#!/usr/bin/env bash
# SIR-70 round 3, should fix 6. an install made by an older version (simulated: a copy of the package with a different
# policy file, and an install record whose undo lines have the older form) is not simply refused: the refusal names the
# way forward, `sirven grant repair`, then the old uninstall, then install, and that way works.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/app && echo hello > /srv/app/f && chown -R owner:owner /srv/app
world_aclraw_attributes /srv > /tmp/before.raw
cp -R "$SRC" /tmp/older && sed -i 's/"summary": "/"summary": "older version: /' /tmp/older/levels/observer.json
check_exit "the older version installs" 0 bash /tmp/older/install.sh --yes --level observer --transport none --path /srv/app
sed -i 's/ --audit [^[:space:]]*//g' /var/lib/sirven/install-record.tsv

check_exit "this version is refused over it" 2 bash install.sh --yes --level observer --transport none --path /srv/app
check "the refusal names sirven grant repair" grep -q 'sirven grant repair' <<< "$LAST_OUTPUT"
check "the refusal says nothing was changed" grep -q 'nothing was changed' <<< "$LAST_OUTPUT"
check_exit "repair dry run lists the folders" 0 bash bin/sirven grant repair --dry-run
check_exit "repair applies" 0 bash bin/sirven grant repair
check_exit "the older version's uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
world_unchanged "the machine is as it was before the older install" aclraw_attributes /tmp/before.raw /srv
check_exit "this version installs" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check_exit "and uninstalls" 0 bash /var/lib/sirven/package/uninstall.sh

finish
