#!/usr/bin/env bash
# SIR-32, from the review (b2-residuals, c1-cron-at; S3). the agent's crontab and at jobs are removed, with an audit
# entry, and another account's jobs are left alone. a second run has nothing to do.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
useradd -m other
mkdir -p /var/spool/cron/crontabs /var/spool/cron/atjobs
printf '* * * * * touch /tmp/cron-ran\n' > /tmp/agent.cron; printf '* * * * * touch /tmp/other-cron-ran\n' > /tmp/other.cron
check "precondition: the agent has a crontab" crontab -u agent /tmp/agent.cron
check "precondition: another account has one" crontab -u other /tmp/other.cron
check "precondition: the agent has an at job" runuser -u agent -- sh -c 'echo "touch /tmp/at-ran" | at now + 1 hour'
check "precondition: another account has an at job" runuser -u other -- sh -c 'echo "touch /tmp/other-at-ran" | at now + 1 hour'
check "precondition: atq lists a job of the agent" bash -c 'atq | awk "\$NF == \"agent\"" | grep -q .'

check_exit "revoke applies" 0 bash install.sh revoke --all --yes --transport none
check "the agent's crontab is gone" bash -c '! crontab -l -u agent && [ ! -e /var/spool/cron/crontabs/agent ]'
check "the agent's at jobs are gone" bash -c 'jobs="$(atq | awk "\$NF == \"agent\"")"; [ -z "$jobs" ] && [ -f /etc/sirven/grants/agent.json.revoked ]'
check "the other account's crontab and at job are left alone" bash -c 'crontab -l -u other | grep -q other-cron-ran && atq | awk "\$NF == \"other\"" | grep -q .'
check "the audit log says what was removed" bash -c 'grep "\"event\": \"revoke_detail\"" /var/log/sirven/audit.jsonl | grep -q "removed the crontab of agent, removed 1 at job"'
check_exit "a second revoke has no job to remove" 0 bash install.sh revoke --all --yes --transport none
check "and the second run skipped that step as already done" bash -c 'grep -A1 "remove the cron and at jobs" <<< "$0" | grep -q "already done"' "$LAST_OUTPUT"

finish
