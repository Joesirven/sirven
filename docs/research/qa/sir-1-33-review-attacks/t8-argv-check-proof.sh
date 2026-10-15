#!/usr/bin/env bash
# attack 8: the scenario 62 check "the key is on the command line of no process" must pass when no process has the key and fail
# when one does. a check written as 'ps | grep -F -- $KEY' finds its own grep, so it fails always; this one passes the key to awk
# through the environment. a dummy key only.
set -uo pipefail
. /src/docs/research/qa/sir-1-33-review-attacks/common.sh
export KEY="tskey""-auth-DUMMYargvproof0123456789-QQQQ"
export -f argv_has_no_key
check "no process has the key on its command line: the check passes" argv_has_no_key
bash -c 'sleep 30; :' "$KEY" &
holder=$!
sleep 1
check "a process started with the key on its command line: the check fails" bash -c '! argv_has_no_key'
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "the process is gone: the check passes again" argv_has_no_key
# the form that was in the scenario before: it fails with nothing running, because grep finds itself
check "the old form 'ps | grep -F -- KEY' finds its own grep with nothing running (shown, so it is not used again)" bash -c 'ps -eo args | grep -qF -- "$KEY"'
finish
