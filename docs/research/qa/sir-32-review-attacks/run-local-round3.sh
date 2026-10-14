#!/usr/bin/env bash
# round 3 runner on this Mac: one container at a time, 256 MB no swap, 256 processes, 1 CPU, no network. the package is copied
# inside the container (root-owned) to /srv/pkg. names: review/NAME (this folder) .
set -uo pipefail
IMAGE="$1"; REPO="$2"; REVIEW="$3"; shift 3
for name in "$@"; do
  printf '\n# %s\n' "$name"; started=$SECONDS
  docker run --rm --label sir32-review=1 --network none --memory 256m --memory-swap 256m --pids-limit 256 --cpus 1 \
    --cap-drop NET_RAW -v "$REPO":/src:ro -v "$REVIEW":/review:ro "$IMAGE" \
    bash -c 'cp -r /src /srv/pkg && SRC=/srv/pkg exec bash "$0"' "/review/$name.sh" < /dev/null
  printf 'scenario %s: exit %s, %s seconds\n' "$name" "$?" "$((SECONDS - started))"
done
