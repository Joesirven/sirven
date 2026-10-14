#!/usr/bin/env bash
# round 3 (a) again: grants on folders ABOVE or AT the state directory. can the agent be given write over the kept copy, so its vet fails?
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
for p in /var/lib/sirven /var/lib /var /; do
  out="$(bash /var/lib/sirven/package/install.sh --yes --level builder --transport none --path /srv/app --path "$p" 2>&1)"; st=$?
  can=no; runuser -u agent -- test -w /var/lib/sirven/package/lib/kill_switch.sh 2>/dev/null && can=yes
  echo "grant $p: exit $st; agent can now write the kept copy: $can; $(printf '%s\n' "$out" | grep -m1 -iE 'refused|error' | cut -c1-140)"
done
finish
