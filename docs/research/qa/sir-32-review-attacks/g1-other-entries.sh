#!/usr/bin/env bash
# the same gate text is in uninstall.sh and bin/sirven: do they hold against an agent-edited copy (dry run, help, rollback, repair, inspect)?
set -uo pipefail
. /src/tests/harness/lib/world.sh
mkdir -p /work && cp -r "$SRC" /work/repo && cd /work/repo || exit 2
bash install.sh --yes --level builder --transport none --path /work/repo >/dev/null 2>&1
runuser -u agent -- bash -c 'for f in lib/common.sh lib/layout.sh; do printf "\ntouch /tmp/ran.\$(date +%%N)\n" >> /work/repo/$f; done'
t() { rm -f /tmp/ran.*; timeout 120 "$@" > /tmp/o 2>&1; echo "[$*] exit $?, agent code ran as root $(ls /tmp/ran.* 2>/dev/null | wc -l) time(s)"; ls /tmp/ran.* >/dev/null 2>&1 && fail "$*: agent edit ran as root" || pass "$*: not run"; }
t bash uninstall.sh --dry-run
t bash uninstall.sh --help
t bash bin/sirven grant inspect
t bash bin/sirven grant rollback --dry-run
t bash bin/sirven grant repair --dry-run --path /work/repo
t bash bin/sirven --help
finish
