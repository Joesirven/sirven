#!/usr/bin/env bash
# SIR-32. the agent plants symbolic links, then the owner runs the kill switch as root. nothing may be followed:
#   (1) authorized_keys and authorized_keys2 are links to root-owned files. emptying a key file by path would have
#       truncated the targets; the names must be removed and the targets left exactly as they were.
#   (2) links inside the granted folder to a root-only file and a root-only folder. the undo walks by descriptor,
#       so the targets keep their owner, mode and lists, and the agent's entries still come off the granted folder.
#   (3) the whole .ssh folder swapped for a link to a root-owned folder that holds an authorized_keys. the link name
#       is removed from the home folder; the folder it pointed at is not opened.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work/sub && echo f > /srv/work/sub/f && chown -R owner:owner /srv/work
mkdir -p /root/.ssh && echo 'ssh-ed25519 AAAAroot root-key' > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
echo 'victim file' > /etc/victim-file && chmod 640 /etc/victim-file
mkdir -p /opt/victim-tree/inner && echo secret > /opt/victim-tree/inner/f && chmod 700 /opt/victim-tree /opt/victim-tree/inner && chmod 600 /opt/victim-tree/inner/f
mkdir -p /opt/victim-ssh && echo 'ssh-ed25519 AAAAdir dir-key' > /opt/victim-ssh/authorized_keys && chmod 700 /opt/victim-ssh && chmod 600 /opt/victim-ssh/authorized_keys
victims="/root/.ssh /etc/victim-file /opt/victim-tree /opt/victim-ssh"   # plain names, split on purpose
world_aclraw_attributes $victims > /tmp/victims.before
sha256sum /root/.ssh/authorized_keys /etc/victim-file /opt/victim-tree/inner/f /opt/victim-ssh/authorized_keys > /tmp/victims.sums
sums_same() { sha256sum -c --status /tmp/victims.sums; }
# the kill switch has really run: only then does "the targets are exactly as they were" mean anything
revoke_ran() { [ -f /etc/sirven/grants/agent.json.revoked ]; }
sums_same_after_revoke() { revoke_ran && sums_same; }

check_exit "install builder on /srv/work applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
as_agent() { setpriv --reuid="$(id -u agent)" --regid="$(id -g agent)" --clear-groups --init-groups "$@" 2>/dev/null || setpriv --reuid="$(id -u agent)" --regid="$(id -g agent)" --clear-groups "$@"; }
check "(1) the agent replaces both key files with links to root's files" as_agent sh -c '
  rm -f /home/agent/.ssh/authorized_keys /home/agent/.ssh/authorized_keys2 &&
  ln -s /root/.ssh/authorized_keys /home/agent/.ssh/authorized_keys &&
  ln -s /etc/victim-file /home/agent/.ssh/authorized_keys2'
check "(2) the agent plants links inside the granted folder" as_agent sh -c '
  ln -s /etc/victim-file /srv/work/filelink && ln -s /opt/victim-tree /srv/work/treelink &&
  ln -s /opt/victim-tree/inner /srv/work/sub/innerlink'
check "precondition: the link leads to root's own key file" bash -c '[ "$(readlink -f /home/agent/.ssh/authorized_keys)" = /root/.ssh/authorized_keys ]'
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3

check_exit "revoke --all applies" 0 bash install.sh revoke --all --yes --transport none
check "(1) both link names are gone, and root's key file and the other target are exactly as they were" bash -c '
  [ ! -e /home/agent/.ssh/authorized_keys ] && [ ! -L /home/agent/.ssh/authorized_keys ] &&
  [ ! -e /home/agent/.ssh/authorized_keys2 ] && [ ! -L /home/agent/.ssh/authorized_keys2 ]' 
check "(1) the key in root's authorized_keys is still there" bash -c '[ -f /etc/sirven/grants/agent.json.revoked ] && grep -q AAAAroot /root/.ssh/authorized_keys'
check "(1) the victim file still says what it said" bash -c '[ -f /etc/sirven/grants/agent.json.revoked ] && grep -qx "victim file" /etc/victim-file'
check "(2) the agent's entry is off the granted folder and everything real inside it" bash -c '
  ! getfacl -R -n -p -P /srv/work 2>/dev/null | grep -Eq "^(default:)?user:[0-9]+:"'
check "(2) the links in the granted folder were not followed and are still links" bash -c '
  [ -f /etc/sirven/grants/agent.json.revoked ] && [ -L /srv/work/filelink ] && [ -L /srv/work/treelink ] && [ -L /srv/work/sub/innerlink ]'
world_unchanged_if revoke_ran "(1) (2) the targets keep owner, mode and lists exactly" aclraw_attributes /tmp/victims.before $victims
check "(1) (2) the targets keep their content" sums_same_after_revoke
check "(2) no entry of the agent on any target" bash -c '[ -f /etc/sirven/grants/agent.json.revoked ] && ! getfacl -R -n -p -P /opt/victim-tree /etc/victim-file /root/.ssh 2>/dev/null | grep -Eq "^(default:)?user:[0-9]+:"'

# (3) the whole .ssh folder swapped for a link. the account is already locked; the scenario plants as the agent's uid.
check "(3) the agent swaps its .ssh folder for a link to a root-owned folder" as_agent sh -c '
  mv /home/agent/.ssh /home/agent/.ssh.real && ln -s /opt/victim-ssh /home/agent/.ssh'
check "precondition: the key file is reachable through the link" test -s /home/agent/.ssh/authorized_keys
revoke_ran() { [ "$(grep -c "\"event\": \"revoke_finished\"" /var/log/sirven/audit.jsonl)" = 2 ]; }
check_exit "revoke --all applies again" 0 bash install.sh revoke --all --yes --transport none
check "(3) the .ssh link is gone from the home folder, and the folder it pointed at is untouched" bash -c '
  [ ! -L /home/agent/.ssh ] && [ -s /opt/victim-ssh/authorized_keys ] && grep -q AAAAdir /opt/victim-ssh/authorized_keys'
world_unchanged_if revoke_ran "(3) the folder keeps owner, mode and lists exactly" aclraw_attributes /tmp/victims.before $victims
check "(3) all targets keep their content" sums_same_after_revoke

finish
