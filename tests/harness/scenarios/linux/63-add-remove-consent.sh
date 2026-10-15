#!/usr/bin/env bash
# the confirmation gate on sirven add and sirven remove, on a real Linux host (container markers removed, see
# lib/real_host.sh). the only shipped component, crm, needs Docker, which the harness image lacks, so this scenario
# writes a test-only component, probe, into the disposable copy of the repository the container runs from (SRC, a
# throwaway copy made by run-linux.sh). the file exists only in that copy: it is never in the
# repository's components folder, so neither make package nor the package.json files list can ship it.
# covers: no terminal and no --yes refused with exit 3 and nothing changed; a typed no refused; a typed yes applies;
# --yes applies; the same for remove, including after each refusal.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
. "$(dirname "$0")/../../lib/real_host.sh"
cd "$SRC" || exit 2
ON_TERMINAL() { python3 -I "$SRC/tests/harness/lib/pty_run.py" "$@"; }

cat > "$SRC/components/probe.sh" <<'P'
# shellcheck shell=bash
# probe: a test-only component that needs no Docker. one folder with one file.
component_probe_summary() { printf 'a test-only component'; }
component_probe_preflight() { :; }
component_probe_plan_add() {
  local dir
  dir="$(rooted "$COMPONENT_DIR")"
  plan_step run "create the folder $COMPONENT_DIR" "[ -d $dir ]" "mkdir -p $dir"
  plan_step run "write the probe file" "[ -e $dir/probe.txt ]" "echo probe > $dir/probe.txt"
}
component_probe_plan_remove() {
  local dir
  dir="$(rooted "$COMPONENT_DIR")"
  plan_step run "remove the probe file" "[ ! -e $dir/probe.txt ]" "rm -f $dir/probe.txt"
  plan_step run "remove the folder" "[ ! -d $dir ]" "rmdir $dir"
}
P

mkdir -p /srv/app && echo hello > /srv/app/file.txt
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
check "precondition: the install made the audit log" test -s /var/log/sirven/audit.jsonl
DIR=/root/probe-folder
world_files > /tmp/installed.files
world_etc_content > /tmp/installed.etc
audit_count() { wc -l < /var/log/sirven/audit.jsonl; }
AUDIT_BEFORE="$(audit_count)"

# add: every refusal leaves the machine as it was.
check_exit "add with no terminal and no --yes is refused" 3 bash -c "printf '' | setsid -w bash bin/sirven add probe --dir $DIR"
check "add says there is no terminal and to run again with --yes" bash -c 'grep -q "no terminal to confirm" <<< "$0" && grep -q "with --yes" <<< "$0"' "$LAST_OUTPUT"
check "no question was printed" bash -c '! grep -q "type yes" <<< "$0"' "$LAST_OUTPUT"
check "the folder was not created" test ! -e "$DIR"
check_exit "typing no to add refuses" 3 ON_TERMINAL "type yes" no bash -c "printf '' | bash bin/sirven add probe --dir $DIR"
check "it says the plan was not confirmed" grep -q 'not confirmed' <<< "$LAST_OUTPUT"
check "the folder was not created by a no" test ! -e "$DIR"
world_unchanged "files are unchanged by the refused adds" files /tmp/installed.files
world_unchanged "the content of /etc is unchanged by the refused adds" etc_content /tmp/installed.etc
check "nothing was written to the audit log by the refused adds" test "$(audit_count)" = "$AUDIT_BEFORE"

# add: consent applies it.
check_exit "typing yes to add applies the plan" 0 ON_TERMINAL "type yes" yes bash -c "printf '' | bash bin/sirven add probe --dir $DIR"
check "the probe file exists" test -f "$DIR/probe.txt"
bash bin/sirven remove probe --dir "$DIR" --yes >/dev/null 2>&1
check "cleanup: remove with --yes took the folder away" test ! -e "$DIR"
check_exit "add with --yes applies the plan" 0 bash bin/sirven add probe --dir "$DIR" --yes
check "the probe file exists after add --yes" test -f "$DIR/probe.txt"
world_files > /tmp/added.files

# remove: every refusal leaves the added component in place.
check_exit "remove with no terminal and no --yes is refused" 3 bash -c "printf '' | setsid -w bash bin/sirven remove probe --dir $DIR"
check "remove says to run again with --yes" grep -q 'with --yes' <<< "$LAST_OUTPUT"
check "the probe file is still there" test -f "$DIR/probe.txt"
check_exit "typing no to remove refuses" 3 ON_TERMINAL "type yes" no bash -c "printf '' | bash bin/sirven remove probe --dir $DIR"
check "the probe file is still there after a no" test -f "$DIR/probe.txt"
world_unchanged "files are unchanged by the refused removes" files /tmp/added.files

# remove: consent applies it.
check_exit "typing yes to remove applies the plan" 0 ON_TERMINAL "type yes" yes bash -c "printf '' | bash bin/sirven remove probe --dir $DIR"
check "the folder is gone" test ! -e "$DIR"
world_unchanged "files match the machine right after the install" files /tmp/installed.files

finish
