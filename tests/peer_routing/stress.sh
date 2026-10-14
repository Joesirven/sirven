#!/usr/bin/env bash
# run the peer routing Python suite COUNT times, or only the tests whose names contain PATTERN,
# and count the runs that pass and fail. the output of each failing run is kept in a folder
# named on the last line, so a flake can be read after the loop ends.
#   tests/peer_routing/stress.sh 200 replay
#   tests/peer_routing/stress.sh 10
count="${1:?usage: stress.sh COUNT [PATTERN]}"
pattern="${2:-}"
here="$(cd "$(dirname "$0")" && pwd)"
logs="$(mktemp -d "${TMPDIR:-/tmp}/peer-routing-stress.XXXXXX")"
pass=0
fail=0
for run in $(seq 1 "$count"); do
  if [ -n "$pattern" ]; then
    python3 -m unittest discover -s "$here" -k "$pattern" > "$logs/run-$run.log" 2>&1
  else
    python3 -m unittest discover -s "$here" > "$logs/run-$run.log" 2>&1
  fi
  if [ $? -eq 0 ]; then
    pass=$((pass + 1))
    rm -f "$logs/run-$run.log"
  else
    fail=$((fail + 1))
  fi
done
echo "runs=$count pattern=${pattern:-all} pass=$pass fail=$fail"
echo "failure logs: $logs"
