# coinflip

`ANALYZE` reads a random sample of each table. When two plans cost almost the
same, a different sample can pick different plan. Same data, no deploy.

coinflip runs `ANALYZE` on the tables a query reads, over and over, and counts
the plans that come out. One psql script. No extension, no regresql.

## Use a copy

Never on production. It runs `ANALYZE` many, many times, all of it inside of
one transaction which gets rolled back in the end.

Rolled back: table data, `pg_statistic`. Not rolled back: `reltuples`,
`relpages`, `relallvisible`, `relallfrozen`, sequences, statistics counters,
dead tuples. Run `ANALYZE` afterwards if you need clean numbers.

The transaction stays open for the whole run. `ANALYZE` holds a
`SHARE UPDATE EXCLUSIVE` lock on each table until the end, and the xmin
horizon doesn't move.

The role must be able to `ANALYZE` the tables (superuser, owner, `MAINTAIN` on
17+). Otherwise coinflip stops. `ANALYZE` alone would warn, skip the table and
leave you with plan that looks stable.

## One query

```
psql -X -d mydb -v query="$(cat q.sql)" -v label=my-query -f coinflip.sql
```

Literal values only, no `$1`. One statement; a trailing semicolon is fine.
Options are more `-v name=value`:

| name      | meaning                                     | default         |
|-----------|---------------------------------------------|-----------------|
| `runs`    | rounds of ANALYZE + EXPLAIN                 | 20              |
| `buffers` | 1: `EXPLAIN ANALYZE`, record shared buffers | 0               |
| `tables`  | comma-separated tables to ANALYZE           | from the plan   |
| `target`  | `default_statistics_target` for the runs    | server setting  |
| `label`   | name in the summary line                    | start of query  |
| `quiet`   | 1: print only the summary line              | 0               |

Join Order Benchmark query 10c, `runs=12 buffers=1`:

```
plans seen:
 plan | runs | min_cost  | max_cost  | min_buffers | max_buffers | shape
------+------+-----------+-----------+-------------+-------------+--------------
    1 |    2 | 592289.57 | 592435.13 |      310620 |      310620 | Aggregate...
    2 |    9 | 556571.98 | 581061.15 |    22171508 |    22171513 | Aggregate...
    3 |    1 | 594015.38 | 594015.38 |      310612 |      310612 | Aggregate...

 coinflip|job-10c|12|3|9|310612|22171513|71.38
```

Three plans, and the one cheapest by cost, chosen nine times, is the one that
reads 71 times more buffers than plan 1.

Without `buffers=1` the query is only planned: costs, no buffers. With it, the
query runs every round. Writes are undone after each round.

Tables are taken from what the first plan shows. `tables=` overrides the list. A partition
stands for its root, and `ANALYZE` on the root analyzes every partition, so a
query that reads one of a thousand partitions analyzes all of them per round.

### Summary line

```
coinflip|label|runs|plans|runs_on_top_plan|min_buffers|max_buffers|buffer_spread
```

With `psql -At -v quiet=1` it is the only output.

`plans` counts distinct shapes: node types, join types, aggregate strategies,
relations, indexes, parallel or not. Estimates, filters and scan direction are
ignored. `buffer_spread` is the largest buffer count over the smallest,
parallel workers included. Empty without `buffers=1`.

## Many queries

```
./coinflip-corpus.sh "postgres://localhost/mydb" queries/ 20 1 > results.csv
```

One statement per `.sql` file, literal values. Optional arguments after the
directory: `runs`, `buffers`, `target`. Pass `''` to skip one. One CSV row per
file; a query that fails gets its error in the last column and the run goes on.

```
file,runs,plans,runs_on_top_plan,min_buffers,max_buffers,buffer_spread,error
```

## Reading the result

One plan means the sample didn't change it this time. A flip that happens once
in fifty runs goes unseen in twenty about two times in three.

A small `buffer_spread` means about the same number of shared buffers. It says
nothing about CPU, spills to disk or elapsed time. A large one is the one to
look at.

A table with no more rows than 300 times the statistics target is sampled
whole and can't flip. The table list marks those, assuming
`default_statistics_target`; a per-column `SET STATISTICS` isn't considered.

## Tested

PostgreSQL 18, psql 18. Needs psql 10 (`\if :{?name}`) and PostgreSQL 12
(`pg_partition_ancestors`). Nothing else was tried.

Written for the PGConf.EU 2026 talk "It works on my database". See
[regresql](https://github.com/boringsql/regresql).
