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

# the package name, lowercased, used for directory names like /etc/sirven.
package_name() {
  local file="$1" name
  [ -f "$file" ] || die "cannot find $file; the package name lives there"
  name="$(project_field "$file" name)"
  [ -n "$name" ] || die "project.json has no name field"
  lowercase "$name"
}

# print linux or macos. SIRVEN_OS_OVERRIDE lets tests render the other system's plan.
detect_os() {
  local kernel
  if [ -n "${SIRVEN_OS_OVERRIDE:-}" ]; then
    case "$SIRVEN_OS_OVERRIDE" in
      linux | macos) printf '%s' "$SIRVEN_OS_OVERRIDE"; return 0 ;;
      *) die "SIRVEN_OS_OVERRIDE must be linux or macos, got '$SIRVEN_OS_OVERRIDE'" ;;
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

# _setup_terminal: print where to read answers from (stdin or tty), or nothing when nothing may
# be asked. curl | bash has a pipe on standard input but a person at the terminal, so the
# controlling terminal is used when standard error is one and it can be opened.
_setup_terminal() {
  case "${SIRVEN_INTERACTIVE:-}" in
    yes) printf 'stdin'; return 0 ;;
    no) return 0 ;;
  esac
  if [ -t 0 ]; then
    printf 'stdin'
  elif [ -t 2 ] && (: < /dev/tty) 2>/dev/null; then
    printf 'tty'
  fi
}
