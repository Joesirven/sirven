#!/usr/bin/env bash
# SIR-32 round 3 (review e4). what the gate accepts as "only root and the owner can write this", judged on the folder the first
# install or the kill switch runs from, with no kept copy yet. the whole package tree is judged, not a list of names.
# SIR-96: a sticky world-writable folder on the way (like /tmp) is let through only when the folder below it is root's or the
# owner's and is not open to others; a member of group root counts against the group unless it is a system account that cannot
# log in or be used to write (Fedora puts sync, shutdown, halt and operator in group root).
# SIR-97: a refusal for an access list entry names the entry, not the group whose mode bits are only the mask.
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
fresh /tmp/pkg-in-real-tmp; verdict "package inside the real /tmp" /tmp/pkg-in-real-tmp accept
mkdir -p /work/tmp7; chmod 1777 /work/tmp7; fresh /work/tmp7/pkg; chown agent /work/tmp7/pkg; verdict "sticky world-writable parent, package folder owned by the agent" /work/tmp7/pkg refuse
check "... and it names the package folder and its owner" grep -q '/work/tmp7/pkg: owned by agent' /tmp/o
mkdir -p /work/tmp8; chmod 1777 /work/tmp8; fresh /work/tmp8/pkg; chmod o+w /work/tmp8/pkg; verdict "sticky world-writable parent, package folder open to everyone" /work/tmp8/pkg refuse
mkdir -p /work/tmp9/inner; chmod 1777 /work/tmp9 /work/tmp9/inner; fresh /work/tmp9/inner/pkg; verdict "two sticky world-writable folders in a row: only the first is let through" /work/tmp9/inner/pkg refuse
mkdir -p /work/tmp10; chmod 777 /work/tmp10; fresh /work/tmp10/pkg; verdict "world-writable parent without the sticky bit" /work/tmp10/pkg refuse
fresh /work/tmp11; chmod 1777 /work/tmp11; verdict "the package folder itself is sticky and world-writable" /work/tmp11 refuse
# an access list on a file whose group has a member (agentgrp has the agent): the mode shows group write, but that is the mask
fresh /work/m1; chgrp agentgrp /work/m1/lib/audit.sh; chmod 644 /work/m1/lib/audit.sh; setfacl -m u:agent:rw /work/m1/lib/audit.sh
check "precondition: the file shows group write (the mask) though its group may only read" bash -c '[ "$(stat -c %a /work/m1/lib/audit.sh)" = 664 ] && getfacl -p /work/m1/lib/audit.sh | grep -q "^group::r--"'
verdict "an access list entry for the agent on a file of a group with a member" /work/m1 refuse
check "... the refusal names the file and the entry, not the group" bash -c 'grep -q "audit.sh: an access list entry gives agent write" /tmp/o && ! grep -q "writable by the group" /tmp/o'
fresh /work/m2; chgrp agentgrp /work/m2/lib/audit.sh; chmod 644 /work/m2/lib/audit.sh; setfacl -m u:root:rw /work/m2/lib/audit.sh
verdict "an access list whose only entry is root's, on a file of a group with a member" /work/m2 accept
fresh /work/m3; setfacl -m g:agentgrp:rw /work/m3/lib/audit.sh; verdict "an access list entry for a group with a member" /work/m3 refuse
check "... the refusal names the group entry" grep -q 'audit.sh: an access list entry gives the group agentgrp write' /tmp/o
# group root, with accounts that Fedora has and that Debian and Ubuntu do not
limit="$(sed -n 's/^UID_MIN[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' /etc/login.defs | head -1)"; limit="${limit:-1000}"
useradd -r -M -g 0 -s /usr/sbin/nologin sir96nologin; useradd -r -M -g 0 -s /bin/bash sir96locked
check "precondition: both new accounts are system accounts below $limit and sir96locked has a locked password" bash -c \
  '[ "$(id -u sir96nologin)" -lt "$1" ] && [ "$(id -u sir96locked)" -lt "$1" ] && getent shadow sir96locked | cut -d: -f2 | grep -q "^[!*]"' _ "$limit"
fresh /work/g1; chmod -R g+w /work/g1; verdict "group root can write, its other members are system accounts that cannot log in" /work/g1 accept
useradd -r -M -g 0 -s /bin/bash -p '$6$harness$notalockedpassword' sir96worker
fresh /work/g2; chmod -R g+w /work/g2; verdict "group root can write and a system account in it has a shell and a password" /work/g2 refuse
check "... and it names that account" grep -q 'which has other members: sir96worker' /tmp/o
userdel sir96worker 2>/dev/null; useradd -M -u 1500 -g 0 -s /usr/sbin/nologin sir96ordinary
fresh /work/g3; chmod -R g+w /work/g3; verdict "group root can write and an ordinary account (user number 1500) is in it" /work/g3 refuse
check "... and it names that account" grep -q 'which has other members: sir96ordinary' /tmp/o
userdel sir96ordinary 2>/dev/null
fresh /work/real7; chmod -R o+w /work/real7/tests; verdict "a world-writable folder inside the package that is not a code folder (the whole tree is judged)" /work/real7 refuse
fresh /work/real8; ln -s /etc /work/real8/lib/etc-link; verdict "a link inside the package to a folder outside it" /work/real8 refuse
fresh /work/real9; chown agent /work/real9/lib/common.sh; verdict "a library owned by the agent" /work/real9 refuse
fresh /work/real10; chmod o+w /work/real10; verdict "the package folder itself writable by everyone" /work/real10 refuse
finish
