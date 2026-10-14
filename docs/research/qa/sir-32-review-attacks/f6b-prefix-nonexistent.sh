#!/usr/bin/env bash
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
echo "before: $(ls -d /var/lib/sirven /etc/sirven 2>&1 | tr '\n' ' ')"
bash install.sh --yes --level observer --transport none --prefix /nonexist/.. > /tmp/o 2>&1; echo "install --prefix /nonexist/..  exit $?"
head -2 /tmp/o | cut -c1-120
echo "after: $(ls -d /var/lib/sirven /etc/sirven /nonexist 2>&1 | tr '\n' ' ')"
check "a prefix that spells the real root did not write the real machine" bash -c '[ ! -e /var/lib/sirven ] && [ ! -e /etc/sirven ]'
finish
