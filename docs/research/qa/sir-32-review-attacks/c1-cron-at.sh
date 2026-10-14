#!/usr/bin/env bash
# attack 1: cron and at jobs of the agent. a control tick before the revoke proves cron runs jobs here; then does a job of a
# revoked (locked, expired, nologin) account still run?
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd /src || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
mkdir -p /var/spool/cron/crontabs; 
printf '* * * * * touch /tmp/cron-ran-$(date +%%s) 2>/dev/null\n' > /tmp/ct && crontab -u agent /tmp/ct
chmod 1777 /tmp
sed -i 's/^session .*pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/cron /etc/pam.d/atd 2>/dev/null
setsid cron -f -L 15 >/tmp/cron.log 2>&1 &
setsid atd -f >/tmp/atd.log 2>&1 &
sleep 1
echo "touch /tmp/at-ran-\$(date +%s)" > /tmp/atjob; runuser -u agent -- at -f /tmp/atjob now + 2 minutes 2>&1 | tail -1
echo "waiting for a control tick..."
for i in $(seq 1 75); do ls /tmp/cron-ran-* >/dev/null 2>&1 && break; sleep 1; done
control="$(ls /tmp/cron-ran-* 2>/dev/null | wc -l)"; echo "control: cron ran the agent's job $control time(s) before the revoke"
bash install.sh revoke --all --yes --transport none > /tmp/rev.out 2>&1; echo "revoke exit $?"
rm -f /tmp/cron-ran-*
echo "crontab after revoke: $(ls /var/spool/cron/crontabs/ | tr '\n' ' ');  at queue: $(ls /var/spool/cron/atjobs/ 2>/dev/null | tr '\n' ' ')"
echo "waiting 130 s for cron and at to try again..."
sleep 130
echo "after the revoke: cron ran the agent's job $(ls /tmp/cron-ran-* 2>/dev/null | wc -l) time(s); at ran $(ls /tmp/at-ran-* 2>/dev/null | wc -l) time(s)"
echo "cron log:"; tail -8 /tmp/cron.log; echo "atd log:"; tail -4 /tmp/atd.log
check "the control tick ran" test "$control" -ge 1
check "no cron job of the revoked agent ran after the revoke" bash -c '! ls /tmp/cron-ran-* >/dev/null 2>&1'
check "no at job of the revoked agent ran" bash -c '! ls /tmp/at-ran-* >/dev/null 2>&1'
check "the agent has no crontab left" bash -c '[ ! -e /var/spool/cron/crontabs/agent ]'
finish
