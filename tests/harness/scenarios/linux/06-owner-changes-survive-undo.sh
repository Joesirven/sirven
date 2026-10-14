#!/usr/bin/env bash
# SIR-70 round 2, must fix 1. between install and uninstall the folder owner and root change owners,
# modes, and special bits of pre-existing paths, and root hardens the pass-through parent. undo must
# remove what the grant added and nothing else: every one of those changes must still be there afterwards.
# at the first round's tip (66e31fe) undo put the old owner, mode, and special bits back.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
useradd -m neighbor
mkdir -p /srv/work/sub /srv/work/dir2
chown -R owner:owner /srv/work
chmod 755 /srv/work /srv/work/sub /srv/work/dir2
echo doc > /srv/work/doc.txt && echo keep > /srv/work/sub/keep && echo run > /srv/work/suid.txt
echo moved > /srv/work/handed.txt && chown owner:owner /srv/work/doc.txt /srv/work/sub/keep /srv/work/suid.txt /srv/work/handed.txt
chmod 644 /srv/work/doc.txt /srv/work/sub/keep /srv/work/suid.txt /srv/work/handed.txt
# a pipe and a socket get the grant's entries too (setfacl -R reaches them), so undo must reach them without opening them
mkfifo /srv/work/pipe && python3 -c "import socket;s=socket.socket(socket.AF_UNIX);s.bind('/srv/work/sock')"
chown owner:owner /srv/work/pipe /srv/work/sock

check_exit "install builder on /srv/work applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work

# changes made while the grant is in force
runuser -u owner -- chmod 600 /srv/work/doc.txt
runuser -u owner -- chmod g+s,+t /srv/work/dir2
runuser -u owner -- chmod u+s /srv/work/suid.txt
chown neighbor:neighbor /srv/work/handed.txt && chmod 600 /srv/work/handed.txt && chmod u+x /srv/work/handed.txt
chmod 700 /srv
check "during the grant the owner's private file is private to another account" bash -c '! runuser -u neighbor -- cat /srv/work/doc.txt 2>/dev/null'

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh

stat_of() { stat -c '%a %U:%G' "$1"; }
check "the owner's chmod 600 stayed" bash -c '[ "$(stat -c "%a %U:%G" /srv/work/doc.txt)" = "600 owner:owner" ]'
check "another account still cannot read the owner's private file" bash -c '! runuser -u neighbor -- cat /srv/work/doc.txt 2>/dev/null'
check "setgid and sticky on a folder stayed (3755)" bash -c '[ "$(stat -c "%a %U:%G" /srv/work/dir2)" = "3755 owner:owner" ]'
check "setuid on a file stayed (4644)" bash -c '[ "$(stat -c "%a %U:%G" /srv/work/suid.txt)" = "4644 owner:owner" ]'
check "root's chown and chmod stayed (700 neighbor)" bash -c '[ "$(stat -c "%a %U:%G" /srv/work/handed.txt)" = "700 neighbor:neighbor" ]'
check "root's chmod 700 on the pass-through parent stayed" bash -c '[ "$(stat -c "%a %U:%G" /srv)" = "700 root:root" ]'
check "paths the owner did not touch are as they were (644 and 755)" \
  bash -c '[ "$(stat -c %a /srv/work/sub/keep)" = 644 ] && [ "$(stat -c %a /srv/work)" = 755 ] && [ "$(stat -c %a /srv/work/sub)" = 755 ]'
# a guard for the new walk, not a defect of 66e31fe (setfacl -b reached them): pipes and sockets are never opened
check "the pipe and the socket kept no entry for the agent" \
  bash -c '! getfacl -n -p /srv/work/pipe /srv/work/sock | grep -Eq "^(default:)?user:[0-9]+:"'
check "no permission list is left anywhere under /srv" bash -c '[ "$(python3 -I "$0/tests/harness/lib/aclraw.py" /srv | grep -vc " - -$")" = 0 ]' "$SRC"

finish
