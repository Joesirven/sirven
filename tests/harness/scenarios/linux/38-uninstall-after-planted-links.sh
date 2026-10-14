#!/usr/bin/env bash
# SIR-32. uninstall removes the agent's key files and .ssh folder as root, in a home folder the agent owns. a plain
# uninstall (no revoke before it) must not follow a link the agent planted there:
#   (1) authorized_keys is a link to root's own key file: the name is removed, root's file is left exactly as it was.
#   (2) the whole .ssh folder is a link to a root-owned folder that holds an authorized_keys: the link name is removed
#       from the home folder, and the folder it pointed at is not opened, emptied or removed.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt
mkdir -p /root/.ssh && echo 'ssh-ed25519 AAAAroot root-key' > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
mkdir -p /opt/victim-ssh && echo 'ssh-ed25519 AAAAdir dir-key' > /opt/victim-ssh/authorized_keys && chmod 700 /opt/victim-ssh && chmod 600 /opt/victim-ssh/authorized_keys
victims="/root/.ssh /opt/victim-ssh"
world_aclraw_attributes $victims > /tmp/victims.before
sha256sum /root/.ssh/authorized_keys /opt/victim-ssh/authorized_keys > /tmp/victims.sums
uninstalled() { ! getent passwd agent >/dev/null; }
sums_same_after_uninstall() { uninstalled && sha256sum -c --status /tmp/victims.sums; }
as_agent() { setpriv --reuid="$(id -u agent)" --regid="$(id -g agent)" --clear-groups "$@"; }

# (1) the key file is a link to root's
check_exit "install applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check "(1) the agent replaces authorized_keys with a link to root's key file" as_agent sh -c '
  rm -f /home/agent/.ssh/authorized_keys && ln -s /root/.ssh/authorized_keys /home/agent/.ssh/authorized_keys'
check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
check "(1) the account and the link are gone" bash -c '! getent passwd agent && [ ! -e /home/agent/.ssh/authorized_keys ] && [ ! -L /home/agent/.ssh/authorized_keys ]'
check "(1) root's key file still has its key and its content" sums_same_after_uninstall
world_unchanged_if uninstalled "(1) root's ssh folder keeps owner, mode and lists" aclraw_attributes /tmp/victims.before $victims

# (2) the whole .ssh folder is a link
check_exit "install applies again" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check "(2) the agent swaps its .ssh folder for a link to a root-owned folder" as_agent sh -c '
  mv /home/agent/.ssh /home/agent/.ssh.real && ln -s /opt/victim-ssh /home/agent/.ssh'
check "precondition: the key file is reachable through the link" test -s /home/agent/.ssh/authorized_keys
check_exit "uninstall applies again" 0 bash /var/lib/sirven/package/uninstall.sh
check "(2) the account is gone and the .ssh link is gone from the home folder" bash -c '! getent passwd agent && [ ! -L /home/agent/.ssh ]'
check "(2) the folder it pointed at still has its key file" sums_same_after_uninstall
world_unchanged_if uninstalled "(2) the folder keeps owner, mode and lists" aclraw_attributes /tmp/victims.before $victims
check "the agent's own real .ssh folder, moved aside, is left in its kept home" test -d /home/agent/.ssh.real

finish
