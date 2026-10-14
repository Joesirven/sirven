#!/usr/bin/env bash
# SIR-32 round 3 (review e4). what the gate accepts as "only root and the owner can write this", judged on the folder the first
# install or the kill switch runs from, with no kept copy yet. the whole package tree is judged, not a list of names.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
useradd -m agent 2>/dev/null; groupadd agentgrp; usermod -aG agentgrp agent
run() { ( cd "$1" && bash install.sh revoke --all --yes --transport none > /tmp/o 2>&1; echo $? ); }
verdict() {  # LABEL FOLDER WANT(refuse|accept)
  local st; st="$(run "$2")"
  if [ "$3" = refuse ]; then
    if [ "$st" = 2 ] && grep -q 'refusing to run as root' /tmp/o; then pass "$1: refused"; else fail "$1: wanted a refusal, exit $st" "$(head -4 /tmp/o)"; fi
  else
    if grep -q 'refusing to run as root' /tmp/o; then fail "$1: refused but should be accepted" "$(head -4 /tmp/o)"; else pass "$1: accepted (exit $st)"; fi
  fi
}
fresh() { rm -rf "$1"; mkdir -p "$(dirname "$1")"; cp -r "$SRC" "$1"; chown -R root:root "$1"; }
fresh /work/real1; chmod o+w /work/real1/lib; ln -sfn /work/real1 /work/link1; verdict "symbolic link to a world-writable folder" /work/link1 refuse
fresh /work/real2; ln -sfn /work/real2 /work/link2; verdict "symbolic link to a root-only folder" /work/link2 accept
mkdir -p /work/parent3; chmod 755 /work/parent3; setfacl -m u:agent:rwx /work/parent3; fresh /work/parent3/pkg; verdict "parent folder with an access list entry for the agent" /work/parent3/pkg refuse
fresh /work/real4; chgrp -R agentgrp /work/real4; chmod -R g+w /work/real4; verdict "group agentgrp (the agent is a member) can write" /work/real4 refuse
fresh /work/real5; setfacl -m u:agent:rw /work/real5/lib/audit.sh; verdict "access list entry on one library" /work/real5 refuse
mkdir -p /work/tmp6; chmod 1777 /work/tmp6; fresh /work/tmp6/pkg; verdict "package inside a sticky world-writable folder like /tmp" /work/tmp6/pkg accept
fresh /work/real7; chmod -R o+w /work/real7/tests; verdict "a world-writable folder inside the package that is not a code folder (the whole tree is judged)" /work/real7 refuse
fresh /work/real8; ln -s /etc /work/real8/lib/etc-link; verdict "a link inside the package to a folder outside it" /work/real8 refuse
fresh /work/real9; chown agent /work/real9/lib/common.sh; verdict "a library owned by the agent" /work/real9 refuse
fresh /work/real10; chmod o+w /work/real10; verdict "the package folder itself writable by everyone" /work/real10 refuse
finish
