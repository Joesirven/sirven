#!/usr/bin/env bash
# attack 1 residuals: what the agent leaves behind or can still do after a finished revoke --all.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app/sub && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
A() { runuser -u agent -- "$@"; }
# things the agent plants before the kill switch
A bash -c 'cp /bin/sleep ~/sleep-copy; mkdir -p /srv/app/dropbox; chmod 0777 /srv/app/dropbox; echo "#!/bin/sh" > /srv/app/dropbox/run.sh; chmod 0755 /srv/app/dropbox/run.sh; echo "#!/bin/sh
touch /tmp/hook-ran" > ~/.ssh/rc; echo x > /srv/app/sub/created-by-agent'
mkdir -p /var/spool/cron/crontabs /var/spool/cron/atjobs
printf '* * * * * touch /tmp/cron-ran\n' > /var/spool/cron/crontabs/agent; chown agent:crontab /var/spool/cron/crontabs/agent 2>/dev/null || chown agent /var/spool/cron/crontabs/agent
# a supervisor of the owner's, started as root, that starts the agent's work again every second (as a systemd unit with Restart=always would)
setsid bash -c 'while :; do pgrep -u agent -f supervised >/dev/null || setpriv --reuid=agent --regid=agent --clear-groups bash -c "exec -a supervised sleep 3000" & sleep 1; done' >/dev/null 2>&1 &
sleep 2
echo "agent processes before: $(pgrep -u agent | wc -l)"
bash install.sh revoke --all --yes --transport none > /tmp/rev.out 2>&1; echo "revoke exit $?"
sleep 3
echo "agent processes 3 s after revoke finished: $(pgrep -u agent | wc -l)   $(pgrep -u agent -a | head -2 | tr '\n' ';')"
echo "crontab left: $(ls -l /var/spool/cron/crontabs/ | tail -n +2 | awk '{print $9}' | tr '\n' ' ')"
echo "setuid/agent-owned files left in the granted folder: $(find /srv/app -user agent | tr '\n' ' ')"
echo "acl entries for agent on /srv/app: $(getfacl -p -R /srv/app 2>/dev/null | grep -c 'user:agent')"
echo "default acl on dropbox: $(getfacl -p /srv/app/dropbox | tr '\n' ' ')"
echo "can another account write into the 0777 dropbox? yes, by mode; and the agent's own files stay agent-owned"
echo "audit tail:"; tail -3 /var/log/sirven/audit.jsonl | cut -c1-260
check "no agent process after the kill switch finished" bash -c '! pgrep -u agent'
check "the agent's crontab is gone" bash -c '[ ! -e /var/spool/cron/crontabs/agent ]'
finish
