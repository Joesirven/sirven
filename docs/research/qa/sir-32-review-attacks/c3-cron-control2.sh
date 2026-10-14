#!/usr/bin/env bash
# control for cron with a real password hash: does cron still run an account's job after (a) lock only, (b) lock + expiry 1?
set -uo pipefail
useradd -m ctl
hash="$(python3 -W ignore -c 'import crypt; print(crypt.crypt("x", "$6$saltsalt"))')"
usermod -p "$hash" ctl
chmod 1777 /tmp
printf '* * * * * touch /tmp/cron-ran-$(date +%%s)\n' > /tmp/ct && crontab -u ctl /tmp/ct
sed -i 's/^session .*pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/cron
setsid cron -f -L 15 >/tmp/cron.log 2>&1 &
sleep 1
tick() { rm -f /tmp/cron-ran-*; for i in $(seq 1 70); do ls /tmp/cron-ran-* >/dev/null 2>&1 && break; sleep 1; done; ls /tmp/cron-ran-* 2>/dev/null | wc -l; }
echo "normal account with a password: cron ran the job $(tick) time(s)"
usermod --lock ctl;  echo "after lock only: $(tick)"
usermod --expiredate 1 ctl; echo "after lock + expiry 1: $(tick)"
usermod --shell /usr/sbin/nologin ctl; echo "after lock + expiry 1 + nologin shell: $(tick)"
tail -3 /tmp/cron.log
