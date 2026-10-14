# shellcheck shell=bash
# helpers for scenarios that run INSIDE the disposable machine, as root. sourced by every
# scenario. nothing here is ever run on the owner's own machine: run-linux.sh starts a fresh
# container per scenario, mounts the repository read only at /src, and throws it away after.
#
# the output format matches tests/run.sh: "ok      name" or "not ok  name". a scenario exits
# non-zero when any assertion failed.
#
# a "known defect" is an assertion the product fails today and a task will fix. it reports as
# "known  name", does not fail the run, and FAILS the run once the product passes, so the marker
# cannot be forgotten: that is the ratchet.

HARNESS_FAILED=0
HARNESS_PASSED=0
HARNESS_KNOWN=0
SRC="${SRC:-/src}"

pass() { HARNESS_PASSED=$((HARNESS_PASSED + 1)); printf 'ok      %s\n' "$1"; }
fail() {
  HARNESS_FAILED=$((HARNESS_FAILED + 1)); printf 'not ok  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/        /'; fi
}

# check NAME COMMAND...: pass when the command exits 0.
check() {
  local name="$1" out
  shift
  if out="$("$@" 2>&1)"; then pass "$name"; else fail "$name" "$out"; fi
}

# check_exit NAME WANTED COMMAND...: pass when the command exits with WANTED. output kept in LAST_OUTPUT.
check_exit() {
  local name="$1" wanted="$2" status=0
  shift 2
  LAST_OUTPUT="$("$@" 2>&1)" || status=$?
  if [ "$status" -eq "$wanted" ]; then pass "$name (exit $status)"; else fail "$name: wanted exit $wanted, got $status" "$(printf '%s\n' "$LAST_OUTPUT" | tail -15)"; fi
}

# known_defect NAME TASK COMMAND...: the assertion the product should meet once TASK lands.
known_defect() {
  local name="$1" task="$2" out
  shift 2
  if out="$("$@" 2>&1)"; then
    fail "$name: now passes, so remove the known_defect marker for $task"
  else
    HARNESS_KNOWN=$((HARNESS_KNOWN + 1)); printf 'known   %s (%s)\n' "$name" "$task"
  fi
}

finish() {
  printf '%s passed, %s failed, %s known defects\n' "$HARNESS_PASSED" "$HARNESS_FAILED" "$HARNESS_KNOWN"
  [ "$HARNESS_FAILED" -eq 0 ]
}

# the files, accounts, and permission lists of the whole machine, as sorted text, so two moments
# can be compared with diff. volatile places are left out. ALLOWED leftovers are left out too and
# are named here on purpose: the audit log and the service user's home are kept by design
# (uninstall.sh says so), and the system's own backup copies of the account files change by
# themselves.
world_files() {
  find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /tmp -o -path /run -o -path /src \
      -o -path /var/cache -o -path /var/lib/apt -o -path /var/lib/dpkg -o -path /var/log/apt \
      -o -path /home -o -path /var/log/sirven \) -prune -o -printf '%p %y %U:%G %m\n' 2>/dev/null \
    | grep -v -e '^/etc/[a-z]*- ' -e '^/etc/subuid' -e '^/etc/subgid' -e '^/var/log/\(lastlog\|faillog\|wtmp\)' \
    | sort
}
world_accounts() {
  { cut -d: -f1,3,4,6,7 /etc/passwd; cut -d: -f1,3 /etc/group; cut -d: -f1,2 /etc/shadow | sed 's/:[^*!].*$/:HASH/'; } | sort
}
# permission lists (base entries included, so a leftover mask or default entry shows) for the folders given.
world_acls() {
  local path
  for path in "$@"; do getfacl -R -p "$path" 2>/dev/null; done | sort
}

# world_unchanged NAME KIND BEFOREFILE: compare now against a saved snapshot.
world_unchanged() {
  local name="$1" kind="$2" before="$3" shift_out
  shift 3
  "world_$kind" "$@" > "$before.now"
  if shift_out="$(diff "$before" "$before.now")"; then pass "$name"; else fail "$name" "$(printf '%s\n' "$shift_out" | head -20)"; fi
}
