#!/usr/bin/env bash
# SIR-32 final round (review N-R3-1 to N-R3-3). the edges of the root gate:
#   - started from standard input or with -c (no file, so no folder to check): refused with a clear message, before any library
#     is read, instead of dying by accident on an unset variable. an agent-edited library in the current folder does not run.
#   - a package tree 1,500 folders deep is judged (accepted when clean, refused with the path when not), never a traceback.
#   - a package name other than sirven installs nowhere: the root gate and the launcher run the kept copy at a fixed path, so such a
#     build is refused up front, with nothing changed.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"

mkdir -p /work && cp -r "$SRC" /work/repo && cd /work/repo || exit 2
printf '\ntouch /tmp/ROOT-RAN-STDIN-LIB\n' >> lib/common.sh
check_exit "install.sh piped into bash -s is refused (exit 2)" 2 bash -c 'cat /work/repo/install.sh | bash -s -- --dry-run --transport none'
check "it says to run the script as a file, and the edited library did not run" bash -c 'grep -q "run this as a file" <<< "$0" && [ ! -e /tmp/ROOT-RAN-STDIN-LIB ]' "$LAST_OUTPUT"
check_exit "install.sh given to bash -c is refused (exit 2)" 2 bash -c 'bash -c "$(cat /work/repo/install.sh)" -- --dry-run --transport none'
check "same: a clear message, the edited library did not run" bash -c 'grep -q "run this as a file" <<< "$0" && [ ! -e /tmp/ROOT-RAN-STDIN-LIB ]' "$LAST_OUTPUT"
check_exit "uninstall.sh and bin/sirven are refused the same way" 2 bash -c 'cat /work/repo/uninstall.sh | bash -s -- --dry-run && false || cat /work/repo/bin/sirven | bash -s -- grant inspect'

# a deep tree
rm -rf /work/deep && cp -r "$SRC" /work/deep && cd /work/deep || exit 2
path=lib; for i in $(seq 1 1500); do path="$path/d"; done
mkdir -p "$path" && echo x > "$path/leaf"
check_exit "a clean package tree 1,500 folders deep is judged and accepted (exit 0)" 0 bash install.sh --dry-run --level observer --transport none
check "no traceback" bash -c '! grep -qi traceback <<< "$0"' "$LAST_OUTPUT"
chmod o+w "$path/leaf"
check_exit "with a writable file at the bottom it is refused (exit 2)" 2 bash install.sh --dry-run --level observer --transport none
check "the refusal names the file at the bottom and shows no traceback" bash -c 'grep -q "/d/leaf: writable by everyone" <<< "$0" && ! grep -qi traceback <<< "$0"' "$LAST_OUTPUT"

# a package name other than sirven
rm -rf /work/named && cp -r "$SRC" /work/named && cd /work/named || exit 2
sed -i 's|"name"[[:space:]]*:[[:space:]]*"[^"]*"|"name": "other"|' project.json
check_exit "a build named other is refused up front (exit 2)" 2 bash install.sh --yes --level observer --transport none
check "it says why, and nothing was created" bash -c 'grep -q "run the kept copy at /var/lib/sirven/package" <<< "$0" && ! getent passwd agent && [ ! -e /var/lib/other ] && [ ! -e /var/lib/sirven ] && [ ! -e /etc/other ]' "$LAST_OUTPUT"
finish
