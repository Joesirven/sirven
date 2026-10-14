#!/usr/bin/env bash
# the owner deletes a file while the grant is in force; uninstall must still apply, and the
# access control lists of the folder and its parent must be back exactly as they were, for
# everything that still exists. the deleted file cannot come back, so its entry is left out
# of the expectation.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt && echo gone > /srv/app/gone.txt
getfacl -R -p /srv > /tmp/before.acls

check_exit "install observer on /srv/app applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
rm -f /srv/app/gone.txt
check_exit "uninstall applies after a file was deleted during the grant" 0 bash /var/lib/sirven/package/uninstall.sh

awk 'BEGIN { RS = ""; ORS = "\n\n" } $0 !~ /# file: \/srv\/app\/gone\.txt/' /tmp/before.acls > /tmp/expected.acls
getfacl -R -p /srv > /tmp/after.acls
check "access control lists match the machine before the install, less the deleted file" diff -q /tmp/expected.acls /tmp/after.acls

finish
