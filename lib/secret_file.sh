# shellcheck shell=bash
# secret_file.sh: the checks a saved secret file (a Tailscale auth key, a Cloudflare API token) must pass before it is read. sourced by
# lib/tailscale_node.sh and lib/cloudflare_tunnel.sh, which run from the pinned copy of this package; it starts no process of its own
# except ls, cut, awk, getfacl, id and uname, which the checks need.

# has_extended_access_list FILE: true when FILE carries an access control list beyond the plain owner, group and other bits, which
# is a way to give another account access that the mode bits do not show. looked for on purpose, in every way the machine offers,
# and never worked out from the mode: on Linux the group bits of such a file show the mask, which can read '---' while a named
# entry sits behind it, and a later chmod g+r would let the entry through.
#   - the '+' that ls prints after the mode (Linux), whether or not getfacl is installed;
#   - any named user or group entry, a mask or a default entry in what getfacl prints (Linux);
#   - the entries ls -e lists under the file (macOS, where ls prints '@' instead of '+' when the file has extended attributes too).
has_extended_access_list() {
  local file="$1" listing entries
  listing="$(ls -ldn "$file" 2>/dev/null)" || return 0
  [ "$(printf '%s' "$listing" | cut -c11)" != "+" ] || return 0
  # each listing is read into a variable first: under pipefail, grep -q ending early would otherwise make the pipeline fail
  if command -v getfacl >/dev/null 2>&1; then
    entries="$(getfacl -p -c -- "$file" 2>/dev/null)" || true
    ! printf '%s\n' "$entries" | grep -Eq '^(default:|mask:|(user|group):[^:])' || return 0
  fi
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    # shellcheck disable=SC2012 # only ls -e prints the access entries of a file on macOS; find cannot
    entries="$(ls -ldne "$file" 2>/dev/null | tail -n +2)" || true
    ! printf '%s\n' "$entries" | grep -Eq '^ *[0-9]+: ' || return 0
  fi
  return 1
}

# key_file_problem FILE: why FILE may not be read as the auth key, or nothing when it may (or is not there at all).
# a key file must be a plain file (not a link, one name only), owned by root (by whoever runs this, when that is not root, which only the tests do),
# with no extended access list and no permission for the group or for anyone else: a file others can write picks the tailnet this
# machine joins, and a file others can read leaks the key.
key_file_problem() {
  local file="$1" listing mode owner links
  [ -e "$file" ] || [ -L "$file" ] || return 0
  listing="$(ls -ldn "$file" 2>/dev/null)" || { printf 'it cannot be examined'; return 0; }
  mode="$(printf '%s' "$listing" | cut -c1-10)"
  owner="$(printf '%s' "$listing" | awk '{print $3}')"
  links="$(printf '%s' "$listing" | awk '{print $2}')"
  case "$mode" in
    -*) ;;
    *) printf 'it is not a plain file (a link or a folder is not used)'; return 0 ;;
  esac
  if [ "$owner" != "$(id -u)" ]; then
    printf 'it is owned by account number %s, not by root' "$owner"
    return 0
  fi
  # a second name for the same file (a hard link) passes the owner and mode checks above, but the removal after the join deletes only
  # the name it was given, so the key would stay on disk under the other name. a bind mount or a link made after this check has run
  # is not caught here at all (both need root), and the same removal leaves the key on disk under it.
  case "$links" in
    1) ;;
    *) printf 'it has more than one name (%s hard links): the removal after the join deletes only one of them, so the key would stay on disk under the other; copy the key into a new file (umask 077; cat KEY_FILE > NEW_FILE), mode 0600, and remove the old names' "$links"; return 0 ;;
  esac
  if has_extended_access_list "$file"; then
    printf 'it has an extended access control list, an access entry beyond the owner, group and other bits (the mode bits do not show who it lets in); remove it (setfacl -b on Linux, chmod -N on macOS) and keep the mode 0600'
    return 0
  fi
  case "${mode#????}" in
    ------) ;;
    *) printf 'its mode is %s: the group or others have permission on it; make it 0600 (chmod 600)' "$mode" ;;
  esac
}
