#!/usr/bin/env bash
# the confirmation gate on a real Linux host (container markers removed, see lib/real_host.sh), with the
# terminal handling the way curl | sudo bash really has it: standard input is a pipe, and the question can
# only be asked on a terminal. covers: no terminal at all (exit 3, nothing changed); the plan-only steps
# refused before any question; a typed no; a typed yes on a pseudo-terminal; and the same gate on
# uninstall.sh and on sirven grant rollback.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
. "$(dirname "$0")/../../lib/real_host.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt
world_files > /tmp/before.files
world_accounts > /tmp/before.accounts
world_etc_content > /tmp/before.etc
INSTALL="--level observer --transport none --path /srv/app"
ON_TERMINAL() { python3 -I "$SRC/tests/harness/lib/pty_run.py" "$@"; }

# no terminal at all: a new session with no controlling terminal, standard input a pipe, output captured.
# it is what curl | sudo bash looks like when it runs from a job with nobody there.
check_exit "no terminal and no --yes is refused" 3 bash -c "printf '' | setsid -w bash install.sh $INSTALL"
check "the refusal says there is no terminal" grep -q 'no terminal to confirm' <<< "$LAST_OUTPUT"
check "the refusal says to run again with --yes" grep -q 'with --yes' <<< "$LAST_OUTPUT"
check "no question was printed" bash -c '! grep -q "type yes" <<< "$0"' "$LAST_OUTPUT"
world_unchanged "files are unchanged by the refusal" files /tmp/before.files
world_unchanged "accounts are unchanged by the refusal" accounts /tmp/before.accounts
world_unchanged "the content of /etc is unchanged by the refusal" etc_content /tmp/before.etc

# container markers are not consent: with /.dockerenv present, and again with container= set, no terminal and no --yes
# still refuses, exit 3, and changes nothing.
touch /.dockerenv
check_exit "with /.dockerenv present, no terminal and no --yes is refused" 3 bash -c "printf '' | setsid -w bash install.sh $INSTALL"
check "it asks for --yes and created nothing" bash -c 'grep -q "with --yes" <<< "$0" && ! getent passwd agent' "$LAST_OUTPUT"
rm -f /.dockerenv
check_exit "with container=lxc set, no terminal and no --yes is refused" 3 bash -c "printf '' | container=lxc setsid -w bash install.sh $INSTALL"
check "it asks for --yes and created nothing" bash -c 'grep -q "with --yes" <<< "$0" && ! getent passwd agent' "$LAST_OUTPUT"
world_unchanged "files are unchanged by the marker refusals" files /tmp/before.files
world_unchanged "accounts are unchanged by the marker refusals" accounts /tmp/before.accounts
world_unchanged "the content of /etc is unchanged by the marker refusals" etc_content /tmp/before.etc

# plan-only steps are refused before anyone is asked to type yes, even on a terminal.
check_exit "a plan with plan-only steps is refused" 3 ON_TERMINAL "type yes" yes bash -c "printf '' | bash install.sh --with-bb $INSTALL"
check "it says not yet" grep -q 'not yet' <<< "$LAST_OUTPUT"
check "it never asked to type yes" bash -c '! grep -q "type yes" <<< "$0"' "$LAST_OUTPUT"
check "the agent account was not created" bash -c '! getent passwd agent'

# a terminal with a person at it, while standard input is a pipe (the curl | sudo bash shape).
check_exit "typing no on the terminal refuses" 3 ON_TERMINAL "type yes" no bash -c "printf '' | bash install.sh $INSTALL"
check "it says the plan was not confirmed" grep -q 'not confirmed' <<< "$LAST_OUTPUT"
check "the agent account was not created by a no" bash -c '! getent passwd agent'
world_unchanged "files are unchanged by a typed no" files /tmp/before.files
check_exit "typing yes on the terminal applies the plan" 0 ON_TERMINAL "type yes" yes bash -c "printf '' | bash install.sh $INSTALL"
check "the agent account exists" id -u agent
cp /var/lib/sirven/install-record.tsv /tmp/record.installed
cp /etc/sirven/grants/agent.json /tmp/grant.installed
world_files > /tmp/installed.files

# the same gate on the commands that also change a real machine.
check_exit "uninstall with no terminal and no --yes is refused" 3 bash -c "printf '' | setsid -w bash /var/lib/sirven/package/uninstall.sh"
check "uninstall says to run again with --yes" grep -q 'with --yes' <<< "$LAST_OUTPUT"
check "the agent account is still there" id -u agent
world_unchanged "files are unchanged by the refused uninstall" files /tmp/installed.files
check_exit "typing no to uninstall refuses" 3 ON_TERMINAL "type yes" no bash -c "printf '' | bash /var/lib/sirven/package/uninstall.sh"
check "the agent account is still there after a no" id -u agent
check_exit "grant rollback with no terminal and no --yes is refused" 3 bash -c "printf '' | setsid -w bash bin/sirven grant rollback"
check "rollback says to run again with --yes" grep -q 'with --yes' <<< "$LAST_OUTPUT"
check "the grant record is unchanged" cmp /tmp/grant.installed /etc/sirven/grants/agent.json
check "the install record is unchanged" cmp /tmp/record.installed /var/lib/sirven/install-record.tsv

check_exit "grant repair with no terminal and no --yes is refused" 3 bash -c "printf '' | setsid -w bash bin/sirven grant repair"
check "repair says to run again with --yes" grep -q 'with --yes' <<< "$LAST_OUTPUT"
check "the grant record is unchanged by the refused repair" cmp /tmp/grant.installed /etc/sirven/grants/agent.json
check_exit "typing no to grant repair refuses" 3 ON_TERMINAL "type yes" no bash -c "printf '' | bash bin/sirven grant repair"
check_exit "grant repair with --yes applies" 0 bash bin/sirven grant repair --yes

check_exit "typing yes to uninstall removes everything" 0 ON_TERMINAL "type yes" yes bash -c "printf '' | bash /var/lib/sirven/package/uninstall.sh"
check "the agent account is gone" bash -c '! getent passwd agent'
world_unchanged "the content of /etc matches the machine before the install" etc_content /tmp/before.etc

finish
