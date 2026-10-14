#!/usr/bin/env bash
# real-install-check.sh: the check that earns macos real apply its place, run once by the owner or an
# agent AFTER the owner has approved a real install on this Mac. nothing runs without that approval.
#
# what it does, in order, for the observer level and then the builder level:
#   1. writes down the before state: accounts, groups, the admin group, the access control lists on the
#      pass-through folders and the granted folder, and every file under sirven's own paths
#   2. prints the real dry run, and checks that a dry run changed nothing
#   3. runs a real install of the level on a throwaway folder, as a throwaway account
#   4. checks every effect (the account, its folders, its record, its access, and what it cannot do)
#   5. runs the install again and checks it finds everything done
#   6. runs the uninstall from the pinned copy the install kept, so no download is needed
#   7. writes down the after state and compares it with the before state
#
# it keeps going after a failed check, so that the uninstall still runs and the machine is put back; the
# summary at the end lists every failure, and the exit status is 1 if there is one.
#
# the only things left behind on purpose, and listed at the end for the owner to remove by hand:
#   the throwaway account's home folder (this package keeps a service user's home folder),
#   the audit log in /var/log/sirven (uninstall keeps it unless asked), the throwaway folder, and the
#   file and folder the builder checks create inside it (kept through the uninstall on purpose: they
#   hold inherited entries, which is the best test that the sweep removes those too).
#
# usage, on the Mac, as the owner, after approval:
#   sudo bash tests/macos/real-install-check.sh --i-have-approval
#
# usage with no approval and no root: the same sequence against a fake root, to see the flow:
#   bash tests/macos/real-install-check.sh --rehearse /tmp/some-empty-folder
#
# the rehearsal records the system commands instead of running them, so it can only prove the order of
# steps, the record, and the files the package writes. the effect checks that need a real account are
# skipped there, and the summary says how many.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: run this with bash, for example: bash $0" >&2
  exit 1
fi

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODE=""
REHEARSE_DIR=""
PASSED=0
FAILED=0
SKIPPED=0
FAILURES=""
LEVEL_USERS="observer:checkobserver builder:checkbuilder"

usage() {
  cat <<END
usage:
  sudo bash tests/macos/real-install-check.sh --i-have-approval
  bash tests/macos/real-install-check.sh --rehearse EMPTY_FOLDER

--i-have-approval    the owner has approved a real install on this Mac. this installs, then removes, a
                     throwaway account at the observer level and again at the builder level, on a
                     throwaway folder under /Users/Shared. it needs root and refuses on anything but macos.
--rehearse FOLDER    no approval and no root: the same sequence on a fake root inside FOLDER.
--help               this text

read docs/research/qa/macos-real-apply-prep.md before running it.
END
}

fatal() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --i-have-approval) MODE=real ;;
    --rehearse)
      [ "$#" -ge 2 ] || fatal "--rehearse needs an empty folder" 64
      MODE=rehearse
      REHEARSE_DIR="$2"
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fatal "unknown option '$1'" 64 ;;
  esac
  shift
done

if [ -z "$MODE" ]; then
  usage >&2
  fatal "refusing to run: this changes the machine, and it needs the owner's approval. pass --i-have-approval once you have it, or --rehearse FOLDER for a run on a fake root." 64
fi

# ---------------------------------------------------------------------------------------------------
# what a run is allowed to be

if [ "$MODE" = real ]; then
  [ "$(uname -s)" = Darwin ] || fatal "a real run is for macos only; use --rehearse FOLDER here" 64
  [ "$(id -u)" = 0 ] || fatal "a real run needs root: sudo bash tests/macos/real-install-check.sh --i-have-approval" 64
  OWNER="${SUDO_USER:-}"
  case "$OWNER" in '' | root) fatal "run it with sudo as the owner's own account, so the owner is known (SUDO_USER is empty or root)" 64 ;; esac
  for pair in $LEVEL_USERS; do
    if dscl . -read "/Users/${pair#*:}" UniqueID >/dev/null 2>&1; then
      fatal "an account named ${pair#*:} is already on this Mac; this check will not touch an account it did not make" 64
    fi
  done
  WORK_DIR="$(mktemp -d /Users/Shared/sirven-check.XXXXXX)"
  chown "$OWNER" "$WORK_DIR"
  chmod 0700 "$WORK_DIR"
else
  [ -d "$REHEARSE_DIR" ] || fatal "$REHEARSE_DIR is not a folder" 64
  [ -z "$(ls -A "$REHEARSE_DIR")" ] || fatal "$REHEARSE_DIR is not empty; give --rehearse an empty folder" 64
  REHEARSE_DIR="$(cd "$REHEARSE_DIR" && pwd)"
  OWNER="${USER:-$(id -un)}"
  WORK_DIR="$REHEARSE_DIR/work"
  mkdir -p "$WORK_DIR"
fi

PROJECT="$WORK_DIR/project"
OUTSIDE="$WORK_DIR/outside"
REPORT_DIR="$WORK_DIR/report"
FAKE_ROOT="$REHEARSE_DIR/root"
mkdir -p "$PROJECT/sub" "$OUTSIDE" "$REPORT_DIR"

# the paths the package keeps, on the real machine or under the fake root
if [ "$MODE" = real ]; then PREFIX=""; else PREFIX="$FAKE_ROOT"; fi
SIRVEN_PATHS="$PREFIX/etc/sirven $PREFIX/var/lib/sirven $PREFIX/var/log/sirven"

# ---------------------------------------------------------------------------------------------------
# the throwaway folder: files the account may read, a file it may not, and links that must not leak

printf 'granted file\n' > "$PROJECT/a.txt"
printf 'granted file in a folder\n' > "$PROJECT/sub/b.txt"
printf 'not granted\n' > "$OUTSIDE/secret.txt"
ln -s ../outside/secret.txt "$PROJECT/file-link"
ln -s ../outside "$PROJECT/folder-link"
# only the owner may use these folders by their ordinary permissions, so the account's access is the
# access control list and nothing else
chmod 0700 "$WORK_DIR" "$PROJECT" "$PROJECT/sub" "$OUTSIDE"
chmod 0600 "$PROJECT/a.txt" "$PROJECT/sub/b.txt" "$OUTSIDE/secret.txt"
if [ "$MODE" = real ]; then
  chown -R "$OWNER" "$WORK_DIR"
fi

# ---------------------------------------------------------------------------------------------------
# small helpers

say() { printf '%s\n' "$*"; }

heading() { printf '\n== %s\n' "$*"; }

# check LABEL COMMAND...: the command must succeed. the run goes on either way.
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    PASSED=$((PASSED + 1))
    printf '  pass: %s\n' "$label"
  else
    FAILED=$((FAILED + 1))
    FAILURES="${FAILURES}  - ${label}
"
    printf '  FAIL: %s\n' "$label"
  fi
}

# check_not LABEL COMMAND...: the command must fail. a refusal is the wanted result.
check_not() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    FAILED=$((FAILED + 1))
    FAILURES="${FAILURES}  - ${label}
"
    printf '  FAIL: %s (it succeeded, and it must not)\n' "$label"
  else
    PASSED=$((PASSED + 1))
    printf '  pass: %s\n' "$label"
  fi
}

# real_only LABEL: a check that needs the real account. counted as skipped in a rehearsal.
real_only() {
  if [ "$MODE" = real ]; then return 0; fi
  SKIPPED=$((SKIPPED + 1))
  printf '  skip: %s (needs a real account; not in a rehearsal)\n' "$1"
  return 1
}

# the installer and the uninstaller, the way the owner would run them. a real run passes the switch
# through sudo's environment on purpose; a rehearsal fakes the operating system and the root.
run_install() {
  local level="$1" user="$2"
  shift 2
  if [ "$MODE" = real ]; then
    env SIRVEN_MACOS_REAL_APPLY=1 bash "$ROOT_DIR/install.sh" --level "$level" --path "$PROJECT" \
      --transport none --yes --user "$user" --owner "$OWNER" "$@"
  else
    SIRVEN_OS_OVERRIDE=macos bash "$ROOT_DIR/install.sh" --level "$level" --path "$PROJECT" \
      --transport none --yes --user "$user" --owner "$OWNER" --prefix "$FAKE_ROOT" "$@"
  fi
}

run_uninstall() {
  if [ "$MODE" = real ]; then
    # from the pinned copy the install kept: this is the path a user has when the download is gone
    env SIRVEN_MACOS_REAL_APPLY=1 bash /var/lib/sirven/package/uninstall.sh
  else
    SIRVEN_OS_OVERRIDE=macos bash "$ROOT_DIR/uninstall.sh" --prefix "$FAKE_ROOT"
  fi
}

# one folder or file: its name, then its mode letters, owner, group, and access list entries. no times,
# because creating a file changes its folder's time and that is not what is compared.
list_one() {
  printf '%s\n' "$1"
  /bin/ls -lde "$1" 2>&1 | awk 'NR == 1 { print "  " $1, $3, $4; next } { print }'
}

list_tree() {
  local item
  /usr/bin/find -P "$1" 2>/dev/null | sort | while IFS= read -r item; do
    list_one "$item"
  done
}

# capture_state FILE: the before or after state. read only.
capture_state() {
  local file="$1" path
  {
    heading "accounts, with account numbers"
    if [ "$MODE" = real ]; then dscl . -list /Users UniqueID | sort; else echo "(rehearsal)"; fi
    heading "groups, with group numbers"
    if [ "$MODE" = real ]; then dscl . -list /Groups PrimaryGroupID | sort; else echo "(rehearsal)"; fi
    heading "members of the admin group"
    if [ "$MODE" = real ]; then dscl . -read /Groups/admin GroupMembership 2>&1; else echo "(rehearsal)"; fi
    heading "members of the staff group"
    if [ "$MODE" = real ]; then dscl . -read /Groups/staff GroupMembership 2>&1; else echo "(rehearsal)"; fi
    heading "who may log in over remote login"
    if [ "$MODE" = real ]; then
      dscl . -read /Groups/com.apple.access_ssh GroupMembership 2>&1
      systemsetup -getremotelogin 2>&1
    else
      echo "(rehearsal)"
    fi
    heading "access lists on the pass-through folders and the granted folder"
    if [ "$MODE" = real ]; then
      for path in /Users /Users/Shared "$WORK_DIR" "$PROJECT"; do list_one "$path"; done
    else
      for path in "$WORK_DIR" "$PROJECT"; do list_one "$path"; done
    fi
    heading "every item in the granted folder"
    list_tree "$PROJECT"
    heading "every item outside the grant"
    list_tree "$OUTSIDE"
    heading "files under the paths sirven keeps"
    # shellcheck disable=SC2086 # SIRVEN_PATHS is three paths with no spaces
    /usr/bin/find -P $SIRVEN_PATHS -exec /usr/bin/stat -f '%N %Sp %Su %Sg' {} + 2>/dev/null | sort
    heading "home folders of the throwaway accounts"
    if [ "$MODE" = real ]; then /bin/ls -d /Users/check* 2>/dev/null | sort; else echo "(rehearsal)"; fi
  } > "$file" 2>&1
}

# what an uninstall leaves on purpose: the home folder of the throwaway account, the audit log directory,
# and the two items the builder checks make inside the granted folder (the account owned them; they stay
# so that the final check can show the sweep took the inherited entries off them). all are taken out of
# the comparison, and the first two are checked on their own.
without_leftovers() {
  awk -v prefix="$PREFIX" -v made="$PROJECT/made-" '
    /^\/Users\/check/ { skip = 1; next }
    index($0, prefix "/var/log/sirven") == 1 { skip = 1; next }
    index($0, made) == 1 { skip = 1; next }
    /^[^ ]/ { skip = 0 }
    skip && /^ / { next }
    { print }' "$1"
}

# ---------------------------------------------------------------------------------------------------
# the effect checks for one level

check_effects() {
  local level="$1" user="$2" home="/Users/$2" record keys
  record="$PREFIX/var/lib/sirven/install-record.tsv"
  keys="$home/.ssh/authorized_keys"

  heading "effects of the $level install"

  # files the package itself writes: these exist in a rehearsal too
  check "the install record exists" test -s "$record"
  check "the pinned copy of the package is in place" test -f "$PREFIX/var/lib/sirven/package/PINNED-COPY"
  check "the $level policy copy is the shipped file" cmp -s "$ROOT_DIR/levels/$level.json" "$PREFIX/etc/sirven/levels/$level.json"
  check "the grant record names the level" grep -q "\"level\": \"$level\"" "$PREFIX/etc/sirven/grants/$user.json"
  check "the audit log exists" test -f "$PREFIX/var/log/sirven/audit.jsonl"
  check "the audit log says the install finished" grep -q 'finished' "$PREFIX/var/log/sirven/audit.jsonl"
  check "the install record lists the account removal" grep -qF "dscl . -delete /Users/$user" "$record"
  check "the install record lists a sweep of every granted folder" grep -qF "access_control_macos.sh sweep $user yes " "$record"

  real_only "the account, its folders, and its access" || return 0

  check "the install record belongs to root and nobody else can write it" \
    sh -c "[ \"\$(stat -f '%Su %Sp' '$record')\" = 'root -rw-------' ]"

  # the account
  check "the account exists with a number" dscl . -read "/Users/$user" UniqueID
  check "the account has a generated identifier, which the access lists use" dscl . -read "/Users/$user" GeneratedUID
  check "the account is hidden" sh -c "[ \"\$(dscl . -read /Users/$user IsHidden | awk '{print \$2}')\" = 1 ]"
  check "the account has no stored password" sh -c "[ \"\$(dscl . -read /Users/$user Password | awk '{print \$2}')\" = '*' ]"
  check "the account's home folder is the one the plan named" sh -c "[ \"\$(dscl . -read /Users/$user NFSHomeDirectory | awk '{print \$2}')\" = '$home' ]"
  check_not "an empty password does not log the account in" dscl . -authonly "$user" ''
  check_not "a wrong password does not log the account in" dscl . -authonly "$user" 'not-the-password'
  check_not "the account is not an administrator (id lists the admin group)" sh -c "id -nG $user | tr ' ' '\\n' | grep -qx admin"
  check_not "the account is not a member of the admin group" dseditgroup -o checkmember -m "$user" admin
  check "the home folder is private to the account" sh -c "[ \"\$(stat -f '%Su %Lp' '$home')\" = '$user 700' ]"
  check "the SSH folder is private to the account" sh -c "[ \"\$(stat -f '%Su %Lp' '$home/.ssh')\" = '$user 700' ]"
  check "the key file is empty and private to the account" sh -c "[ \"\$(stat -f '%Su %Lp %z' '$keys')\" = '$user 600 0' ]"

  # access by list: what the account can read and write inside the grant
  check "the granted folder has the account's entry" sh -c "/bin/ls -lde '$PROJECT' | grep -q 'user:$user allow list'"
  check "a file in the granted folder has the account's entry" sh -c "/bin/ls -lde '$PROJECT/a.txt' | grep -q 'user:$user allow read'"
  check "the account reads a granted file" sudo -u "$user" -H cat "$PROJECT/a.txt"
  check "the account reads a file in a granted subfolder" sudo -u "$user" -H cat "$PROJECT/sub/b.txt"
  check "the account lists the granted folder" sudo -u "$user" -H ls "$PROJECT"
  if [ "$level" = observer ]; then
    check_not "an observer cannot change a granted file" sudo -u "$user" -H sh -c "echo changed >> '$PROJECT/a.txt'"
    check_not "an observer cannot create a file in the granted folder" sudo -u "$user" -H sh -c "echo new > '$PROJECT/made-by-agent.txt'"
  else
    check "a builder changes a granted file" sudo -u "$user" -H sh -c "echo changed >> '$PROJECT/a.txt'"
    check "a builder creates a file in the granted folder" sudo -u "$user" -H sh -c "echo new > '$PROJECT/made-by-agent.txt'"
    check "the new file inherited the account's entry" sh -c "/bin/ls -lde '$PROJECT/made-by-agent.txt' | grep -q 'user:$user inherited'"
    check "a builder creates a folder in the granted folder" sudo -u "$user" -H mkdir "$PROJECT/made-folder"
  fi

  # what the account must not reach
  check_not "the account cannot read a file outside the grant" sudo -u "$user" -H cat "$OUTSIDE/secret.txt"
  check_not "the account cannot list the folder outside the grant" sudo -u "$user" -H ls "$OUTSIDE"
  check_not "the account cannot read through a link inside the grant" sudo -u "$user" -H cat "$PROJECT/file-link"
  check_not "the account cannot list through a folder link inside the grant" sudo -u "$user" -H ls "$PROJECT/folder-link"
  check "no entry landed on what the links point at" sh -c "! /bin/ls -lde '$OUTSIDE' '$OUTSIDE/secret.txt' | grep -q 'user:$user'"
  check_not "the account cannot use sudo" sudo -u "$user" -H sudo -n true
  check_not "the account cannot change its own policy" sudo -u "$user" -H sh -c ": >> /etc/sirven/levels/$level.json"
  check_not "the account cannot change the audit log" sudo -u "$user" -H sh -c ": >> /var/log/sirven/audit.jsonl"
  check_not "the account cannot read the install record" sudo -u "$user" -H cat "$record"
  check_not "the account cannot change the grant record" sudo -u "$user" -H sh -c ": >> /etc/sirven/grants/$user.json"
  # informational: the owner's home folder is the owner's to protect, so this is a finding about the Mac, not a failure
  if sudo -u "$user" -H ls "/Users/$OWNER" >/dev/null 2>&1; then
    printf '  note: the account CAN list /Users/%s: that home folder is open to other accounts on this Mac, which is the Mac'"'"'s own setting\n' "$OWNER"
  else
    printf '  note: the account cannot list /Users/%s, as expected\n' "$OWNER"
  fi
}

# ---------------------------------------------------------------------------------------------------
# one pass: one level, one throwaway account

run_pass() {
  local level="$1" user="$2" before after after_dry status stamp
  stamp="$REPORT_DIR/$level"
  before="$stamp-before.txt"
  after="$stamp-after.txt"
  after_dry="$stamp-after-dry-run.txt"

  heading "PASS: $level level, account $user"
  capture_state "$before"
  say "  before state written to $before"

  heading "the real dry run, which must change nothing"
  run_install "$level" "$user" --dry-run > "$stamp-dry-run.txt" 2>&1
  status=$?
  check "the dry run exits 0" test "$status" = 0
  capture_state "$after_dry"
  check "the dry run changed nothing" diff -q "$before" "$after_dry"

  heading "the real install"
  run_install "$level" "$user" > "$stamp-install.txt" 2>&1
  status=$?
  tail -n 4 "$stamp-install.txt" | sed 's/^/  | /'
  check "the install exits 0" test "$status" = 0
  if [ "$status" != 0 ]; then
    say "  the install failed; its output is in $stamp-install.txt. the uninstall below still runs, to put back what was done."
  fi

  check_effects "$level" "$user"

  heading "the install again, which must find everything done"
  run_install "$level" "$user" > "$stamp-install-again.txt" 2>&1
  status=$?
  check "the second install exits 0" test "$status" = 0
  # the one step with no read-only probe of its end state, the check that the account is not an administrator,
  # runs every time (tag always, as on linux); every other step must have been found done. in a rehearsal
  # even that step counts as done, because its command text is already in the simulation log.
  check "the second install applied at most the one step that has no probe" grep -Eq '^applied [01] steps' "$stamp-install-again.txt"
  check "the second install skipped the finished steps" grep -Eq 'skipped (1[5-9]|[2-9][0-9]) already done' "$stamp-install-again.txt"

  heading "the uninstall, from the pinned copy"
  run_uninstall > "$stamp-uninstall.txt" 2>&1
  status=$?
  tail -n 4 "$stamp-uninstall.txt" | sed 's/^/  | /'
  check "the uninstall exits 0" test "$status" = 0

  capture_state "$after"
  heading "the after state against the before state"
  without_leftovers "$before" > "$stamp-before.compared.txt"
  without_leftovers "$after" > "$stamp-after.compared.txt"
  if diff -u "$stamp-before.compared.txt" "$stamp-after.compared.txt" > "$stamp-state.diff"; then
    PASSED=$((PASSED + 1))
    say "  pass: the machine is as it was, apart from the two things kept on purpose"
  else
    FAILED=$((FAILED + 1))
    FAILURES="${FAILURES}  - $level: the state after the uninstall differs from the state before (see $stamp-state.diff)
"
    say "  FAIL: the state after the uninstall differs from the state before:"
    sed 's/^/    /' "$stamp-state.diff"
  fi
  check "no list entry of the account is left on the granted folder" sh -c "! /usr/bin/find -P '$PROJECT' -exec /bin/ls -lde {} + | grep -q 'user:$user'"
  check "the audit log was kept, as the uninstall says" test -f "$PREFIX/var/log/sirven/audit.jsonl"
  if real_only "the account is gone and its home folder is kept"; then
    check_not "the account is gone" dscl . -read "/Users/$user" UniqueID
    check "the home folder is kept, as the uninstall says" test -d "/Users/$user"
  fi
}

# ---------------------------------------------------------------------------------------------------

heading "sirven real install check ($MODE)"
say "  repository: $ROOT_DIR"
say "  owner: $OWNER"
say "  throwaway folder: $WORK_DIR"
say "  reports: $REPORT_DIR"
if [ "$MODE" = real ]; then
  say "  this Mac: $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m)"
fi

for pair in $LEVEL_USERS; do
  run_pass "${pair%%:*}" "${pair#*:}"
done

heading "summary"
say "  passed: $PASSED, failed: $FAILED, skipped: $SKIPPED"
if [ "$FAILED" -gt 0 ]; then
  printf '  failures:\n%s' "$FAILURES"
fi
heading "left behind on purpose; remove by hand when you have looked"
if [ "$MODE" = real ]; then
  for pair in $LEVEL_USERS; do
    say "  /Users/${pair#*:}   (the throwaway account's home folder)   remove with: sudo rm -rf /Users/${pair#*:}"
  done
  say "  /var/log/sirven   (the audit log, which holds this check's own entries)   remove with: sudo rm -rf /var/log/sirven"
fi
say "  $PROJECT/made-by-agent.txt and made-folder   (made by the builder account; kept through the uninstall to test the sweep)"
say "  $WORK_DIR   (the throwaway folder and the reports)   remove with: sudo rm -rf $WORK_DIR"

[ "$FAILED" -eq 0 ]
