# shellcheck shell=bash
# preflight checks: bash version, python3, commands each path needs, minimum tool versions.
#
# preflight never changes anything. results go to standard error so the plan on standard
# output stays clean. python3 and bash problems always stop the run; missing commands for a
# path only warn in a dry run or under --prefix, and stop a real apply.

# minimum versions we have read the documentation for. bump them on purpose, not by accident.
PREFLIGHT_MINIMUM_BASH="3.2"
PREFLIGHT_MINIMUM_PYTHON="3.6"
PREFLIGHT_MINIMUM_TAILSCALE="1.60.0"
PREFLIGHT_MINIMUM_CLOUDFLARED="2024.1.0"

PREFLIGHT_PROBLEMS=0

# version_at_least HAVE WANT: true when dotted version HAVE is at least WANT.
version_at_least() {
  local have="$1" want="$2" have_part want_part
  while [ -n "$want" ]; do
    have_part="${have%%.*}"
    want_part="${want%%.*}"
    have_part="${have_part%%[!0-9]*}"
    want_part="${want_part%%[!0-9]*}"
    [ -n "$have_part" ] || have_part=0
    [ -n "$want_part" ] || want_part=0
    if [ "$have_part" -gt "$want_part" ]; then return 0; fi
    if [ "$have_part" -lt "$want_part" ]; then return 1; fi
    case "$have" in *.*) have="${have#*.}" ;; *) have="" ;; esac
    case "$want" in *.*) want="${want#*.}" ;; *) want="" ;; esac
  done
  return 0
}

# first dotted number in a string, like 1.62.0 out of "1.62.0-t1234 go1.22".
first_version() {
  printf '%s\n' "$1" | sed -n 's/[^0-9]*\([0-9][0-9]*\(\.[0-9][0-9]*\)*\).*/\1/p' | head -n 1
}

_preflight_problem() {
  local strict="$1" message="$2"
  if [ "$strict" = yes ]; then
    printf 'preflight: missing: %s\n' "$message" >&2
    PREFLIGHT_PROBLEMS=$((PREFLIGHT_PROBLEMS + 1))
  else
    printf 'preflight: warning: %s (fine for a dry run or a fake root, needed to apply for real)\n' "$message" >&2
  fi
}

preflight_bash() {
  local have="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  if ! version_at_least "$have" "$PREFLIGHT_MINIMUM_BASH"; then
    die "bash $have is too old; the package needs bash $PREFLIGHT_MINIMUM_BASH or newer"
  fi
  printf 'preflight: ok bash %s\n' "$have" >&2
}

# python3 runs the grant compiler. without it there is no plan, so stop loudly.
preflight_python() {
  local version
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 was not found on PATH. the grant compiler needs python $PREFLIGHT_MINIMUM_PYTHON or newer.
  on macos: install the command line developer tools with 'xcode-select --install'
  on linux: install your distribution's python3 package, for example 'apt install python3'"
  fi
  version="$(first_version "$(python3 --version 2>&1)")"
  if ! version_at_least "$version" "$PREFLIGHT_MINIMUM_PYTHON"; then
    die "python3 $version is too old; the grant compiler needs $PREFLIGHT_MINIMUM_PYTHON or newer"
  fi
  printf 'preflight: ok python3 %s\n' "$version" >&2
}

# preflight_commands STRICT NAME... : every command must be on PATH.
preflight_commands() {
  local strict="$1" name missing=""
  shift
  for name in "$@"; do
    if ! command -v "$name" >/dev/null 2>&1; then
      missing="$missing $name"
    fi
  done
  if [ -n "$missing" ]; then
    _preflight_problem "$strict" "commands not found:$missing"
  fi
}

# preflight_tool STRICT COMMAND MINIMUM VERSION_ARGUMENT...
preflight_tool() {
  local strict="$1" name="$2" minimum="$3" output version
  shift 3
  if ! command -v "$name" >/dev/null 2>&1; then
    _preflight_problem "$strict" "$name $minimum or newer is not installed"
    return 0
  fi
  output="$("$name" "$@" 2>&1 | head -n 1)" || true
  version="$(first_version "$output")"
  if [ -z "$version" ]; then
    _preflight_problem "$strict" "could not read the $name version from '$output'"
  elif ! version_at_least "$version" "$minimum"; then
    _preflight_problem "$strict" "$name $version is older than the pinned minimum $minimum"
  else
    printf 'preflight: ok %s %s\n' "$name" "$version" >&2
  fi
}

# preflight_all OPERATING_SYSTEM TRANSPORT STRICT
# STRICT is no for a dry run and for a fake root, where system commands are recorded, not run.
preflight_all() {
  local os="$1" transport="$2" strict="$3"
  PREFLIGHT_PROBLEMS=0
  preflight_bash
  preflight_python
  preflight_commands yes mkdir chmod cp cmp touch grep sed tr head id uname dirname
  case "$os" in
    linux) preflight_commands "$strict" useradd usermod getent id install setfacl getfacl chown pkill ;;
    macos) preflight_commands "$strict" dscl dseditgroup createhomedir find chown pkill ;;
  esac
  case "$transport" in
    tailscale) preflight_tool "$strict" tailscale "$PREFLIGHT_MINIMUM_TAILSCALE" version ;;
    cloudflare) preflight_tool "$strict" cloudflared "$PREFLIGHT_MINIMUM_CLOUDFLARED" --version ;;
  esac
  if [ "$PREFLIGHT_PROBLEMS" -gt 0 ]; then
    die "preflight found $PREFLIGHT_PROBLEMS problem(s); nothing was changed"
  fi
}
