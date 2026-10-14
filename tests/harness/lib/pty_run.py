"""pty_run.py PROMPT ANSWER COMMAND...: run COMMAND on a pseudo-terminal, as a person at a keyboard
would have it. when PROMPT appears in the output, type ANSWER and a newline. prints everything the
terminal showed and exits with the command's own exit status (124 if it goes quiet for a minute).
used by the real-host scenarios to test the typed-yes path against the real terminal detection."""
import os
import pty
import select
import signal
import sys

prompt, answer = sys.argv[1].encode(), sys.argv[2].encode()
command = sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
seen = b""
typed = False
while True:
    ready, _, _ = select.select([fd], [], [], 60)
    if not ready:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        sys.stdout.buffer.write(seen)
        sys.exit(124)
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    seen += data
    if not typed and prompt in seen:
        os.write(fd, answer + b"\n")
        typed = True
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(seen)
sys.exit(os.waitstatus_to_exitcode(status))
