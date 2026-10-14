#!/usr/bin/env bash
# control for cron: a normal account (default locked password, as useradd leaves it) runs its job; after the kill switch's
# own account changes (lock, expiry 1, nologin shell) does cron still run it?
set -uo pipefail
. /src/tests/harness/lib/world.sh
useradd -m ctl
chmod 1777 /tmp
printf '* * * * * touch /tmp/cron-ran-$(date +%%s)\n' > /tmp/ct && crontab -u ctl /tmp/ct
sed -i 's/^session .*pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/cron
setsid cron -f -L 15 >/tmp/cron.log 2>&1 &
sleep 1
for i in $(seq 1 75); do ls /tmp/cron-ran-* >/dev/null 2>&1 && break; sleep 1; done
echo "control: cron ran the job $(ls /tmp/cron-ran-* 2>/dev/null | wc -l) time(s) for a normal account"
rm -f /tmp/cron-ran-*
usermod --lock ctl; usermod --expiredate 1 ctl; usermod --shell /usr/sbin/nologin ctl
echo "waiting 130 s..."; sleep 130
echo "after lock+expiry+nologin: cron ran the job $(ls /tmp/cron-ran-* 2>/dev/null | wc -l) time(s)"; tail -4 /tmp/cron.log
rm -f /tmp/cron-ran-*; usermod --expiredate '' ctl; usermod --unlock ctl; usermod --shell /bin/bash ctl
echo "waiting 70 s after giving the account back..."; sleep 70
echo "after reinstating: cron ran the job $(ls /tmp/cron-ran-* 2>/dev/null | wc -l) time(s)"
