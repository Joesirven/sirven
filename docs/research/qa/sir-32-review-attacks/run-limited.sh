#!/usr/bin/env bash
# review runner: one container at a time, 256 MB with no swap, 256 processes, one cpu, and a memory floor check.
# usage: run-limited.sh SCENARIO...   each is a file name in tests/harness/scenarios/linux (without .sh) or review/NAME
set -uo pipefail
SRC_DIR=/tmp/sir32-src
REVIEW_DIR=/tmp/sir32-review
IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^sirven-harness-linux:' | head -1)"
total_failed=0
for name in "$@"; do
  avail="$(free -m | awk '/^Mem:/ {print $7}')"
  if [ "$avail" -lt 800 ]; then echo "STOP: available memory $avail MB is below 800 MB"; exit 9; fi
  case "$name" in
    review/*) path="/review/${name#review/}.sh" ;;
    *) path="/src/tests/harness/scenarios/linux/$name.sh" ;;
  esac
  printf '\n# %s (available %s MB)\n' "$name" "$avail"
  started=$SECONDS
  docker run --rm --label sir32-review=1 --network none --memory 256m --memory-swap 256m --pids-limit 256 --cpus 1 \
    --cap-drop NET_RAW -v "$SRC_DIR":/src:ro -v "$REVIEW_DIR":/review:ro "$IMAGE" bash "$path" < /dev/null
  status=$?
  printf 'scenario %s: exit %s, %s seconds\n' "$name" "$status" "$((SECONDS - started))"
  [ "$status" -eq 0 ] || total_failed=$((total_failed + 1))
done
printf '\n%s failed\n' "$total_failed"
