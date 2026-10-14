#!/usr/bin/env bash
# access_control_snapshot.sh: record the linux access control lists a grant is about to change, and
# put them back exactly when the grant is undone. called by the install record's undo lines and by
# the grant rollback and the kill switch, from the pinned copy of this package (see lib/access_control.sh).
#
#   access_control_snapshot.sh record  SNAPSHOT FOLDER yes|no
#   access_control_snapshot.sh restore SNAPSHOT FOLDER yes|no USER
#
# record writes what getfacl shows for FOLDER to SNAPSHOT, and for everything inside it when the
# third argument is yes. a traverse folder (a parent the agent only passes through) is recorded
# alone, so it is no. the snapshot is root only.
#
# restore removes every extended entry under FOLDER (setfacl -b), then puts back the recorded
# entries of the folders and files that had extended entries before the grant and still exist.
# a folder with no list before the grant has none after. a path deleted while the grant was in
# force is skipped, not an error. the snapshot is deleted at the end. when there is no snapshot
# (a grant made before snapshots existed), only the named entries for USER are removed.
#
# restore is idempotent: with no snapshot it only removes USER's named entries, so a second run
# changes nothing.

set -u

# _list_flags RECURSIVE: sets FLAGS for getfacl and setfacl. -P never follows a link.
_list_flags() {
  if [ "$1" = yes ]; then FLAGS="-R -P"; else FLAGS="-P"; fi
}

# _has_extended BLOCK: exit 0 when a recorded block has entries beyond the base owner, group and other.
_has_extended() {
  case "$1" in
    *$'\n'mask::* | *$'\n'default:* | *$'\n'user:?*:* | *$'\n'group:?*:*) return 0 ;;
  esac
  return 1
}

# _kept_blocks SNAPSHOT: print the recorded blocks that had extended entries and whose path still exists.
_kept_blocks() {
  local line block="" path=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      if [ -n "$path" ] && _has_extended "$block" && { [ -e "$path" ] || [ -L "$path" ]; }; then
        printf '%s\n' "$block"
      fi
      block="" path=""
      continue
    fi
    case "$line" in
      "# file: "*) path="${line#\# file: }" ;;
    esac
    block="$block$line"$'\n'
  done < "$1"
  if [ -n "$path" ] && _has_extended "$block" && { [ -e "$path" ] || [ -L "$path" ]; }; then
    printf '%s\n' "$block"
  fi
  return 0
}

record() {
  local snapshot="$1" folder="$2" recursive="$3"
  _list_flags "$recursive"
  mkdir -p "$(dirname "$snapshot")" || return 1
  (
    umask 077
    # FLAGS is deliberately unquoted: it holds one or two option words.
    # shellcheck disable=SC2086
    getfacl --absolute-names $FLAGS -- "$folder" > "$snapshot"
  ) || { rm -f "$snapshot"; return 1; }
}

restore() {
  local snapshot="$1" folder="$2" recursive="$3" user="$4" live
  _list_flags "$recursive"
  if [ ! -s "$snapshot" ]; then
    # shellcheck disable=SC2086
    setfacl $FLAGS -x "u:$user" -- "$folder" || return 1
    if [ "$recursive" = yes ]; then setfacl -R -P -d -x "u:$user" -- "$folder" || return 1; fi
    return 0
  fi
  live="$snapshot.live"
  # shellcheck disable=SC2086
  setfacl $FLAGS -b -- "$folder" || return 1
  _kept_blocks "$snapshot" > "$live" || { rm -f "$live"; return 1; }
  if [ -s "$live" ]; then
    setfacl --restore="$live" || { rm -f "$live"; return 1; }
  fi
  rm -f "$live" "$snapshot"
  rmdir "$(dirname "$snapshot")" 2>/dev/null || true
}

case "${1:-}" in
  record)
    [ "$#" -eq 4 ] || { echo "usage: access_control_snapshot.sh record SNAPSHOT FOLDER yes|no" >&2; exit 2; }
    record "$2" "$3" "$4"
    ;;
  restore)
    [ "$#" -eq 5 ] || { echo "usage: access_control_snapshot.sh restore SNAPSHOT FOLDER yes|no USER" >&2; exit 2; }
    restore "$2" "$3" "$4" "$5"
    ;;
  *)
    echo "usage: access_control_snapshot.sh record|restore ..." >&2
    exit 2
    ;;
esac
