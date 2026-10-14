#!/usr/bin/env bash
# round 2: cron and at removal with the real commands (the image has cron and at).
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
printf '* * * * * touch /tmp/cron-ran\n' > /tmp/ct; crontab -u agent /tmp/ct
echo "touch /tmp/at-ran" > /tmp/atjob; runuser -u agent -- at -f /tmp/atjob now + 1 hour 2>&1 | tail -1
echo "touch /tmp/at-ran-b" > /tmp/atjob2; runuser -u agent -- at -q b -f /tmp/atjob2 now + 2 hours 2>&1 | tail -1
printf '* * * * * touch /tmp/other\n' > /tmp/ct2; useradd -m other; crontab -u other /tmp/ct2
echo "before: agent crontab $(crontab -l -u agent 2>&1 | wc -l) lines; atq: $(atq | wc -l) jobs"
bash install.sh revoke --all --yes --transport none > /tmp/rev.out 2>&1; echo "revoke exit $?"
grep -E "removed|crontab|at job" /tmp/rev.out | head -5
echo "after: agent crontab: $(crontab -l -u agent 2>&1 | head -1); atq: $(atq | wc -l) jobs; other's crontab: $(crontab -l -u other 2>&1 | wc -l) lines"
ls /var/spool/cron/crontabs /var/spool/cron/atjobs 2>&1 | tr '\n' ' '; echo
grep -c '"operation": "revoke"' /var/log/sirven/audit.jsonl; grep revoke_detail /var/log/sirven/audit.jsonl | cut -c1-240
check "the agent's crontab is gone" bash -c '! crontab -l -u agent >/dev/null 2>&1'
check "the agent's at jobs are gone" bash -c '[ "$(atq | wc -l)" = 0 ]'
check "another account's crontab is untouched" bash -c 'crontab -l -u other | grep -q /tmp/other'
finish
