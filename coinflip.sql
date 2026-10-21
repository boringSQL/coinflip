-- coinflip.sql: re-run ANALYZE on the tables a query reads and count the
-- distinct plans it gets. Options and output are described in README.md.
--
--   psql -X -d DB -v query="SELECT ..." -f coinflip.sql

\set ON_ERROR_STOP on

\if :{?query}
\else
    \echo 'usage: psql -X -d DB -v query="SELECT ..." [-v runs=20] [-v buffers=1] [-v tables=a,b] [-v target=100] [-v label=name] [-v quiet=1] -f coinflip.sql'
    \quit
\endif
\if :{?runs}
\else
    \set runs 20
\endif
\if :{?buffers}
\else
    \set buffers 0
\endif
\if :{?tables}
\else
    \set tables ''
\endif
\if :{?target}
\else
    \set target ''
\endif
\if :{?label}
\else
    \set label ''
\endif
\if :{?quiet}
\else
    \set quiet 0
\endif

-- psql's own QUIET variable, unrelated to the quiet option above
\set QUIET on
\pset footer off

BEGIN;

-- A DO block cannot see psql variables, so hand them over as settings.
-- \gset swallows the row.
SELECT set_config('coinflip.query',   :'query',   true),
       set_config('coinflip.runs',    :'runs',    true),
       set_config('coinflip.buffers', :'buffers', true),
       set_config('coinflip.tables',  :'tables',  true),
       set_config('coinflip.target',  :'target',  true)
\gset cfg_

-- Temp tables come first in the search path, so a plain name could shadow a
-- table the query reads. Hence the prefix.
CREATE TEMP TABLE coinflip_runs (
    run        int,
    shape      text,
    total_cost numeric,
    buffers    bigint
);

CREATE TEMP TABLE coinflip_tables (rel text);

-- Node types, join types, relations and indexes, without estimates.
-- Equal shapes count as the same plan.
CREATE FUNCTION pg_temp.coinflip_shape(node jsonb) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    children text;
BEGIN
    SELECT string_agg(pg_temp.coinflip_shape(child), ',' ORDER BY ord)
      INTO children
      FROM jsonb_array_elements(coalesce(node->'Plans', '[]')) WITH ORDINALITY AS t(child, ord);

    RETURN concat_ws(' ',
               node->>'Node Type',
               node->>'Join Type',
               node->>'Strategy',
               CASE WHEN (node->>'Parallel Aware')::boolean THEN 'parallel' END,
               node->>'Relation Name',
               node->>'Index Name')
           || coalesce('(' || children || ')', '');
END $$;

DO $$
DECLARE
    query    text    := current_setting('coinflip.query');
    runs     int     := current_setting('coinflip.runs')::int;
    buffers  boolean := current_setting('coinflip.buffers')::boolean;
    tables   text    := current_setting('coinflip.tables');
    target   text    := current_setting('coinflip.target');
    name     text;
    rels     text[];
    rel      text;
    allowed  boolean;
    result   text;
    root     jsonb;
BEGIN
    IF runs < 1 THEN
        RAISE EXCEPTION 'coinflip: runs must be at least 1';
    END IF;

    -- SPI executes every statement in the string and returns the last one,
    -- so "SELECT ...; SELECT ..." would plan the wrong statement, or run it
    -- bare under EXPLAIN ANALYZE.
    IF regexp_replace(query, ';\s*$', '') ~ ';' THEN
        RAISE EXCEPTION 'coinflip: single statement only (a trailing semicolon is fine)';
    END IF;

    IF target <> '' THEN
        PERFORM set_config('default_statistics_target', target, true);
    END IF;

    IF tables <> '' THEN
        FOREACH name IN ARRAY string_to_array(tables, ',') LOOP
            rel := to_regclass(trim(name))::text;
            IF rel IS NULL THEN
                RAISE EXCEPTION 'coinflip: no such table: %', trim(name);
            END IF;
            -- ANALYZE would only warn and skip an index or a view
            IF (SELECT relkind FROM pg_class WHERE oid = rel::regclass) NOT IN ('r', 'm', 'p', 'f') THEN
                RAISE EXCEPTION 'coinflip: not a table: %', rel;
            END IF;
            IF rel <> ALL (coalesce(rels, '{}')) THEN
                rels := rels || rel;
            END IF;
        END LOOP;
    ELSE
        -- First plan only; tables= overrides.
        EXECUTE 'EXPLAIN (VERBOSE, FORMAT JSON) ' || query INTO result;
        -- A partition stands for its root: ANALYZE on the root analyzes every
        -- partition, and the root's statistics feed join estimates.
        SELECT array_agg(DISTINCT s.rel)
          INTO rels
          FROM jsonb_path_query(result::jsonb,
                                'strict $[0].Plan.** ? (exists(@."Relation Name"))') AS n,
               LATERAL (SELECT format('%I.%I', n->>'Schema', n->>'Relation Name')::regclass AS leaf) AS l,
               LATERAL (SELECT coalesce((SELECT a
                                           FROM pg_partition_ancestors(l.leaf) AS a
                                          WHERE NOT EXISTS (SELECT 1
                                                              FROM pg_partition_ancestors(a) AS x
                                                             WHERE x <> a)),
                                        l.leaf)::regclass::text) AS s(rel);
    END IF;

    IF rels IS NULL THEN
        RAISE EXCEPTION 'coinflip: the plan reads no tables, nothing to ANALYZE';
    END IF;

    -- ANALYZE only warns and skips a table the role may not analyze, which
    -- would look like a stable plan.
    FOREACH rel IN ARRAY rels LOOP
        IF current_setting('server_version_num')::int >= 170000 THEN
            allowed := has_table_privilege(rel, 'MAINTAIN');
        ELSE
            -- before 17: the owner, or the owner of the database
            allowed := pg_has_role((SELECT relowner FROM pg_class WHERE oid = rel::regclass), 'MEMBER')
                    OR pg_has_role((SELECT datdba FROM pg_database WHERE datname = current_database()), 'MEMBER');
        END IF;
        IF NOT allowed THEN
            RAISE EXCEPTION 'coinflip: not allowed to ANALYZE %', rel;
        END IF;
    END LOOP;
    INSERT INTO coinflip_tables SELECT unnest(rels);

    FOR i IN 1..runs LOOP
        FOREACH rel IN ARRAY rels LOOP
            EXECUTE 'ANALYZE ' || rel;
        END LOOP;

        IF buffers THEN
            -- EXPLAIN ANALYZE runs the query. Abort the subtransaction after
            -- each run so a write is not repeated on top of itself. The
            -- variable keeps its value through the abort, table changes do not.
            BEGIN
                EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) ' || query INTO result;
                RAISE EXCEPTION USING ERRCODE = 'CF001', MESSAGE = 'undo the query';
            EXCEPTION WHEN SQLSTATE 'CF001' THEN
                NULL;
            END;
        ELSE
            EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO result;
        END IF;
        root := result::jsonb->0->'Plan';

        INSERT INTO coinflip_runs VALUES (
            i,
            pg_temp.coinflip_shape(root),
            (root->>'Total Cost')::numeric,
            CASE WHEN buffers
                 THEN (root->>'Shared Hit Blocks')::bigint + (root->>'Shared Read Blocks')::bigint
            END);
    END LOOP;
END $$;

\if :quiet
\else
    \echo
    \echo 'tables analyzed, with their row estimate after the last run:'
    SELECT t.rel AS "table",
           c.reltuples::bigint AS rows,
           -- The sample is 300 * the largest statistics target on the table;
           -- a table with no more rows than that is sampled whole. This uses
           -- the default target and ignores per-column ones.
           CASE WHEN c.reltuples >= 0 AND c.relkind <> 'p'
                 AND c.reltuples <= 300 * current_setting('default_statistics_target')::int
                THEN 'read in full, cannot flip'
           END AS note
      FROM coinflip_tables t
      JOIN pg_class c ON c.oid = t.rel::regclass
     ORDER BY 1;

    \echo 'plans seen:'
    SELECT dense_rank() OVER (ORDER BY min(run)) AS plan,
           count(*)         AS runs,
           min(total_cost)  AS min_cost,
           max(total_cost)  AS max_cost,
           min(buffers)     AS min_buffers,
           max(buffers)     AS max_buffers,
           shape
      FROM coinflip_runs
     GROUP BY shape
     ORDER BY 1;
\endif

WITH per_shape AS (
    SELECT count(*) AS n, min(buffers) AS min_buf, max(buffers) AS max_buf
      FROM coinflip_runs
     GROUP BY shape
)
SELECT concat_ws('|',
           'coinflip',
           replace(coalesce(nullif(:'label', ''),
                            btrim(left(regexp_replace(:'query', '\s+', ' ', 'g'), 60))), '|', '/'),
           (SELECT count(*) FROM coinflip_runs),
           count(*),
           max(n),
           coalesce(min(min_buf)::text, ''),
           coalesce(max(max_buf)::text, ''),
           coalesce(round(max(max_buf)::numeric / nullif(min(min_buf), 0), 2)::text, '')
       ) AS summary
  FROM per_shape;

ROLLBACK;
