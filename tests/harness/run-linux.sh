#!/usr/bin/env bash
# run-linux.sh: real installs in a disposable Linux container. never touches this machine.
#
#   bash tests/harness/run-linux.sh              every scenario in tests/harness/scenarios/linux
#   bash tests/harness/run-linux.sh 02           only scenarios whose file name contains 02
#
# each scenario gets a brand new container from one prebuilt image: the repository mounted read
# only at /src, no network, no privileged mode, no host folder other than the repository, a
# memory and process cap. the container is removed when the scenario ends. the host's own
# install.sh is never run. exit status: 0 all passed, 1 an assertion failed, 77 no container
# engine is running (a skip, not a pass), 2 the harness itself broke.

set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
FILTER="${1:-}"
ENGINE="${SIRVEN_HARNESS_ENGINE:-docker}"
IMAGE="sirven-harness-linux"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"

if ! command -v "$ENGINE" >/dev/null 2>&1 || ! "$ENGINE" info >/dev/null 2>&1; then
  printf 'skipped: no running container engine (%s). on a Mac, start Docker Desktop, or set SIRVEN_HARNESS_ENGINE=podman.\n' "$ENGINE" >&2
  exit 77
fi

# rebuild the image only when its recipe changed: the recipe's checksum is the tag.
recipe_sum="$(shasum "$HARNESS_DIR/Dockerfile.linux" | cut -c1-12)"
if ! "$ENGINE" image inspect "$IMAGE:$recipe_sum" >/dev/null 2>&1; then
  printf 'building %s:%s\n' "$IMAGE" "$recipe_sum"
  "$ENGINE" build -q -t "$IMAGE:$recipe_sum" -f "$HARNESS_DIR/Dockerfile.linux" "$HARNESS_DIR" >/dev/null || { echo "image build failed" >&2; exit 2; }
fi

cleanup() { "$ENGINE" ps -aq --filter "label=sirven-harness=$RUN_ID" | xargs -r "$ENGINE" rm -f >/dev/null 2>&1; }
trap cleanup EXIT

total_failed=0
ran=0
for scenario in "$HARNESS_DIR"/scenarios/linux/*.sh; do
  case "$scenario" in *"$FILTER"*) ;; *) continue ;; esac
  name="$(basename "$scenario" .sh)"
  printf '\n# %s\n' "$name"
  started=$SECONDS
  "$ENGINE" run --rm --label "sirven-harness=$RUN_ID" --network none \
    --memory 256m --pids-limit 256 --cap-drop NET_RAW \
    -v "$REPO_DIR":/src:ro \
    "$IMAGE:$recipe_sum" bash "/src/tests/harness/scenarios/linux/$name.sh" < /dev/null
  status=$?
  printf 'scenario %s: exit %s, %s seconds\n' "$name" "$status" "$((SECONDS - started))"
  ran=$((ran + 1))
  [ "$status" -eq 0 ] || total_failed=$((total_failed + 1))
done
[ "$ran" -gt 0 ] || { echo "no scenario matched '$FILTER'" >&2; exit 2; }
printf '\n%s scenarios, %s failed\n' "$ran" "$total_failed"
[ "$total_failed" -eq 0 ]
