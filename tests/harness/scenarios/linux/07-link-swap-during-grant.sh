#!/usr/bin/env bash
# SIR-70 round 2, must fix 2. the agent, with only the access the grant gave it, replaces a folder in the
# granted tree with a symbolic link to a root-only folder. undo must not follow the link: the target keeps
# its owner, mode, and lists, and the audit log says the recorded folder was no longer there. at 66e31fe
# undo ran as root through the link and gave /opt/victim to the folder owner.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work/sub && echo f > /srv/work/sub/f && chown -R owner:owner /srv/work
mkdir -p /opt/victim && echo secret > /opt/victim/f && chmod 700 /opt/victim && chmod 600 /opt/victim/f
world_aclraw_attributes /opt/victim > /tmp/victim.before

check_exit "install builder on /srv/work applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check "precondition: a process of agent is running" pgrep -u agent
check "the agent swaps a folder for a link to /opt/victim" \
  runuser -u agent -- sh -c 'mv /srv/work/sub /srv/work/sub.old && ln -s /opt/victim /srv/work/sub'

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
world_unchanged "the link target is exactly as it was: owner, mode, and lists" aclraw_attributes /tmp/victim.before /opt/victim
check "the link target is still root 700" bash -c '[ "$(stat -c "%a %U:%G" /opt/victim)" = "700 root:root" ]'
check "the moved folder itself was cleaned (no entry for the agent left)" \
  bash -c '! getfacl -R -n -p /srv/work/sub.old 2>/dev/null | grep -Eq "^(default:)?user:[0-9]+:"'
check "the audit log has a warning that names the replaced folder" \
  bash -c 'grep "\"event\": \"warning\"" /var/log/sirven/audit.jsonl | grep -q "/srv/work/sub"'
check "no process of agent remains" bash -c '! pgrep -u agent'

finish
