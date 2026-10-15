#!/usr/bin/env bash
# install, then uninstall from the pinned copy (as a user would, without the repository), and
# compare the whole machine with how it was before. allowed leftovers are named in lib/world.sh.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt
# decided before the snapshot, because the probe makes and removes a throwaway account (see lib/world.sh)
makes_spool=no
world_account_gets_spool && makes_spool=yes
world_files > /tmp/before.files
world_accounts > /tmp/before.accounts
world_acls /srv > /tmp/before.acls

check_exit "install applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check_exit "uninstall from the pinned copy applies" 0 bash /var/lib/sirven/package/uninstall.sh

check "service user is gone" bash -c '! getent passwd agent && ! getent group agent'
check "its home is kept on purpose" test -d /home/agent
check "audit log is kept on purpose" test -s /var/log/sirven/audit.jsonl
if [ "$makes_spool" = yes ]; then
  check "service user's mail spool is gone after the uninstall (this image makes one)" world_mail_spool_gone agent
else
  skip "service user's mail spool gone after the uninstall" "this image's account tool makes no mail spool"
fi
world_unchanged "files match the machine before the install" files /tmp/before.files
world_unchanged "accounts match the machine before the install" accounts /tmp/before.accounts
# finding of the first real run, 2026-10-13, fixed by the snapshot and restore: the access control lists
# of the granted folder, of everything inside it, and of the parent folder are back exactly as before.
world_unchanged "access control lists match the machine before the install" acls /tmp/before.acls /srv
# a file made under umask 077 after uninstall is private again, because no default list is left.
check "after uninstall a new file made under umask 077 is private (mode 600)" \
  bash -c 'umask 077; touch /srv/app/private; [ "$(stat -c %a /srv/app/private)" = 600 ]'

finish
