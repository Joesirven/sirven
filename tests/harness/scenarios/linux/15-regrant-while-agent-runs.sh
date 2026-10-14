#!/usr/bin/env bash
# SIR-70 round 2, the grant direction. a rollback (and a level-change re-install) grants again while the
# agent's account may be running. the grant must not follow a link the agent planted: before the rollback the
# agent swaps a folder for a link to a root-only folder, and a loop keeps swapping during it. the target must be
# unchanged, the agent's processes must be ended while the access changes, and its account must be back after.
# at 66e31fe the removal followed the link, and nothing ended the agent.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work/sub /srv/work/other && echo f > /srv/work/sub/f && chown -R owner:owner /srv/work
mkdir -p /opt/victim && echo secret > /opt/victim/f && chmod 700 /opt/victim && chmod 600 /opt/victim/f
world_aclraw_attributes /opt/victim > /tmp/victim.before

check_exit "install observer applies" 0 bash install.sh --yes --level observer --transport none --path /srv/work
check_exit "install builder (a level change, the grant again) applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work

# the agent plants the link, and keeps swapping while the rollback runs
runuser -u agent -- sh -c 'mv /srv/work/sub /srv/work/sub.old && ln -s /opt/victim /srv/work/sub'
setsid runuser -u agent -- bash -c 'while :; do mv /srv/work/other /srv/work/other.old 2>/dev/null && ln -s /opt/victim /srv/work/other 2>/dev/null; rm -f /srv/work/other 2>/dev/null; mv /srv/work/other.old /srv/work/other 2>/dev/null; done' >/dev/null 2>&1 &
sleep 0.3
check "precondition: a process of agent is running" pgrep -u agent

check_exit "rollback applies" 0 bash /var/lib/sirven/package/bin/sirven grant rollback
world_unchanged "the link target is exactly as it was: owner, mode, and lists" aclraw_attributes /tmp/victim.before /opt/victim
check "the link target is still root 700" bash -c '[ "$(stat -c "%a %U:%G" /opt/victim)" = "700 root:root" ]'
check "the agent's processes were ended while the access changed" bash -c '! pgrep -u agent'
check "the audit log has a warning about the replaced folder" \
  bash -c 'grep "\"event\": \"warning\"" /var/log/sirven/audit.jsonl | grep -q "/srv/work/sub"'
check "the agent's account is back as it was: password login off, never expires" \
  bash -c '[ "$(getent shadow agent | cut -d: -f2)" = "*" ] && [ -z "$(getent shadow agent | cut -d: -f8)" ]'
check "the earlier level (observer) is back: the agent can read the folder it moved" runuser -u agent -- cat /srv/work/sub.old/f
check "and cannot write there any more" bash -c '! runuser -u agent -- sh -c "echo x > /srv/work/sub.old/by-agent" 2>/dev/null'

finish
