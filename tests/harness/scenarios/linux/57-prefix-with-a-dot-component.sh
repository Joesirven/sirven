#!/usr/bin/env bash
# SIR-32 final round (review S-R3-3, f6b). a --prefix such as /nonexist/.. names the real root without being resolvable (the folder does
# not exist), so it was accepted as a fake root, and a real run created /etc/sirven, /var/lib/sirven and /nonexist on the machine. a
# prefix with a "." or ".." component is refused, existing or not, and no folder is created from it. real folders are still accepted.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

nothing_created() { [ ! -e /nonexist ] && [ ! -e /etc/sirven ] && [ ! -e /var/lib/sirven ] && [ ! -e /var/log/sirven ] && [ ! -e /tmp/nonexist ]; }
check "precondition: none of the folders a traversal prefix would reach exists" nothing_created
for prefix in /nonexist/.. /tmp/nonexist/../.. /nonexist/../ //nonexist//.. /tmp/./x /tmp/real/../..; do
  check_exit "install --prefix $prefix is refused (exit 64)" 64 bash install.sh --yes --level observer --transport none --prefix "$prefix"
  check "install --prefix $prefix: the reason is the dot component, and nothing was created" bash -c "$(declare -f nothing_created); grep -q 'may not contain a . or .. component' <<< \"\$0\" && nothing_created" "$LAST_OUTPUT"
done
check_exit "revoke --prefix /nonexist/.. is refused (exit 64)" 64 bash install.sh revoke --all --yes --transport none --prefix /nonexist/..
check_exit "uninstall --prefix /nonexist/.. is refused (exit 64)" 64 bash uninstall.sh --prefix /nonexist/..
check_exit "sirven grant rollback --prefix /nonexist/.. is refused (exit 64)" 64 bash bin/sirven grant rollback --prefix /nonexist/..
check "nothing was created by any of them" nothing_created
# a real folder is still a fake root
mkdir -p /tmp/fake-root
check_exit "a plain folder is accepted as a fake root" 0 bash install.sh --yes --level observer --transport none --prefix /tmp/fake-root
check "it worked inside the fake root and nowhere else" bash -c '[ -d /tmp/fake-root/etc/sirven ] && [ ! -e /etc/sirven ] && [ ! -e /var/lib/sirven ]'
finish
