#!/usr/bin/env bash
# round 3: the gate runs only when the script is run as a file ("${BASH_SOURCE[0]}" = "$0"). the script piped to bash, or run with -c, has no such name.
set -uo pipefail
. /src/tests/harness/lib/world.sh
mkdir -p /work && cp -r "$SRC" /work/repo && cd /work/repo || exit 2
bash install.sh --yes --level builder --transport none --path /work/repo >/dev/null 2>&1
runuser -u agent -- bash -c 'printf "\ntouch /tmp/ran.\$(date +%%N)\n" >> /work/repo/lib/common.sh'
try() { rm -f /tmp/ran.*; shift 0; }
cd /work/repo
rm -f /tmp/ran.*; bash -s -- --dry-run --level observer --transport none < install.sh > /tmp/o1 2>&1; echo "bash -s < install.sh: exit $?, agent code ran as root $(ls /tmp/ran.* 2>/dev/null | wc -l) time(s); $(grep -m1 -E 'refusing|error' /tmp/o1 | cut -c1-100)"
n1=$(ls /tmp/ran.* 2>/dev/null | wc -l)
rm -f /tmp/ran.*; bash -c "$(cat install.sh)" install.sh --dry-run --level observer --transport none > /tmp/o2 2>&1; echo "bash -c \"\$(cat install.sh)\": exit $?, agent code ran as root $(ls /tmp/ran.* 2>/dev/null | wc -l) time(s); $(grep -m1 -E 'refusing|error' /tmp/o2 | cut -c1-100)"
n2=$(ls /tmp/ran.* 2>/dev/null | wc -l)
rm -f /tmp/ran.*; cat install.sh | bash -s -- --dry-run --level observer --transport none > /tmp/o3 2>&1; echo "cat install.sh | bash -s: exit $?, ran $(ls /tmp/ran.* 2>/dev/null | wc -l)"
n3=$(ls /tmp/ran.* 2>/dev/null | wc -l)
check "no way of starting install.sh as root runs the agent's edit" test "$((n1+n2+n3))" = 0
finish
