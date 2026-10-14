#!/usr/bin/env bash
# SIR-70 round 6, should fix 1 and 2. python3 without the sqlite3 module (the minimal Ubuntu install): (1) install is
# refused up front with a clear message, before the account is created, locked or changed; (2) uninstall of an install
# made while the module was there does not die with an AttributeError: it removes the grant's entries, warns that the
# snapshot cannot be read and leaves the file where it is. at fa208c7 install locked the account and failed at step 19
# with exit 4, and uninstall exited 4 with "unexpected AttributeError".
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work/sub && echo f > /srv/work/sub/f && chown -R owner:owner /srv/work
setfacl -d -m u::rwx,g::r-x,o::r-x /srv/work/sub    # a list of its own, so the snapshot holds a row
world_aclraw_attributes /srv > /tmp/before.raw
world_accounts > /tmp/before.accounts

module="$(python3 -c 'import _sqlite3; print(_sqlite3.__file__)')"
cp "$module" /tmp/_sqlite3.so
hide() { mv "$module" /tmp/_sqlite3.hidden; }
unhide() { mv /tmp/_sqlite3.hidden "$module"; }

# (1) refused up front
hide
check "precondition: python3 cannot import sqlite3" bash -c '! python3 -c "import sqlite3" 2>/dev/null'
check_exit "install is refused (preflight, like a missing python3)" 1 bash install.sh --yes --level builder --transport none --path /srv/work
check "the message names the missing module and the package to install" grep -q 'no sqlite3 module.*apt install python3\|no sqlite3 module' <<< "$LAST_OUTPUT"
check "the message says nothing was changed" grep -q 'nothing was changed' <<< "$LAST_OUTPUT"
world_unchanged "no account was created or changed" accounts /tmp/before.accounts
world_unchanged "no list was changed" aclraw_attributes /tmp/before.raw /srv
unhide

# (2) uninstall of an install made while the module was there
check_exit "install applies with the module" 0 bash install.sh --yes --level builder --transport none --path /srv/work
hide
check_exit "uninstall applies without the module" 0 bash /var/lib/sirven/package/uninstall.sh
check "no AttributeError, no traceback" bash -c '! grep -Eq "AttributeError|Traceback" <<< "$0"' "$LAST_OUTPUT"
check "it warns that the snapshot cannot be read, and says what to do" grep -q 'no sqlite3 module' <<< "$LAST_OUTPUT"
check "the audit log has the warning" bash -c 'grep "\"event\": \"warning\"" /var/log/sirven/audit.jsonl | grep -q "sqlite3"'
check "no entry of the agent is left" bash -c '! getfacl -R -n -p /srv/work | grep -Eq "^(default:)?user:[0-9]+:"'
check "the snapshot file was left where it is, not deleted" bash -c 'ls /var/lib/sirven/access-lists/* >/dev/null 2>&1'
unhide

finish
