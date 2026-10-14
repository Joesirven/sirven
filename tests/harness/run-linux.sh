#!/usr/bin/env bash
# run-linux.sh: real installs in a disposable Linux container. never touches this machine.
#
#   bash tests/harness/run-linux.sh              every scenario in tests/harness/scenarios/linux
#   bash tests/harness/run-linux.sh 02           only scenarios whose file name contains 02
#
# each scenario gets a brand new container from one prebuilt image: the repository mounted read
# only at /src (and copied to /srv/pkg, root-owned, which is what the scenario runs), no network, no privileged mode, no host folder other than the repository, a
# memory and process cap (256 MB; a scenario can ask for more with a header line, see below). the container is removed when the scenario ends. the host's own
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
  # 256 MB unless the scenario asks for more in a header line "# harness-memory: 1g" (the kernel's own cache of
  # hundreds of thousands of folders counts against the container). the helper's own peak is asserted by the scenario.
  memory="$(sed -n 's/^# harness-memory: \([0-9]*[mg]\)$/\1/p' "$scenario" | head -1)"
  # "# harness-apparmor: unconfined" lifts the host's AppArmor profile for that one container. why: on a Linux host with AppArmor
  # (the server ba-sing-se) its default profile rejects the deliberately deep mkdir chains of scenarios 17, 22 and 26 with
  # ENAMETOOLONG; Docker Desktop on a Mac has no AppArmor. the depths must not be lowered to suit a host. no other isolation changes:
  # no host folder, --network none, same capabilities, memory and process caps.
  apparmor="$(sed -n 's/^# harness-apparmor: \(unconfined\)$/\1/p' "$scenario" | head -1)"
  apparmor_option=""
  [ -n "$apparmor" ] && apparmor_option="--security-opt apparmor=$apparmor"
  # the repository is mounted read only at /src and copied inside the container to /srv/pkg, owned by root: the installer
  # refuses, as root, to run code from a folder owned by someone else (the host user who owns the mount), so the scenario
  # runs the copy (SRC=/srv/pkg). the scenario script itself is read from /src.
  "$ENGINE" run --rm --label "sirven-harness=$RUN_ID" --network none \
    --memory "${memory:-256m}" --pids-limit 256 --cap-drop NET_RAW $apparmor_option \
    -v "$REPO_DIR":/src:ro \
    "$IMAGE:$recipe_sum" bash -c 'cp -r /src /srv/pkg && SRC=/srv/pkg exec bash "$0"' \
    "/src/tests/harness/scenarios/linux/$name.sh" < /dev/null
  status=$?
  printf 'scenario %s: exit %s, %s seconds\n' "$name" "$status" "$((SECONDS - started))"
  ran=$((ran + 1))
  [ "$status" -eq 0 ] || total_failed=$((total_failed + 1))
done
[ "$ran" -gt 0 ] || { echo "no scenario matched '$FILTER'" >&2; exit 2; }
printf '\n%s scenarios, %s failed\n' "$ran" "$total_failed"
[ "$total_failed" -eq 0 ]
