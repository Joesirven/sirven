#!/usr/bin/env bash
# regression guard for the grant history: a second install that adds a nested path, an install at another
# level, and a re-install must all apply (the agent's own entries are not "existing lists for other
# accounts"), and uninstall leaves the lists as they were before the first install.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work/sub && echo f > /srv/work/sub/f && echo g > /srv/work/g && chown -R owner:owner /srv/work
world_aclraw_attributes /srv > /tmp/before.raw

check_exit "install observer on /srv/work applies" 0 bash install.sh --yes --level observer --transport none --path /srv/work
check_exit "install builder on /srv/work (another level) applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check_exit "install builder on the nested /srv/work/sub applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work --path /srv/work/sub
check_exit "a plain re-install applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work --path /srv/work/sub
check "the agent can write in the nested folder" runuser -u agent -- sh -c 'echo x > /srv/work/sub/by-agent'

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
rm -f /srv/work/sub/by-agent
world_unchanged "every list, owner, and mode is back exactly" aclraw_attributes /tmp/before.raw /srv

finish
