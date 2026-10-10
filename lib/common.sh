# shellcheck shell=bash
# common helpers. sourced by install.sh and the tests. works on bash 3.2 and newer.

say() {
  printf '%s\n' "$*"
}

warn() {
  printf '%s\n' "warning: $*" >&2
}

die() {
  printf '%s\n' "error: $*" >&2
  exit "${DIE_STATUS:-1}"
}

# quote one word for a shell command line, so plans can be shown and evaluated.
shell_quote() {
  printf '%q' "$1"
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# read a top level string field from project.json without a JSON parser.
# project.json keeps one field per line, so a line match is enough.
project_field() {
  local file="$1" field="$2"
  sed -n "s/^[[:space:]]*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n 1
}

# the package name, lowercased, used for directory names like /etc/sirv.
package_name() {
  local file="$1" name
  [ -f "$file" ] || die "cannot find $file; the package name lives there"
  name="$(project_field "$file" name)"
  [ -n "$name" ] || die "project.json has no name field"
  lowercase "$name"
}

# print linux or macos. SIRV_OS_OVERRIDE lets tests render the other system's plan.
detect_os() {
  local kernel
  if [ -n "${SIRV_OS_OVERRIDE:-}" ]; then
    case "$SIRV_OS_OVERRIDE" in
      linux | macos) printf '%s' "$SIRV_OS_OVERRIDE"; return 0 ;;
      *) die "SIRV_OS_OVERRIDE must be linux or macos, got '$SIRV_OS_OVERRIDE'" ;;
    esac
  fi
  kernel="$(uname -s)"
  case "$kernel" in
    Linux) printf 'linux' ;;
    Darwin) printf 'macos' ;;
    *) die "unsupported operating system '$kernel'; only macos and linux are supported" ;;
  esac
}

# true when this process runs inside a container (docker or podman).
in_container() {
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
    return 0
  fi
  if [ -r /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container='; then
    return 0
  fi
  return 1
}
