#!/usr/bin/env bash
# install, then uninstall from the pinned copy (as a user would, without the repository), and
# compare the whole machine with how it was before. allowed leftovers are named in lib/world.sh.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt
world_files > /tmp/before.files
world_accounts > /tmp/before.accounts
world_acls /srv > /tmp/before.acls

check_exit "install applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check_exit "uninstall from the pinned copy applies" 0 bash /var/lib/sirven/package/uninstall.sh

check "service user is gone" bash -c '! getent passwd agent && ! getent group agent'
check "its home is kept on purpose" test -d /home/agent
check "audit log is kept on purpose" test -s /var/log/sirven/audit.jsonl
world_unchanged "files match the machine before the install" files /tmp/before.files
world_unchanged "accounts match the machine before the install" accounts /tmp/before.accounts
# finding of the first real run, 2026-10-13: the named entry is removed but a default list stays on
# the granted folder and a mask on every file in it, and on the parent (/srv), so new files ignore
# the owner's umask. SIR-70 owns it.
known_defect "permission lists match the machine before the install" SIR-70 \
  bash -c '. "$0"; world_acls /srv | diff -q /tmp/before.acls - >/dev/null' "$(dirname "$0")/../../lib/world.sh"
known_defect "a new file in the granted folder follows the owner's umask 077" SIR-70 \
  bash -c 'umask 077; touch /srv/app/private; [ "$(stat -c %a /srv/app/private)" = 600 ]'

finish
