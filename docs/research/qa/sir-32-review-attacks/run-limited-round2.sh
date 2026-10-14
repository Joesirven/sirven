#!/usr/bin/env bash
# round 2 runner: one container at a time, 256 MB no swap, 256 processes, 1 cpu, memory floor 800 MB.
# the package is copied inside the container (root-owned) to /srv/pkg, because the trust gate refuses a folder owned by
# the host user. scenario names: NN-name (tests/harness/scenarios/linux) or review/NAME.
set -uo pipefail
IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^sirven-harness-linux:' | head -1)"
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
    --cap-drop NET_RAW -v /tmp/sir32-src:/src:ro -v /tmp/sir32-review:/review:ro "$IMAGE" \
    bash -c 'cp -r /src /srv/pkg && SRC=/srv/pkg exec bash "$0"' "$path" < /dev/null
  printf 'scenario %s: exit %s, %s seconds\n' "$name" "$?" "$((SECONDS - started))"
done
