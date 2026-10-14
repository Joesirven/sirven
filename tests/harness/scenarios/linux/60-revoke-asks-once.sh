#!/usr/bin/env bash
# an interactive revoke on a real host asks one question, not two: the kill switch's own "type revoke" is the
# consent, and the generic "type yes" of the shared confirmation gate is not asked after it. a terminal is made
# with python's pty module, so the script under test has a real controlling terminal to read the answer from.
# a wrong answer changes nothing; with --yes and no terminal neither question is asked.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
. "$(dirname "$0")/../../lib/real_host.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
check "precondition: the install made the agent account" id -u agent

cat > /tmp/ask.py <<'P'
import os, pty, sys, select
answer = sys.argv[1].encode() + b"\n"
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "install.sh", "revoke", "--all", "--level", "observer", "--transport", "none", "--path", "/srv/app"])
out = b""
sent = False
while True:
    ready, _, _ = select.select([fd], [], [], 30)
    if not ready:
        os.kill(pid, 9)
        break
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
    if not sent and b"type revoke" in out:
        os.write(fd, answer)
        sent = True
_, status = os.waitpid(pid, 0)
open("/tmp/ask.out", "wb").write(out)
sys.exit(os.waitstatus_to_exitcode(status))
P

check_exit "a wrong answer to the revoke question stops the run (exit 2)" 2 python3 /tmp/ask.py no
check "the account is untouched by the wrong answer" bash -c '[ "$(getent passwd agent | cut -d: -f7)" != /usr/sbin/nologin ]'
check_exit "typing revoke applies (exit 0)" 0 python3 /tmp/ask.py revoke
check "exactly one question was asked: the revoke one" bash -c '[ "$(grep -c "type revoke" /tmp/ask.out)" = 1 ] && ! grep -q "type yes" /tmp/ask.out'
check "the account is locked" bash -c '[ "$(getent passwd agent | cut -d: -f7)" = /usr/sbin/nologin ]'
check_exit "without --yes and without a terminal revoke refuses before any change" 2 env SIRVEN_INTERACTIVE=no bash install.sh revoke --all --level observer --transport none --path /srv/app < /dev/null

finish
