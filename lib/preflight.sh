# shellcheck shell=bash
# preflight checks: bash version, python3, commands each path needs, minimum tool versions, and
# whether this machine's SSH server answers.
#
# preflight never changes anything. results go to standard error so the plan on standard
# output stays clean. python3 and bash problems always stop the run; missing commands for a
# path only warn in a dry run or under --prefix, and stop a real apply. the SSH server probe
# only runs before a real apply and only ever warns: the installer never configures it.
#
# idempotency lives in the plan, not here: every step carries a read-only check, and a step
# whose end state already exists shows as already done and is skipped on apply.

# minimum versions we have read the documentation for. bump them on purpose, not by accident.
PREFLIGHT_MINIMUM_BASH="3.2"
PREFLIGHT_MINIMUM_PYTHON="3.6"
PREFLIGHT_MINIMUM_TAILSCALE="1.60.0"
PREFLIGHT_MINIMUM_CLOUDFLARED="2024.1.0"

PREFLIGHT_PROBLEMS=0
PREFLIGHT_SSH_COMMAND="${PREFLIGHT_SSH_COMMAND:-ssh}"

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

# preflight_bash [VERSION]: the running bash, or VERSION, must meet the floor. the floor is the
# bash macos ships as /bin/bash, so nothing in the package may need a newer one.
preflight_bash() {
  local have="${1:-${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}}"
  if ! version_at_least "$have" "$PREFLIGHT_MINIMUM_BASH"; then
    die "bash $have is too old; the package needs bash $PREFLIGHT_MINIMUM_BASH or newer, the version macos ships as /bin/bash"
  fi
  printf 'preflight: ok bash %s\n' "$have" >&2
}

# PREFLIGHT_SYSTEM_PYTHON: the python3 that macos ships. on a Mac without the command line
# developer tools it is a placeholder that only opens a system dialog. a variable, so tests can
# point it at a fake.
PREFLIGHT_SYSTEM_PYTHON="${PREFLIGHT_SYSTEM_PYTHON:-/usr/bin/python3}"

# _preflight_placeholder_python: true on a Mac where python3 is the placeholder. it asks
# xcode-select first, so the placeholder itself is never run, and it never runs a python3 that
# is not the system one: a Homebrew or pyenv python3 works without the developer tools.
_preflight_placeholder_python() {
  command -v xcode-select >/dev/null 2>&1 || return 1
  if xcode-select -p >/dev/null 2>&1; then return 1; fi
  case "$(command -v python3 2>/dev/null)" in
    '' | "$PREFLIGHT_SYSTEM_PYTHON") return 0 ;;
  esac
  return 1
}

# python3 runs the grant compiler. without it there is no plan, so stop loudly.
# preflight_python [OPERATING_SYSTEM]: the operating system decides the guidance on a Mac.
preflight_python() {
  local operating_system="${1:-}" version
  if [ "$operating_system" = macos ] && _preflight_placeholder_python; then
    die "python3 is Apple's placeholder: the command line developer tools are not installed, so it only opens a system dialog.
  install them with: xcode-select --install
  wait for that install to finish (it is about 2 GB), then run this again. nothing was changed."
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 was not found on PATH. the grant compiler needs python $PREFLIGHT_MINIMUM_PYTHON or newer.
  on macos: install the command line developer tools with 'xcode-select --install'
  on linux: install your distribution's python3 package, for example 'apt install python3'"
  fi
  version="$(first_version "$(python3 --version 2>&1)")"
  if ! version_at_least "$version" "$PREFLIGHT_MINIMUM_PYTHON"; then
    die "python3 $version is too old; the grant compiler needs $PREFLIGHT_MINIMUM_PYTHON or newer"
  fi
  if [ "$operating_system" = linux ] && ! python3 -c 'import sqlite3' >/dev/null 2>&1; then
    die "python3 on this machine has no sqlite3 module, which the access control snapshot needs.
  install the python3 standard library package, for example 'apt install python3' on Ubuntu or Debian (a
  'python3-minimal' install without the recommended packages leaves it out). nothing was changed."
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

# preflight_ssh_probe HOST [PORT] [SECONDS]: does an SSH server answer at HOST? prints one word,
# reachable, refused, timeout, unresolved, or unknown, and returns 0 only for reachable.
# it never logs in and writes nothing: strict host key checking against empty known hosts files
# ends the connection as soon as the server shows its key, before any authentication.
preflight_ssh_probe() {
  local host="$1" port="${2:-22}" seconds="${3:-5}" output
  case "$host" in
    '' | -* | *[!A-Za-z0-9._:-]*) printf 'unknown'; return 2 ;;
  esac
  case "$port$seconds" in
    *[!0-9]*) printf 'unknown'; return 2 ;;
  esac
  if output="$("$PREFLIGHT_SSH_COMMAND" -o BatchMode=yes -o ConnectTimeout="$seconds" \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
    -p "$port" "probe@$host" true 2>&1)"; then
    printf 'reachable'
    return 0
  fi
  case "$output" in
    *"Host key verification failed"* | *"Permission denied"* | *"no hostkey alg"* | *"No matching host key"*)
      printf 'reachable'
      return 0
      ;;
    *"Connection refused"*) printf 'refused' ;;
    *"timed out"*) printf 'timeout' ;;
    *"Could not resolve"* | *"not known"* | *"nodename nor servname"*) printf 'unresolved' ;;
    *) printf 'unknown' ;;
  esac
  return 1
}

# preflight_ssh_server STRICT: before a real apply, check that this machine's SSH server answers,
# since the agent client connects through it. a soft warning either way: the installer never
# turns it on or changes it. a dry run or a fake root contacts nothing.
preflight_ssh_server() {
  local strict="$1" result
  if [ "$strict" != yes ]; then
    printf 'preflight: skipped the SSH server probe: a dry run or a fake root contacts nothing\n' >&2
    return 0
  fi
  if ! command -v "$PREFLIGHT_SSH_COMMAND" >/dev/null 2>&1; then
    printf 'preflight: warning: no ssh client to probe this machine'"'"'s SSH server with\n' >&2
    return 0
  fi
  if result="$(preflight_ssh_probe localhost 22 3)"; then
    printf 'preflight: ok SSH server answers on this machine\n' >&2
  else
    printf 'preflight: warning: no SSH server answered on this machine (%s). the agent client connects through it: turn on remote login (macos) or start sshd (linux). this installer never changes it.\n' "$result" >&2
  fi
}

# preflight_all OPERATING_SYSTEM TRANSPORT STRICT
# STRICT is no for a dry run and for a fake root, where system commands are recorded, not run.
preflight_all() {
  local os="$1" transport="$2" strict="$3"
  PREFLIGHT_PROBLEMS=0
PREFLIGHT_SSH_COMMAND="${PREFLIGHT_SSH_COMMAND:-ssh}"
  preflight_bash
  preflight_python "$os"
  preflight_commands yes mkdir chmod cp cmp touch grep sed tr head id uname dirname
  case "$os" in
    linux) preflight_commands "$strict" useradd usermod getent id install setfacl getfacl chown pkill ;;
    macos) preflight_commands "$strict" dscl dseditgroup createhomedir find chown pkill ;;
  esac
  case "$transport" in
    tailscale) preflight_tool "$strict" tailscale "$PREFLIGHT_MINIMUM_TAILSCALE" version ;;
    cloudflare) preflight_tool "$strict" cloudflared "$PREFLIGHT_MINIMUM_CLOUDFLARED" --version ;;
  esac
  preflight_ssh_server "$strict"
  if [ "$PREFLIGHT_PROBLEMS" -gt 0 ]; then
    die "preflight found $PREFLIGHT_PROBLEMS problem(s); nothing was changed"
  fi
}

# preflight_revoke OPERATING_SYSTEM STRICT: only what the kill switch itself runs. no transport tool is
# asked for, because a machine that lost its tailscale or never had it must still be cut off.
preflight_revoke() {
  local os="$1" strict="$2"
  PREFLIGHT_PROBLEMS=0
  preflight_bash
  preflight_python "$os"
  preflight_commands yes grep sed tr head id uname dirname cut mv rm date
  case "$os" in
    linux) preflight_commands "$strict" usermod getent pkill pgrep ;;
    macos) preflight_commands "$strict" dscl pkill pgrep ;;
  esac
  if [ "$PREFLIGHT_PROBLEMS" -gt 0 ]; then
    die "preflight found $PREFLIGHT_PROBLEMS problem(s); nothing was changed"
  fi
}
