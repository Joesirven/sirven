#!/usr/bin/env bash
# round 2: what does the gate accept as "only root and the owner can write this"? no kept copy yet, so each run is judged on its folder.
set -uo pipefail
. /src/tests/harness/lib/world.sh
useradd -m agent 2>/dev/null; groupadd agentgrp; usermod -aG agentgrp agent
run() { ( cd "$1" && bash install.sh revoke --all --yes --transport none > /tmp/o 2>&1; echo $? ); }
verdict() {  # LABEL FOLDER WANT(refuse|accept)
  local st; st="$(run "$2")"
  if [ "$3" = refuse ]; then [ "$st" = 2 ] && grep -q 'refusing to run' /tmp/o && pass "$1: refused" || { fail "$1: wanted refusal, exit $st" "$(head -4 /tmp/o)"; }
  else grep -q 'refusing to run' /tmp/o && fail "$1: refused but should be accepted" "$(head -4 /tmp/o)" || pass "$1: accepted (exit $st)"; fi
}
fresh() { rm -rf "$1"; mkdir -p "$(dirname "$1")"; cp -r "$SRC" "$1"; chown -R root:root "$1"; }
# 1 a symbolic link to a folder the agent can write
fresh /work/real1; chmod o+w /work/real1/lib; ln -sfn /work/real1 /work/link1; verdict "symbolic link to a world-writable folder" /work/link1 refuse
# 2 a link that is fine, folder fine
fresh /work/real2; ln -sfn /work/real2 /work/link2; verdict "symbolic link to a root-only folder" /work/link2 accept
# 3 writable parent
mkdir -p /work/parent3; chmod 755 /work/parent3; setfacl -m u:agent:rwx /work/parent3; fresh /work/parent3/pkg; verdict "parent folder with an access list entry for the agent" /work/parent3/pkg refuse
# 4 group writable with the agent in the group
fresh /work/real4; chgrp -R agentgrp /work/real4; chmod -R g+w /work/real4; verdict "group agentgrp (the agent is a member) can write" /work/real4 refuse
# 5 access list entry on one file
fresh /work/real5; setfacl -m u:agent:rw /work/real5/lib/audit.sh; verdict "access list entry on one library" /work/real5 refuse
# 6 sticky world-writable parent like /tmp
mkdir -p /work/tmp6; chmod 1777 /work/tmp6; fresh /work/tmp6/pkg; verdict "package inside a sticky world-writable folder like /tmp" /work/tmp6/pkg accept
# 7 a file owned by the agent in a folder not listed as package files (docs) but linked into lib
fresh /work/real7; ln -s ../tests /work/real7/lib/tests-link 2>/dev/null; chmod -R o+w /work/real7/tests; verdict "link inside lib to a world-writable folder inside the package, outside the listed files" /work/real7 accept
# 8 other top-level code the entry scripts read that is not in the listed files
fresh /work/real8; grep -ho '\$ROOT_DIR/[a-z_]*' /work/real8/install.sh /work/real8/lib/*.sh /work/real8/uninstall.sh /work/real8/bin/sirven | sort | uniq -c | sort -rn | head -12
finish
