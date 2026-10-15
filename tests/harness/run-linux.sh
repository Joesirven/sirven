#!/usr/bin/env bash
# run-linux.sh: real installs in a disposable Linux container. never touches this machine.
#
#   bash tests/harness/run-linux.sh              every scenario in tests/harness/scenarios/linux
#   bash tests/harness/run-linux.sh 02           only scenarios whose file name contains 02
#   bash tests/harness/run-linux.sh 01,02,real-host   several filters, separated by commas: a scenario runs if its file name contains any
#
# the machine the scenarios run on is chosen with SIRVEN_HARNESS_IMAGE (default debian12, so existing runs are unchanged):
#   SIRVEN_HARNESS_IMAGE=debian12     Debian 12, Dockerfile.linux (the default)
#   SIRVEN_HARNESS_IMAGE=ubuntu2404   Ubuntu 24.04 long-term support, Dockerfile.linux-ubuntu2404
#   SIRVEN_HARNESS_IMAGE=fedora       Fedora 42 (the Red Hat family, package tool dnf), Dockerfile.linux-fedora
# each recipe is pinned by digest. the core subset worth running on a non-default image (first install as observer and as
# builder, the re-run, uninstall restoring the machine, the consent scenarios) is:
#   SIRVEN_HARNESS_IMAGE=fedora bash tests/harness/run-linux.sh 01-install,02-uninstall,real-host
# a scenario that needs the real Tailscale always uses the Debian image of Dockerfile.linux-tailscale, whatever is chosen here.
#
# each scenario gets a brand new container from one prebuilt image: the repository mounted read
# only at /src (and copied to /srv/pkg, root-owned, which is what the scenario runs), no network, no privileged mode, no host folder other than the repository, a
# memory and process cap (256 MB; a scenario can ask for more with a header line, see below). the container is removed when the scenario ends.
# the one exception is a scenario that needs the real Tailscale, which asks in header lines (below) for the image with it, for a network of its
# own (made for that run and removed after it, never the shared default one), and for a test key to be passed in. it is the only way a
# scenario reaches a network, and the key is passed by name or by a private file holding that one line, never on a command line. the host's own
# install.sh is never run. exit status: 0 all passed, 1 an assertion failed, 77 no container
# engine is running (a skip, not a pass), 2 the harness itself broke.
#
# several runs may go at once on one host. every container, network and temporary file a run makes carries that run's identifier
# (in its label and, for containers, its name), and the cleanup removes only those. to stop a run, send kill -TERM to the process number
# it prints at its start. never pkill -f (it matches every run's command line) and never remove containers by the bare label name (it
# matches every run). the shared image is never removed. a stopped run removes its own containers at once.

set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
FILTER="${1:-}"
ENGINE="${SIRVEN_HARNESS_ENGINE:-docker}"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
printf 'run %s, process %s: to stop only this run, kill -TERM %s\n' "$RUN_ID" "$$" "$$" >&2

if ! command -v "$ENGINE" >/dev/null 2>&1 || ! "$ENGINE" info >/dev/null 2>&1; then
  printf 'skipped: no running container engine (%s). on a Mac, start Docker Desktop, or set SIRVEN_HARNESS_ENGINE=podman.\n' "$ENGINE" >&2
  exit 77
fi

# ensure_image DOCKERFILE NAME: rebuild the image only when its recipe changed (the recipe's checksum is the tag), and print the tag.
ensure_image() {
  local recipe="$1" name="$2" sum
  sum="$(shasum "$HARNESS_DIR/$recipe" | cut -c1-12)"
  if ! "$ENGINE" image inspect "$name:$sum" >/dev/null 2>&1; then
    printf 'building %s:%s\n' "$name" "$sum" >&2
    "$ENGINE" build -q -t "$name:$sum" -f "$HARNESS_DIR/$recipe" "$HARNESS_DIR" >/dev/null || { echo "image build failed" >&2; exit 2; }
  fi
  printf '%s:%s' "$name" "$sum"
}

# the private file that carries the test key into a container, made per scenario and removed with it
KEY_ENV_FILE=""
remove_key_env_file() { [ -z "$KEY_ENV_FILE" ] || rm -f "$KEY_ENV_FILE"; KEY_ENV_FILE=""; }
# run_pid is the container client of the scenario in progress; it runs in the background so a stop signal is handled at once
run_pid=""
cleanup() {
  [ -z "$run_pid" ] || kill "$run_pid" 2>/dev/null
  remove_key_env_file
  "$ENGINE" ps -aq --filter "label=sirven-harness=$RUN_ID" | xargs -r "$ENGINE" rm -f >/dev/null 2>&1
  "$ENGINE" network ls -q --filter "label=sirven-harness=$RUN_ID" | xargs -r "$ENGINE" network rm >/dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

total_failed=0
ran=0
case "${SIRVEN_HARNESS_IMAGE:-debian12}" in
  debian12) default_image="$(ensure_image Dockerfile.linux sirven-harness-linux)" ;;
  ubuntu2404) default_image="$(ensure_image Dockerfile.linux-ubuntu2404 sirven-harness-linux-ubuntu2404)" ;;
  fedora) default_image="$(ensure_image Dockerfile.linux-fedora sirven-harness-linux-fedora)" ;;
  *) echo "unknown SIRVEN_HARNESS_IMAGE '$SIRVEN_HARNESS_IMAGE': use debian12, ubuntu2404 or fedora" >&2; exit 2 ;;
esac
[ -n "$default_image" ] || exit 2
for scenario in "$HARNESS_DIR"/scenarios/linux/*.sh; do
  # a wholly empty filter selects every scenario. an empty element ("01,", "01,,02", ",01") names nothing and is skipped:
  # matched as a pattern it would match every file name.
  selected=""
  [ -n "$FILTER" ] || selected=yes
  rest="$FILTER,"
  while [ -n "$rest" ]; do
    f="${rest%%,*}"
    rest="${rest#*,}"
    [ -n "$f" ] || continue
    case "$scenario" in *"$f"*) selected=yes ;; esac
  done
  [ -n "$selected" ] || continue
  name="$(basename "$scenario" .sh)"
  printf '\n# %s\n' "$name"
  started=$SECONDS
  # 256 MB unless the scenario asks for more in a header line "# harness-memory: 1g" (the kernel's own cache of
  # hundreds of thousands of folders counts against the container). the helper's own peak is asserted by the scenario.
  memory="$(sed -n 's/^# harness-memory: \([0-9]*[mg]\)$/\1/p' "$scenario" | head -1)"
  # "# harness-apparmor: unconfined" lifts the host's AppArmor profile for that one container. why: on a Linux host with AppArmor
  # (the server ba-sing-se) its default profile rejects the deliberately deep mkdir chains of scenarios 17, 22 and 26 with
  # ENAMETOOLONG; Docker Desktop on a Mac has no AppArmor. the depths must not be lowered to suit a host. no other isolation changes:
  # no host folder, the same network as any other scenario (none unless it asks for the real Tailscale), same capabilities, memory and process caps.
  apparmor="$(sed -n 's/^# harness-apparmor: \(unconfined\)$/\1/p' "$scenario" | head -1)"
  apparmor_option=""
  [ -n "$apparmor" ] && apparmor_option="--security-opt apparmor=$apparmor"
  # "# harness-tailscale: yes" gives the scenario the image with the real tailscale, a network made for this run alone (so the
  # container cannot reach another container on the shared default bridge), and the test key if one is available:
  # SIRVEN_TAILSCALE_AUTHKEY in this shell's environment (passed by name, so its value is never on a command line), or the
  # SIRVEN_TAILSCALE_AUTHKEY line of the dotenv file named by SIRVEN_HARNESS_SECRETS_FILE. only that one line is copied, into a
  # private temporary file (mode 0600, removed when the scenario ends) that is passed with --env-file: no other variable of the
  # dotenv file reaches a container that has a network and runs the code under test.
  # without a key the scenario still runs and skips the steps that need one, saying so.
  image="$default_image"
  network=none
  own_network=""
  set --
  if grep -q '^# harness-tailscale: yes$' "$scenario"; then
    image="$(ensure_image Dockerfile.linux-tailscale sirven-harness-linux-tailscale)"
    [ -n "$image" ] || exit 2
    network="sirven-harness-$RUN_ID-${name%%-*}"
    "$ENGINE" network create --label "sirven-harness=$RUN_ID" "$network" >/dev/null || { echo "could not make the network $network" >&2; exit 2; }
    own_network="$network"
    set -- "$@" -e "SIRVEN_TAILSCALE_HOSTNAME=harness-$RUN_ID"
    secrets_file="${SIRVEN_HARNESS_SECRETS_FILE:-/nonexistent}"
    if [ -n "${SIRVEN_TAILSCALE_AUTHKEY:-}" ]; then
      set -- "$@" -e SIRVEN_TAILSCALE_AUTHKEY
    elif [ -f "$secrets_file" ] && grep -q '^SIRVEN_TAILSCALE_AUTHKEY=.' "$secrets_file"; then
      KEY_ENV_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/sirven-harness-key.XXXXXX")" || { echo "could not make a private file for the key" >&2; exit 2; }
      grep -m 1 '^SIRVEN_TAILSCALE_AUTHKEY=.' "$secrets_file" > "$KEY_ENV_FILE"
      set -- "$@" --env-file "$KEY_ENV_FILE"
    fi
  fi
  # the repository is mounted read only at /src and copied inside the container to /srv/pkg, owned by root: the installer
  # refuses, as root, to run code from a folder owned by someone else (the host user who owns the mount), so the scenario
  # runs the copy (SRC=/srv/pkg). the scenario script itself is read from /src.
  "$ENGINE" run --rm --name "sirven-harness-$RUN_ID-$name" --label "sirven-harness=$RUN_ID" --network "$network" \
    --memory "${memory:-256m}" --pids-limit 256 --cap-drop NET_RAW $apparmor_option \
    "$@" \
    -v "$REPO_DIR":/src:ro \
    "$image" bash -c 'cp -r /src /srv/pkg && SRC=/srv/pkg exec bash "$0"' \
    "/src/tests/harness/scenarios/linux/$name.sh" < /dev/null &
  run_pid=$!
  wait "$run_pid"
  status=$?
  run_pid=""
  remove_key_env_file
  [ -z "$own_network" ] || "$ENGINE" network rm "$own_network" >/dev/null 2>&1
  printf 'scenario %s: exit %s, %s seconds\n' "$name" "$status" "$((SECONDS - started))"
  ran=$((ran + 1))
  [ "$status" -eq 0 ] || total_failed=$((total_failed + 1))
done
[ "$ran" -gt 0 ] || { echo "no scenario matched '$FILTER'" >&2; exit 2; }
printf '\n%s scenarios, %s failed\n' "$ran" "$total_failed"
[ "$total_failed" -eq 0 ]
