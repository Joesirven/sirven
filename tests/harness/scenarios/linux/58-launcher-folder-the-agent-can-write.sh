#!/usr/bin/env bash
# SIR-32 final round (review S-R3-2, f5b). if /usr/local/sbin (or a folder above it) can be written by the agent, a launcher put there
# can be replaced by the agent's own script, and the documented command then runs it as root. install used to write the launcher there
# without a word. now it vets the folder first (the gate's own checker, owner root): when it is not safe it writes nothing, says so, and
# gives the owner the kept-copy command instead; it advertises no path it did not secure. the owner runs what install printed, and the
# agent's script never runs. with the folder fixed, the next install lays the launcher down and advertises it.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m agent
mkdir -p /usr/local/sbin /srv/app && echo f > /srv/app/f
chown agent /usr/local/sbin
check "precondition: the agent can write /usr/local/sbin" runuser -u agent -- test -w /usr/local/sbin

check_exit "install applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
out="$LAST_OUTPUT"
check "no launcher was written into the folder the agent can write" bash -c '[ ! -e /usr/local/sbin/sirven ]'
check "the plan says the launcher is not installed, and why" bash -c 'grep -q "the launcher /usr/local/sbin/sirven is NOT installed" <<< "$0" && grep -q "can be changed by an account other than root" <<< "$0"' "$out"
check "it gives the kept-copy commands instead" bash -c 'grep -q "sudo bash /var/lib/sirven/package/install.sh revoke --all" <<< "$0" && grep -q "sudo bash /var/lib/sirven/package/uninstall.sh" <<< "$0"' "$out"
check "it says anything found at that path is not ours" grep -q 'anything found at that path is not ours: do not run it' <<< "$out"
check "--help of the installer and the uninstaller point at the kept copy, not at the launcher path" bash -c '
  for helper in install.sh uninstall.sh; do
    text="$(bash /var/lib/sirven/package/$helper --help 2>&1)"
    grep -q "sudo bash /var/lib/sirven/package/install.sh revoke --all" <<< "$text" || exit 1
    ! grep -q "sudo /usr/local/sbin/sirven" <<< "$text" || exit 1
  done'
check "it does not tell the owner to run the launcher" bash -c '! grep -q "sudo /usr/local/sbin/sirven" <<< "$0"' "$out"

# the agent plants its own launcher, then the owner runs the command install advertised
# (it owns the folder, so it can remove a root-owned file there and put its own in its place)
runuser -u agent -- bash -c 'rm -f /usr/local/sbin/sirven; printf "#!/bin/sh\ntouch /tmp/ROOT-RAN-LAUNCHER\n" > /usr/local/sbin/sirven; chmod +x /usr/local/sbin/sirven'
advertised="$(grep -o 'sudo [^(]*revoke --all' <<< "$out" | head -1)"
echo "advertised: $advertised"
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check_exit "the advertised command applies" 0 bash -c "cd /tmp && ${advertised#sudo } --yes --transport none"
check "the agent's launcher never ran as root, and the agent is cut off" bash -c '[ ! -e /tmp/ROOT-RAN-LAUNCHER ] && ! pgrep -u agent && passwd --status agent | grep -q "^agent L"'

# a folder above it that the agent can write, with /usr/local/sbin not there yet
bash /var/lib/sirven/package/uninstall.sh >/dev/null 2>&1
rm -rf /usr/local/sbin /home/agent /etc/sirven /var/lib/sirven /var/log/sirven; userdel agent >/dev/null 2>&1; groupdel agent >/dev/null 2>&1
useradd -m agent; chown agent /usr/local
check_exit "install with /usr/local owned by the agent and no /usr/local/sbin applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check "no launcher, no folder made for it, and the plan says so" bash -c '[ ! -e /usr/local/sbin/sirven ] && grep -q "is NOT installed" <<< "$0"' "$LAST_OUTPUT"

# the folder made safe: the next install lays the launcher down and advertises it
chown root /usr/local; mkdir -p /usr/local/sbin; chown root /usr/local/sbin; chmod 755 /usr/local/sbin
check_exit "install again, with the folders root's" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check "the launcher is there, root-owned, mode 755, and advertised" bash -c '[ "$(stat -c "%a %u" /usr/local/sbin/sirven)" = "755 0" ] && grep -q "sudo /usr/local/sbin/sirven revoke --all" <<< "$0"' "$LAST_OUTPUT"
check "with the folders root's, --help names the launcher" bash -c 'bash /var/lib/sirven/package/install.sh --help | grep -q "sudo /usr/local/sbin/sirven revoke --all" && bash /var/lib/sirven/package/uninstall.sh --help | grep -q "sudo /usr/local/sbin/sirven revoke --all"'
# and it is checked again when it is written
chown agent /usr/local/sbin; rm -f /usr/local/sbin/sirven
check "the step itself refuses to write into a folder that stopped being safe" bash -c '
  cd /var/lib/sirven/package && . lib/common.sh && . lib/layout.sh && PREFIX="" OPERATING_SYSTEM=linux
  # the gate block of the entry script defines sirven_vet
  eval "$(sed -n "/^sirven_vet()/,/^}/p" /var/lib/sirven/package/install.sh)"
  ! layout_install_launcher /usr/local/sbin/sirven 2>/dev/null && [ ! -e /usr/local/sbin/sirven ]'
finish
