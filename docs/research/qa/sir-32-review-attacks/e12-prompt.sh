#!/usr/bin/env bash
# round 2: the real-machine prompt. no terminal and no --yes: refuse, change nothing. the environment answer that skips it.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
before="$(getent shadow agent)"
out="$(bash install.sh revoke --all --transport none 2>&1 < /dev/null)"; st=$?
echo "no --yes, no terminal: exit $st"; printf '%s\n' "$out" | tail -2 | cut -c1-200
check "refused with exit 2 and nothing changed" bash -c '[ "'$st'" = 2 ] && [ "$(getent shadow agent)" = "'"$before"'" ]'
out="$(SIRVEN_YES=1 bash install.sh revoke --all --transport none 2>&1 < /dev/null)"; st=$?
echo "SIRVEN_YES=1 and no --yes: exit $st"
echo "dry run does not ask: $(bash install.sh revoke --all --dry-run --transport none >/dev/null 2>&1 < /dev/null; echo exit $?)"
finish
