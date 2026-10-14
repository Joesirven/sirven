#!/usr/bin/env bash
# attack 1: a key in a nonstandard AuthorizedKeysFile the agent owns, ~/.ssh/rc, and a ControlMaster socket, against a revoked account.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
mkdir -p /tmp/k && ssh-keygen -q -t ed25519 -N '' -f /tmp/k/id
runuser -u agent -- bash -c 'cp /tmp/k/id.pub ~/.mykeys; chmod 600 ~/.mykeys'
ssh-keygen -A >/dev/null 2>&1; mkdir -p /run/sshd
/usr/sbin/sshd -p 2223 -o ListenAddress=127.0.0.1 -o PidFile=/tmp/sshd2.pid -o 'AuthorizedKeysFile=.mykeys' -o UsePAM=no
sleep 1
cli() { ssh -p 2223 -i /tmp/k/id -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@" agent@127.0.0.1; }
check "precondition: a login with the key in ~/.mykeys works (UsePAM no)" bash -c '[ "$(ssh -p 2223 -i /tmp/k/id -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR agent@127.0.0.1 id -un)" = agent ]'
# a master connection with a control socket
setsid ssh -p 2223 -i /tmp/k/id -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlMaster=yes -o ControlPath=/tmp/cm.sock -o ControlPersist=600 -N agent@127.0.0.1 >/dev/null 2>&1 &
sleep 2
echo "procs before: $(pgrep -u agent | wc -l)"
bash install.sh revoke --all --yes --transport none > /tmp/rev.out 2>&1; echo "revoke exit $?"
echo "procs after: $(pgrep -u agent | wc -l)"
out="$(ssh -p 2223 -i /tmp/k/id -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=INFO agent@127.0.0.1 id -un 2>&1)"; st=$?
echo "login with the nonstandard key file, UsePAM no: exit $st: $out" | head -3
check "a login through a nonstandard key file is refused" test "$st" -ne 0
# the control socket
out="$(ssh -S /tmp/cm.sock -O check agent@127.0.0.1 2>&1)"; echo "control socket: $out"
finish
