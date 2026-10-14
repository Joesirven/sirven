# shellcheck shell=bash
# the first library an entry script reads, before any other: root must not run code the agent could have changed.
#
# every command sirven runs as root on a real machine (install, uninstall, grant rollback, grant repair, revoke)
# passes trust_gate before it reads another library. the agent owns its home folder and, at the builder level,
# the folders it was granted, which is often the folder the package was unpacked in; code it edited would run
# as root and could make the kill switch a no-op that prints success.
#
#   - the kept copy in $STATE_DIR/package is root-owned and nothing else can write it. when it exists and this is
#     not it, uninstall, rollback, repair and revoke run it instead (the same arguments, a new process). install
#     is the exception because it is how a newer release replaces the kept copy: it runs from where it is
#     started only if nobody but root and the owner can write that folder, and runs the kept copy otherwise.
#   - with no kept copy (the first install, or a revoke on a machine that never had one), the folder it runs from
#     must not be writable by the service user or any account but root and the owner, the whole way to it.
#
# skipped for --prefix (a fake root), --dry-run and --help: they change nothing on the real machine.
#
# the entry scripts read this file from the kept copy when there is one (so an edit of this file in a folder the agent
# can write does nothing), and trust_gate runs the kept copy's trust.py. what this cannot do: if the entry script the
# owner starts was itself edited, nothing here can notice. to be sure, run the kept copy:
#   sudo bash /var/lib/sirven/package/install.sh revoke --all

# trust_gate KIND ENTRY ARGUMENT...: KIND is install, uninstall, rollback, repair or revoke; ENTRY is the path of
# the entry script relative to the package folder (install.sh, uninstall.sh, bin/sirven).
trust_gate() {
  local kind="$1" entry="$2" user=agent owner="${SUDO_USER:-}" prefix=no dry=no package pinned here there output
  local argument previous=""
  shift 2
  [ -n "$owner" ] || owner="$(id -un 2>/dev/null || true)"
  # read the arguments without consuming them: they are passed on if the kept copy is run instead
  for argument in "$@"; do
    case "$argument" in
      --prefix | --prefix=*) prefix=yes ;;
      --dry-run | --help | -h) dry=yes ;;
      --user=*) user="${argument#*=}" ;;
      --owner=*) owner="${argument#*=}" ;;
    esac
    case "$previous" in
      --user) user="$argument" ;;
      --owner) owner="$argument" ;;
    esac
    previous="$argument"
  done
  [ "$prefix" = no ] && [ "$dry" = no ] || return 0
  [ "$(uname -s)" = Linux ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0   # the preflight says so, in words, a moment later

  package="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT_DIR/project.json" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]')"
  [ -n "$package" ] || package=sirven
  pinned="/var/lib/$package/package"
  here="$(cd "$ROOT_DIR" && pwd -P)"
  there=""
  if [ -f "$pinned/$entry" ]; then there="$(cd "$pinned" && pwd -P)"; fi

  if [ -n "$there" ] && [ "$here" != "$there" ]; then
    if [ "$kind" = install ] && python3 -I "$there/lib/trust.py" check "$here" "$user" "$owner" >/dev/null 2>&1; then
      return 0
    fi
    if ! output="$(python3 -I "$there/lib/trust.py" check "$there" "$user" "$owner" 2>&1)"; then
      printf 'error: the kept copy %s can be written by an account other than root and %s, so it is not trusted either:\n%s\nnothing was changed.\n' "$there" "$owner" "$output" >&2
      exit 2
    fi
    printf 'running the kept copy %s instead of %s: root runs the root-owned copy, not a folder an agent may have changed.\n' "$there" "$here" >&2
    exec bash "$there/$entry" "$@"
  fi

  if ! output="$(python3 -I "$here/lib/trust.py" check "$here" "$user" "$owner" 2>&1)"; then
    printf 'error: refusing to run %s as root from %s: an account other than root and %s can change the code there, and it would run as root:\n%s\n' "$kind" "$here" "$owner" "$output" >&2
    printf 'there is no kept copy to run instead. run it from a folder only %s can write, or after an install: sudo bash %s/%s ...\nnothing was changed.\n' "$owner" "$pinned" "$entry" >&2
    exit 2
  fi
}
