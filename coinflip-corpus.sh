#!/usr/bin/env bash
# Run coinflip.sql over every .sql file under a directory, one CSV row per file.
#
#   coinflip-corpus.sh DB_URI DIR [runs] [buffers] [target] > results.csv

# No -e: a failing query must not stop the run, its error goes in the CSV.
set -u

usage="usage: coinflip-corpus.sh DB_URI DIR [runs] [buffers] [target]"
uri=${1:?$usage}
dir=${2:?$usage}

here=$(cd "$(dirname "$0")" && pwd)

# bash 3.2 (macOS) fails on an empty array under set -u, hence the ${x[@]+...} below.
options=()
[ -n "${3:-}" ] && options+=(-v "runs=$3")
[ -n "${4:-}" ] && options+=(-v "buffers=$4")
[ -n "${5:-}" ] && options+=(-v "target=$5")

csv() { printf '"%s"' "${1//\"/\"\"}"; }

echo "file,runs,plans,runs_on_top_plan,min_buffers,max_buffers,buffer_spread,error"

find "$dir" -type f -name '*.sql' -print0 | sort -z | while IFS= read -r -d '' file; do
    out=$(psql -X -w -At -d "$uri" ${options[@]+"${options[@]}"} -v quiet=1 \
        -v query="$(cat "$file")" -f "$here/coinflip.sql" 2>&1)

    summary=$(grep -m1 '^coinflip|' <<<"$out")
    if [ -n "$summary" ]; then
        IFS='|' read -r _ _ n plans top min max spread <<<"$summary"
        echo "$(csv "$file"),$n,$plans,$top,$min,$max,$spread,"
    else
        error=$(grep -m1 -E '(^|: )ERROR: ' <<<"$out" | sed -E 's/^(psql:.*:[0-9]+: )?ERROR: +//')
        echo "$(csv "$file"),,,,,,,$(csv "${error:-$(head -1 <<<"$out")}")"
    fi
done
