#!/usr/bin/env bash
# SIR-70 round 2, must fix 4. folders whose names hold a newline or a backslash keep their own default
# lists through install and uninstall, and the grant reaches them. at 66e31fe getfacl wrote those names
# escaped, so their blocks were dropped and the lists were lost without a word.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
newline=$'new\nline'
back='back\slash'
mkdir -p /srv/odd
for name in "$newline" "$back" 'plain name' $'tab\there'; do
  mkdir "/srv/odd/$name" && echo data > "/srv/odd/$name/file" && echo data > "/srv/odd/$name file"
  setfacl -d -m u::rwx,g::r-x,o::r-x "/srv/odd/$name"
done
mkdir -p "/srv/odd/$newline/in\\side" && echo deep > "/srv/odd/$newline/in\\side/leaf"
chown -R owner:owner /srv/odd
world_aclraw_attributes /srv > /tmp/before.raw

check_exit "install builder on /srv/odd applies" 0 bash install.sh --yes --level builder --transport none --path /srv/odd
check "the agent can read a file in the folder with a newline in its name" runuser -u agent -- cat "/srv/odd/$newline/file"
check "the agent can write in the folder with a backslash in its name" runuser -u agent -- sh -c "echo more >> '/srv/odd/$back/file'"
check "the agent can read a file two levels down under odd names" runuser -u agent -- cat "/srv/odd/$newline/in\\side/leaf"

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
world_unchanged "every list, owner, and mode is back exactly, odd names included" aclraw_attributes /tmp/before.raw /srv
check "the oddly named folders kept their own default lists" \
  bash -c '[ "$(getfacl -p --omit-header "/srv/odd/$0" | grep -c "^default:")" = 3 ]' "$newline"

finish
