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

# the package name, lowercased, used for directory names like /etc/sirven. it becomes part of paths root works in, so only
# lowercase letters, digits and hyphens are accepted, and not a leading hyphen: no slash, no "..", nothing else.
package_name() {
  local file="$1" name
  [ -f "$file" ] || die "cannot find $file; the package name lives there"
  name="$(project_field "$file" name)"
  [ -n "$name" ] || die "project.json has no name field"
  name="$(lowercase "$name")"
  case "$name" in
    '' | -* | *[!a-z0-9-]*) die "the package name '$name' in $file is not a plain lowercase name (letters, digits, hyphens); it is part of paths root works in, so nothing was changed" ;;
  esac
  printf '%s' "$name"
}

# prefix_normalize VALUE: the fake root as an absolute path with no trailing slash. a prefix that is the real root, or
# resolves to it (/, //, /., /..), is refused: --prefix / would otherwise turn into no prefix at all, a real run.
prefix_normalize() {
  local value="$1" stripped resolved
  stripped="$value"
  while [ "${stripped%/}" != "$stripped" ]; do stripped="${stripped%/}"; done
  resolved="$(cd -P "$value" 2>/dev/null && pwd -P || true)"
  if [ -z "$stripped" ] || [ "$resolved" = / ]; then return 1; fi
  printf '%s' "$stripped"
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
