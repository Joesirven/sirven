# shellcheck shell=bash
# macos service user helpers shared by the installer and the install record's undo lines. sourced by
# lib/service_user.sh, and run as a command from the pinned copy by the account's undo:
#   service_user_macos.sh remove USER REAL_NAME
# reads nothing but its arguments.

# service_user_macos_field USER FIELD: what dscl reads for one field. a value with a space comes on the
# line after the field name, so the lines are joined.
service_user_macos_field() {
  dscl . -read "/Users/$1" "$2" 2>/dev/null | awk '
    NR == 1 { sub(/^[^:]*:[ ]*/, ""); value = $0; next }
    { sub(/^[ ]+/, ""); value = (value == "" ? $0 : value " " $0) }
    END { print value }'
}

# service_user_macos_exists USER: a record of that name is there, whatever fields it has. a record with no
# number is still somebody's record.
service_user_macos_exists() {
  dscl . -read "/Users/$1" RecordName >/dev/null 2>&1
}

# service_user_macos_remove USER REAL_NAME: end the account's processes and delete it, but only while it is
# still the account this package made (its real name is the one the install gave it). if somebody replaced
# or renamed it since, it is not ours to delete: say so and leave it.
service_user_macos_remove() {
  local user="$1" real_name="$2"
  service_user_macos_exists "$user" || return 0
  if [ "$(service_user_macos_field "$user" RealName)" != "$real_name" ]; then
    printf '       kept the account %s: its real name is no longer %s, so this package did not make this account\n' "$user" "$real_name" >&2
    return 0
  fi
  { pkill -KILL -u "$user" || true; } && dscl . -delete "/Users/$user"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    remove) [ "$#" -eq 3 ] || { echo "usage: service_user_macos.sh remove USER REAL_NAME" >&2; exit 64; }
      service_user_macos_remove "$2" "$3" ;;
    *) echo "usage: service_user_macos.sh remove USER REAL_NAME" >&2; exit 64 ;;
  esac
fi
