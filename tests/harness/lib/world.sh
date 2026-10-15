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
HARNESS_SKIPPED=0
SRC="${SRC:-/src}"
# the container is a real machine to the installer, so every apply asks for the owner's consent (README): the scenarios give it
# through SIRVEN_YES, the same as running with --yes. the real host scenarios (lib/real_host.sh) take it away to test the question.
export SIRVEN_YES=1

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

# world_account_gets_spool: exit 0 when this image's account tool gives a new account a mail spool (Fedora does, Debian and
# Ubuntu do not). it makes and removes a throwaway account, so call it before any snapshot is taken.
world_account_gets_spool() {
  local status=1
  useradd -m harness-spool-probe && [ -e /var/spool/mail/harness-spool-probe ] && status=0
  userdel -r harness-spool-probe >/dev/null 2>&1
  return "$status"
}

# world_mail_spool_gone NAME: exit 0 when no mail spool or link named NAME is left in either spool folder (/var/mail is
# usually a link to /var/spool/mail on Fedora, so both are looked at).
world_mail_spool_gone() {
  local path
  for path in "/var/spool/mail/$1" "/var/mail/$1"; do
    if [ -e "$path" ] || [ -L "$path" ]; then return 1; fi
  done
}

# skip NAME REASON: an assertion that cannot run here (a missing credential, say). it reports as "skipped", does not
# fail the run, and is counted, so a run that skipped what mattered says so on its last line.
skip() {
  HARNESS_SKIPPED=$((HARNESS_SKIPPED + 1)); printf 'skipped %s: %s\n' "$1" "$2"
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
  printf '%s passed, %s failed, %s known defects, %s skipped\n' "$HARNESS_PASSED" "$HARNESS_FAILED" "$HARNESS_KNOWN" "$HARNESS_SKIPPED"
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
# a content hash of every regular file under /etc, so a file that kept its type, owner, and mode but not its
# bytes shows too. the account files are left out here because world_accounts compares them without the
# password hashes' salts moving, and the system's own backup copies and subordinate id files change by themselves.
world_etc_content() {
  find /etc -xdev -type f ! -name 'passwd' ! -name 'shadow' ! -name 'group' ! -name 'gshadow' \
      ! -name '*-' ! -name 'subuid' ! -name 'subgid' ! -name 'ld.so.cache' -print0 2>/dev/null \
    | sort -z | xargs -0 sha256sum 2>/dev/null
}
world_accounts() {
  { cut -d: -f1,3,4,6,7 /etc/passwd; cut -d: -f1,3 /etc/group; cut -d: -f1,2 /etc/shadow | sed 's/:[^*!].*$/:HASH/'; sed 's/^/subuid /' /etc/subuid; sed 's/^/subgid /' /etc/subgid; } | sort
}
# permission lists (base entries included, so a leftover mask or default entry shows) for the folders given.
world_acls() {
  local path
  for path in "$@"; do getfacl -R -p "$path" 2>/dev/null; done | sort
}

# the raw permission-list attributes of the folders given, with names kept lossless (see aclraw.py), so a
# newline or a backslash in a file name cannot hide a difference. world_aclraw_attributes adds owner, group,
# and the full mode, special bits included.
world_aclraw() { python3 -I "$SRC/tests/harness/lib/aclraw.py" "$@"; }
world_aclraw_attributes() { python3 -I "$SRC/tests/harness/lib/aclraw.py" --attributes "$@"; }

# world_unchanged NAME KIND BEFOREFILE: compare now against a saved snapshot.
world_unchanged() {
  local name="$1" kind="$2" before="$3" shift_out
  shift 3
  "world_$kind" "$@" > "$before.now"
  if shift_out="$(diff "$before" "$before.now")"; then pass "$name"; else fail "$name" "$(printf '%s\n' "$shift_out" | head -20)"; fi
}

# world_unchanged_if CONDITION NAME KIND BEFOREFILE [ARG...]: like world_unchanged, but only counts when CONDITION
# (shell text) holds. a "left it alone" assertion would otherwise pass for a command that did nothing at all, so each
# one is paired with proof that the command ran.
world_unchanged_if() {
  local condition="$1"
  shift
  if eval "$condition"; then world_unchanged "$@"; else fail "$1: not counted, because this is false: $condition"; fi
}

# argv_has_no_key: true when no running process has the text in $KEY on its command line. the key is handed to awk through the
# environment, never as an argument: a "ps | grep -F -- $KEY" would find grep's own command line, which holds the key, and so could
# never pass. (awk's own command line holds only the program text.) the caller exports KEY; export -f to use it inside bash -c.
argv_has_no_key() {
  ps -eo args | K="$KEY" awk 'index($0, ENVIRON["K"]) { f = 1 } END { exit f }'
}
