#!/usr/bin/env bash
# round 3 (f): --prefix normalization. for each value: the exit status of a dry run of install.sh, uninstall.sh and bin/sirven, and where the plan puts the state folder.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /tmp/rl && ln -sfn / /tmp/rootlink; mkdir -p /tmp/real/sub; ln -sfn /tmp/real/sub /tmp/sublink
show() {
  local p="$1" a b c line
  bash install.sh --dry-run --level observer --transport none --prefix "$p" > /tmp/oa 2>&1; a=$?
  bash uninstall.sh --dry-run --prefix "$p" > /tmp/ob 2>&1; b=$?
  bash bin/sirven grant inspect --dry-run --prefix "$p" > /tmp/oc 2>&1; c=$?
  line="$(grep -m1 -o '[^ ]*/var/lib/sirven[^ ]*' /tmp/oa | head -1)"
  printf '%-24s install %-3s uninstall %-3s sirven %-3s plan state folder: %s\n' "[$p]" "$a" "$b" "$c" "$line"
}
for p in / // /// /. /./ /.. /../.. /tmp/.. /tmp/../ /tmp/./.. /tmp//.. /tmp/real/.. /tmp/rootlink /tmp/rootlink/ /tmp/rootlink/tmp/.. /proc/self/root /proc/1/root /tmp/sublink/.. /nonexist/.. /nonexist/../.. /tmp/nonexist/../.. /tmp/real /tmp/real/ /tmp/real//sub; do show "$p"; done
echo "== --prefix=VALUE and repeated flags =="
bash install.sh --dry-run --level observer --transport none --prefix=/ > /tmp/o 2>&1; echo "--prefix=/ : $?"
bash install.sh --dry-run --level observer --transport none --prefix /tmp/real --prefix / > /tmp/o 2>&1; echo "--prefix /tmp/real --prefix / : $?"
bash install.sh --dry-run --level observer --transport none --prefix / --prefix /tmp/real > /tmp/o 2>&1; echo "--prefix / --prefix /tmp/real : $?"
bash install.sh --dry-run --level observer --transport none --prefix "" > /tmp/o 2>&1; echo "--prefix '' : $? $(head -1 /tmp/o | cut -c1-100)"
echo "== a real (not dry) run with a prefix that is a link to / : does it write the real machine? =="
bash install.sh --yes --level observer --transport none --prefix /tmp/rootlink > /tmp/o 2>&1; echo "exit $? $(grep -m1 -E '^error|fake root' /tmp/o | cut -c1-120)"; ls -d /var/lib/sirven /etc/sirven 2>&1 | tr '\n' ' '; echo
