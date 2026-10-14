#!/usr/bin/env bash
# golden files: pinned dry-run plans and grant compiler fragments.
#
# each case runs a command and compares its standard output with tests/golden/NAME.txt.
# the fake root changes every run, so it is written as <prefix> before comparing.
#
#   bash tests/golden/run.sh                      compare, print a diff on mismatch
#   SIRVEN_UPDATE_GOLDEN=1 bash tests/golden/run.sh  regenerate every golden file
#
# review a regenerated diff with git before committing it: it is the behavior change.

set -uo pipefail

GOLDEN_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$GOLDEN_DIR/../.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sirven-golden.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# the machine running the goldens must not show through: its Tailscale and bb are never probed.
# the adopt case points these at the fakes in tests/fixtures/adopt.
SIRVEN_TAILSCALE=none
SIRVEN_BB=none
export SIRVEN_TAILSCALE SIRVEN_BB
FAKES="$REPO_DIR/tests/fixtures/adopt"

INSTALL="$REPO_DIR/install.sh"
UNINSTALL="$REPO_DIR/uninstall.sh"
COMPILER="$REPO_DIR/lib/grant_compiler.py"
LEVELS="$REPO_DIR/levels"

failures=0

# case_prefix NAME: the fake root for one case.
case_prefix() {
  printf '%s/%s-root' "$WORK_DIR" "$1"
}

# golden_case NAME OPERATING_SYSTEM COMMAND...
golden_case() {
  local name="$1" os="$2" prefix actual expected status=0
  shift 2
  prefix="$(case_prefix "$name")"
  actual="$WORK_DIR/$name.txt"
  expected="$GOLDEN_DIR/$name.txt"
  SIRVEN_OS_OVERRIDE="$os" "$@" < /dev/null > "$actual.raw" 2> "$actual.error" || status=$?
  {
    sed "s|$prefix|<prefix>|g" "$actual.raw"
    printf 'exit status: %s\n' "$status"
  } > "$actual"
  if [ -n "${SIRVEN_UPDATE_GOLDEN:-}" ]; then
    cp "$actual" "$expected"
    printf 'ok %s (regenerated)\n' "$name"
  elif [ ! -f "$expected" ]; then
    printf 'not ok %s: no golden file; run with SIRVEN_UPDATE_GOLDEN=1 to create it\n' "$name"
    failures=$((failures + 1))
  elif diff -u "$expected" "$actual" > "$WORK_DIR/$name.diff"; then
    printf 'ok %s\n' "$name"
  else
    printf 'not ok %s: output differs from tests/golden/%s.txt\n' "$name" "$name"
    sed 's/^/    /' "$WORK_DIR/$name.diff"
    if [ -s "$actual.error" ]; then
      printf '    standard error:\n'
      sed 's/^/      /' "$actual.error"
    fi
    failures=$((failures + 1))
  fi
}

# install_case NAME OPERATING_SYSTEM ARGUMENT...: a dry run of install.sh on a fake root.
install_case() {
  local name="$1" os="$2"
  shift 2
  golden_case "$name" "$os" "$INSTALL" "$@" --dry-run --prefix "$(case_prefix "$name")" --owner example
}

# uninstall_case NAME OPERATING_SYSTEM INSTALL_ARGUMENT...: apply install.sh to a fake root, then
# pin the dry run of uninstall.sh on that root.
uninstall_case() {
  local name="$1" os="$2" prefix
  shift 2
  prefix="$(case_prefix "$name")"
  if ! SIRVEN_OS_OVERRIDE="$os" "$INSTALL" "$@" --prefix "$prefix" --owner example > /dev/null 2>&1; then
    printf 'not ok %s: the install before it failed\n' "$name"
    failures=$((failures + 1))
    return 0
  fi
  golden_case "$name" "$os" "$UNINSTALL" --dry-run --prefix "$prefix"
}

# compiler_case NAME OPERATING_SYSTEM SUBCOMMAND LEVEL: the grant compiler on a fixed path list,
# unsorted, with a duplicate, a trailing slash, and a nested path, to pin the normalizing.
compiler_case() {
  local name="$1" os="$2" subcommand="$3" level="$4"
  if [ "$os" = linux ]; then
    set -- --path /srv/b --path /srv/a/ --path /srv/b --path /home/example/my-project --path /home/example/my-project/vendor
  else
    set -- --path /Users/example/code/b --path /Users/example/code/a/ --path /Users/example/code/b --path /opt/work/site --path /opt/work/site/vendor
  fi
  golden_case "$name" "$os" python3 "$COMPILER" "$subcommand" --level "$LEVELS/$level.json" \
    --os "$os" --user agent --prefix "$(case_prefix "$name")" "$@"
}

# dry-run plans
install_case install-linux-builder-tailscale linux --level builder --path /home/example/project --transport tailscale
install_case install-linux-observer-none linux --level observer --path /srv/app --path /home/example/notes --transport none
install_case install-macos-builder-tailscale-bb macos --level builder --path /Users/example/code/app --transport tailscale --with-bb
install_case install-macos-operator-cloudflare macos --level operator --path /Users/example/code/site --transport cloudflare
install_case install-macos-builder-none macos --level builder --path /Users/example/code/app --transport none
install_case revoke-linux-tailscale linux revoke --all --level builder --path /home/example/project --transport tailscale
install_case revoke-macos-cloudflare macos revoke --all --level observer --path /Users/example/code/app --transport cloudflare

# removal plans: after an install, and with nothing recorded
uninstall_case uninstall-linux-builder-none linux --level builder --path /home/example/project --path /srv/app --transport none
uninstall_case uninstall-macos-builder-none macos --level builder --path /Users/example/code/app --path /opt/work/site --transport none
golden_case uninstall-nothing-recorded linux "$UNINSTALL" --dry-run --prefix "$(case_prefix uninstall-nothing-recorded)"

# adopt_case NAME OPERATING_SYSTEM INSTALL_ARGUMENT...: apply install.sh to a fake root on a
# machine whose fake Tailscale already has this machine as the agent node and whose fake bb is
# installed, then pin the dry run of a second install with no level and no path given: it adopts
# the grant in force, Tailscale, bb, and the audit log, and changes nothing.
adopt_case() {
  local name="$1" os="$2" prefix
  shift 2
  prefix="$(case_prefix "$name")"
  if ! SIRVEN_OS_OVERRIDE="$os" SIRVEN_TAILSCALE="$FAKES/tailscale" SIRVEN_BB="$FAKES/bb" \
    "$INSTALL" "$@" --prefix "$prefix" --owner example > /dev/null 2>&1; then
    printf 'not ok %s: the install before it failed\n' "$name"
    failures=$((failures + 1))
    return 0
  fi
  golden_case "$name" "$os" env SIRVEN_TAILSCALE="$FAKES/tailscale" SIRVEN_BB="$FAKES/bb" \
    "$INSTALL" --dry-run --prefix "$prefix" --owner example --transport tailscale --with-bb
}

# adoption: a second run on a machine that already has Tailscale, bb, and an earlier install
adopt_case adopt-linux-builder-tailscale-bb linux --level builder --path /home/example/project --transport tailscale --with-bb

# grant compiler fragments, both operating systems, every level
for os in linux macos; do
  for level in observer builder operator; do
    compiler_case "compile-$os-$level" "$os" compile "$level"
  done
  compiler_case "revoke-fragment-$os-builder" "$os" revoke builder
done

if [ "$failures" -gt 0 ]; then
  exit 1
fi
