#!/usr/bin/env bash
# SIR-70 round 2, must fix 5. the snapshot is deleted after install. undo must not call that done: it
# removes what the grant added anyway, says loudly that earlier lists could not be restored, and the
# machine ends as it was. at 66e31fe the restore step was judged already done and the folder kept its
# default list, mask, and the folder owner's entry.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work/sub && echo f > /srv/work/sub/f && echo g > /srv/work/g && chown -R owner:owner /srv/work
world_aclraw_attributes /srv > /tmp/before.raw

check_exit "install builder on /srv/work applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
rm -rf /var/lib/sirven/access-lists
check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
check "the output says the earlier lists could not be restored" grep -qi 'could not restore' <<< "$LAST_OUTPUT"
check "the audit log has a warning about the missing snapshot" \
  bash -c 'grep "\"event\": \"warning\"" /var/log/sirven/audit.jsonl | grep -qi "snapshot"'
check "the restore step was not reported as already done" bash -c '! grep -B1 -A3 "put back\|as they were before the grant" <<< "$0" | grep -q "already done"' "$LAST_OUTPUT"
world_unchanged "the grant's entries are all gone and the machine is as it was" aclraw_attributes /tmp/before.raw /srv

finish
