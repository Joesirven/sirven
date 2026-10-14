#!/usr/bin/env bash
# round 3 (c): the package name regex and the paths built from it. project.json is edited by root in a root-only copy (the agent cannot
# reach it any more); what does each name do? and does a valid name that is not "sirven" work with the fixed kept path?
set -uo pipefail
. /src/tests/harness/lib/world.sh
useradd -m agent
try() {  # NAME
  rm -rf /work/n; mkdir -p /work; cp -r "$SRC" /work/n; chown -R root:root /work/n
  python3 - "$1" <<'PY'
import re, sys
p = "/work/n/project.json"; s = open(p).read()
name = sys.argv[1].replace("\\u0301", "\u0301").replace("\\n", "\n")
s = re.sub(r'"name"\s*:\s*"[^"]*"', lambda m: '"name": "' + name + '"', s, count=1)
open(p, "w").write(s)
PY
  ( cd /work/n && timeout 60 bash install.sh --dry-run --level observer --transport none > /tmp/o 2>&1; echo "name [$1]: exit $? $(grep -m1 -E "^error|not a plain" /tmp/o | cut -c1-120)" )
}
for n in sirven Sirven "../../tmp/evil" "a/b" "a b" "-x" "x-" "" "a.b" "a_b" "9lives" 'x\ny' 'ok\n../..' "sirven\\u0301" "SIRVEN"; do try "$n"; done
echo "== a valid name other than sirven: where do state, kept copy and launcher go? =="
rm -rf /work/n2; cp -r "$SRC" /work/n2; chown -R root:root /work/n2
sed -i 's/"name"[[:space:]]*:[[:space:]]*"[^"]*"/"name": "mypkg"/' /work/n2/project.json
( cd /work/n2 && bash install.sh --yes --level observer --transport none >/tmp/o 2>&1; echo "install exit $?"; ls -d /var/lib/mypkg /var/lib/sirven /etc/mypkg 2>&1 | tr '\n' ' '; echo; ls -l /usr/local/sbin/sirven 2>&1 | cut -c1-80; grep -n "kept" /usr/local/sbin/sirven | head -2 )
/usr/local/sbin/sirven revoke --all --dry-run 2>&1 | head -2 | cut -c1-200
