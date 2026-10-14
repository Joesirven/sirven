#!/usr/bin/env bash
# run-ro-bind.sh: the read-only mount case of the root gate (SIR-32 round 3, review ro-bind). one host folder is mounted twice in
# the container, read-write at /rw and read-only at /ro. a read-only mount says nothing about who can write the same files through
# the other mount, so the gate must not take it as safe. the folder holds a copy of the package, mode 666, owned by another account;
# the agent edits a library through /rw; root runs the installer from /ro and the edit must not run as root.
#
#   bash tests/harness/run-ro-bind.sh        exit 0 when the gate refused, 1 when root ran the agent's code, 77 no engine
set -uo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
ENGINE="${SIRVEN_HARNESS_ENGINE:-docker}"
if ! command -v "$ENGINE" >/dev/null 2>&1 || ! "$ENGINE" info >/dev/null 2>&1; then
  echo "skipped: no running container engine ($ENGINE)" >&2
  exit 77
fi
recipe_sum="$(shasum "$HARNESS_DIR/Dockerfile.linux" | cut -c1-12)"
IMAGE="sirven-harness-linux:$recipe_sum"
"$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 || "$ENGINE" build -q -t "$IMAGE" -f "$HARNESS_DIR/Dockerfile.linux" "$HARNESS_DIR" >/dev/null || exit 2
work="$(mktemp -d "${TMPDIR:-/tmp}/sirven-ro-bind.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# SIRVEN_PACKAGE_DIR: the package to test (default: this one)
mkdir -p "$work/mnt" && cp -r "${SIRVEN_PACKAGE_DIR:-$REPO_DIR}" "$work/mnt/pkg" && chmod -R a+rwX "$work/mnt"
"$ENGINE" run --rm --label sirven-harness-ro-bind=1 --network none --memory 256m --memory-swap 256m --pids-limit 256 --cpus 1 --cap-drop NET_RAW \
  -v "$work/mnt":/rw -v "$work/mnt":/ro:ro "$IMAGE" bash -c '
  useradd -m agent
  echo "mounts: $(grep -E " /(rw|ro) " /proc/mounts | awk "{print \$2, \$4}" | tr "\n" ";")"
  runuser -u agent -- bash -c "printf \"\ntouch /tmp/ROOT-RAN-ROBIND\n\" >> /rw/pkg/lib/kill_switch.sh && echo the agent edited a library through /rw"
  cd /ro/pkg && bash install.sh revoke --all --yes --transport none > /tmp/o 2>&1; echo "revoke from /ro/pkg: exit $?"; head -3 /tmp/o | cut -c1-200
  if [ -e /tmp/ROOT-RAN-ROBIND ]; then echo "FINDING: root ran code the agent edited, trusting a read-only mount"; exit 1; fi
  grep -q "refusing to run as root" /tmp/o && echo "ok: the gate refused, and the agent code did not run" && exit 0
  echo "the agent code did not run, but the gate did not refuse either"; exit 1
' < /dev/null
