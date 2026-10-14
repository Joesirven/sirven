#!/usr/bin/env bash
# round 3 (b): the whole-tree vet. each variant is a fresh root-owned copy with ONE thing wrong; no kept copy exists, so the gate judges the
# folder it starts from. expected: refuse (exit 2) unless the label says accept.
set -uo pipefail
. /src/tests/harness/lib/world.sh
useradd -m agent
run() { ( cd "$1" && timeout 120 bash install.sh --dry-run --level observer --transport none > /tmp/o 2>&1; echo $? ); }
fresh() { rm -rf "$1"; mkdir -p "$(dirname "$1")"; cp -r "$SRC" "$1"; chown -R root:root "$1"; }
v() {  # LABEL FOLDER WANT
  local st; started=$SECONDS; st="$(run "$2")"
  if [ "$3" = refuse ]; then
    if [ "$st" = 2 ] && grep -q 'refusing to run' /tmp/o; then pass "$1: refused ($((SECONDS-started)) s)"; else fail "$1: wanted a refusal, exit $st" "$(head -3 /tmp/o | cut -c1-200)"; fi
  else
    if [ "$st" = 0 ]; then pass "$1: accepted ($((SECONDS-started)) s)"; else fail "$1: wanted accept, exit $st" "$(head -3 /tmp/o | cut -c1-200)"; fi
  fi
}
fresh /work/v1; d=/work/v1/lib; for i in $(seq 1 30); do d=$d/sub$i; done; mkdir -p $d; touch $d/f; chmod 666 $d/f; v "writable file 30 folders deep" /work/v1 refuse
fresh /work/v2; mkfifo -m 666 /work/v2/lib/pipe; v "a pipe, mode 666" /work/v2 refuse
fresh /work/v2b; mkfifo -m 600 /work/v2b/lib/pipe; v "a pipe, mode 600, root-owned" /work/v2b accept
fresh /work/v3; python3 -c 'import socket;s=socket.socket(socket.AF_UNIX);s.bind("/work/v3/lib/sock")'; chown agent /work/v3/lib/sock; v "a socket owned by the agent" /work/v3 refuse
fresh /work/v3b; python3 -c 'import socket;s=socket.socket(socket.AF_UNIX);s.bind("/work/v3b/lib/sock")'; chmod 666 /work/v3b/lib/sock; v "a socket, mode 666, root-owned" /work/v3b refuse
fresh /work/v4; mknod -m 666 /work/v4/lib/nul c 1 3 2>/dev/null; v "a device node, mode 666" /work/v4 refuse
fresh /work/v5; echo x > /home/agent/own; chown agent /home/agent/own; ln /home/agent/own /work/v5/lib/hard; v "a hard link to a file the agent owns" /work/v5 refuse
fresh /work/v5b; ln /work/v5b/lib/common.sh /home/agent/link-to-common; chmod 755 /home; v "a package file also linked from the agent's folder (root-owned inode)" /work/v5b accept
before="$(md5sum < /work/v5b/lib/common.sh)"; runuser -u agent -- bash -c 'echo evil >> /home/agent/link-to-common' 2>/dev/null; [ "$(md5sum < /work/v5b/lib/common.sh)" = "$before" ] && pass "v5b: the agent cannot change the file through its link" || fail "v5b: the agent changed a package file through a hard link"
fresh /work/v6; ln -s /etc/passwd /work/v6/lib/out; v "a link to a file outside the package" /work/v6 refuse
fresh /work/v6b; ln -s ../levels /work/v6b/lib/in; ln -s .. /work/v6b/lib/up; v "links that stay inside the package (one points at the root of it)" /work/v6b accept
fresh /work/v7; chmod o+w /work/v7/levels; v "a world-writable folder (levels)" /work/v7 refuse
fresh /work/v8; touch /work/v8/.hidden; chown agent /work/v8/.hidden; v "a hidden file owned by the agent" /work/v8 refuse
fresh /work/v9; d=/work/v9/lib; python3 - "$d" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
for i in range(1500):
    os.mkdir("d", dir_fd=fd)
    fd2 = os.open("d", os.O_RDONLY | os.O_DIRECTORY, dir_fd=fd); os.close(fd); fd = fd2
os.close(fd)
PY
v "1500 folders deep, all root's" /work/v9 refuse
head -3 /tmp/o | cut -c1-160
fresh /work/v10; d=/work/v10/lib; python3 - "$d" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
for i in range(300):
    os.mkdir("d", dir_fd=fd)
    fd2 = os.open("d", os.O_RDONLY | os.O_DIRECTORY, dir_fd=fd); os.close(fd); fd = fd2
fd3 = os.open("f", os.O_WRONLY | os.O_CREAT, 0o666, dir_fd=fd); os.fchmod(fd3, 0o666); os.close(fd3)
PY
v "a writable file 300 folders deep" /work/v10 refuse
finish
