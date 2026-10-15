#!/usr/bin/env bash
# attack 9: a key file that looks right to ls (owned by root, mode 0600, nothing for the group or others) but carries an access entry
# for another account. on Linux the group bits of such a file show the access control list's mask, so a mask of --- hides the
# entry completely; a check that reads the mode bits alone lets the file through, and the other account can read the key.
set -uo pipefail
. /src/docs/research/qa/sir-1-33-review-attacks/common.sh
mkdir -p /etc/sirven; chmod 755 /etc/sirven
printf '%s\n' "$KEY" > /etc/sirven/tailscale-auth-key
chown root:root /etc/sirven/tailscale-auth-key; chmod 0600 /etc/sirven/tailscale-auth-key
setfacl -m u:nobody:r /etc/sirven/tailscale-auth-key
for mask in 'r--' 'rw-' '---'; do
  setfacl -m "m::$mask" /etc/sirven/tailscale-auth-key
  echo "mask $mask: $(ls -ld /etc/sirven/tailscale-auth-key | cut -c1-11)"
  install_ts > /tmp/t9.out 2>&1; echo "install exit $? (0 means the file with an entry for nobody was used)"
  check "mask $mask: the file is refused, naming the access control list" bash -c 'grep -q "extended access control list" /tmp/t9.out'
  check "mask $mask: the machine did not join" bash -c '[ "$(cat /tmp/fake-ts/state 2>/dev/null)" != Running ]'
  check "mask $mask: the key is not in the refusal" bash -c '! grep -qF -- "$KEY" /tmp/t9.out'
done
# a named group entry is refused the same way, and the same file with the list taken off is used again
setfacl -b /etc/sirven/tailscale-auth-key; setfacl -m g:nogroup:r /etc/sirven/tailscale-auth-key; setfacl -m m::--- /etc/sirven/tailscale-auth-key
install_ts > /tmp/t9.out 2>&1; echo "install exit $?"
check "an entry for a group is refused too" bash -c 'grep -q "extended access control list" /tmp/t9.out && [ "$(cat /tmp/fake-ts/state 2>/dev/null)" != Running ]'
setfacl -b /etc/sirven/tailscale-auth-key; chmod 0600 /etc/sirven/tailscale-auth-key
install_ts > /tmp/t9.out 2>&1; echo "install exit $?"
check "with the list taken off, the same file is used and the machine joins" bash -c '[ "$(cat /tmp/fake-ts/state 2>/dev/null)" = Running ]'
finish
