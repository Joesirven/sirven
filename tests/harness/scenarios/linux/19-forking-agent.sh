#!/usr/bin/env bash
# SIR-70 round 3, should fix 3. an agent process that keeps starting others survives a single pkill pass. a level
# change must end every process of the agent, by repeating until none is left. at 1ce7450 one pass was made.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work && echo f > /srv/work/f && chown -R owner:owner /srv/work
check_exit "install observer applies" 0 bash install.sh --yes --level observer --transport none --path /srv/work
for round in 1 2 3; do
  setsid runuser -u agent -- bash -c 'while :; do sleep 100 & sleep 0.005; done' >/dev/null 2>&1 &
  sleep 0.3
  check "round $round precondition: the agent has processes" pgrep -u agent
  level=builder; [ "$round" = 2 ] && level=observer
  check_exit "round $round: a level change applies" 0 bash install.sh --yes --level "$level" --transport none --path /srv/work
  check "round $round: no process of the agent is left" bash -c '! pgrep -u agent'
done
finish
