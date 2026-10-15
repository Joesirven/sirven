#!/usr/bin/env bash
# sirven bootstrap, served at https://cli.sirven.xyz
#
# What this does, and nothing else:
#   1. downloads one pinned release of the public sirven repository: the archive attached to a
#      GitHub release for one git tag
#   2. checks the archive's checksum (a 256-bit secure hash) against the one pinned below, before
#      anything is unpacked or run
#   3. unpacks it into a fresh temporary directory, runs its install.sh with the arguments you
#      passed, then deletes the directory. if this script is stopped, the installer is stopped too
#
# Read it before running:   curl -fsSL https://cli.sirven.xyz
# Preview the plan safely:  curl -fsSL https://cli.sirven.xyz | bash -s -- --dry-run
# Installer options:        curl -fsSL https://cli.sirven.xyz | bash -s -- --help
#
# The two pin lines below are written by bootstrap/release.sh, never by hand. An empty pin means
# no release has been pinned yet, and this file refuses to install anything.

set -euo pipefail

SIRVEN_REPOSITORY="Joesirven/sirven"

# release pin, written by bootstrap/release.sh: the git tag, and the checksum of its archive.
SIRVEN_PINNED_TAG="v0.2.0"
SIRVEN_PINNED_SHA256="7750941c45a627f353362dda0a7f54e5b589cdf4e5b0f6bef78ba5e00beeb6ad"

# the arguments as they were given. main checks them again before it runs anything, so a download
# cut off in its last line can never run the installer with different arguments.
SIRVEN_BOOTSTRAP_ARGUMENTS="$*"
SIRVEN_BOOTSTRAP_ARGUMENT_COUNT=$#

SIRVEN_BOOTSTRAP_DIR=""
SIRVEN_BOOTSTRAP_CHILD=""

cleanup() {
  if [ -n "$SIRVEN_BOOTSTRAP_DIR" ]; then
    rm -rf "$SIRVEN_BOOTSTRAP_DIR"
  fi
}

fail() {
  echo "sirven bootstrap: $1" >&2
  exit 1
}

# process_tree PID: print PID and every process started under it, at any depth. a background command
# in a non-interactive shell ignores interrupts, so a stop has to reach its children by number.
process_tree() {
  local child
  printf "%s\n" "$1"
  for child in $(ps -A -o pid= -o ppid= | awk -v parent="$1" '$2 == parent { print $1 }'); do
    process_tree "$child"
  done
}

# stop_installer STATUS: stop the installer and every process it started, then exit with STATUS. the
# installer's running steps, such as python3 or useradd, must not finish after the installer that would
# record them is gone. TERM first, a short grace period, then KILL for anything still alive.
stop_installer() {
  local pids pid waited=0 alive
  if [ -n "$SIRVEN_BOOTSTRAP_CHILD" ]; then
    pids="$(process_tree "$SIRVEN_BOOTSTRAP_CHILD")"
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    while [ "$waited" -lt 30 ]; do
      alive=""
      for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive=yes; done
      [ -z "$alive" ] && break
      sleep 0.1
      waited=$((waited + 1))
    done
    for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
    wait "$SIRVEN_BOOTSTRAP_CHILD" 2>/dev/null || true
  fi
  exit "$1"
}

# sha256_of FILE: print the checksum of FILE. macOS ships shasum, Linux usually ships sha256sum.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "needs shasum or sha256sum to check the download, and neither was found"
  fi
}

# bootstrap_fetch URL DESTINATION: download over https only, with timeouts. a function, so tests can replace it.
bootstrap_fetch() {
  curl -fsSL --proto '=https' --tlsv1.2 --proto-redir '=https' --connect-timeout 20 --max-time 900 \
    -o "$2" "$1"
}

# Everything runs from the pinned release, called on the last line, so a download cut off midway runs nothing.
main() {
  local tool url actual installer archive status=0
  [ "$#" -eq "$SIRVEN_BOOTSTRAP_ARGUMENT_COUNT" ] && [ "$*" = "$SIRVEN_BOOTSTRAP_ARGUMENTS" ] ||
    fail "this script was cut off before its last line; nothing was run"

  for tool in curl tar mktemp; do
    command -v "$tool" >/dev/null 2>&1 || fail "needs $tool, which was not found"
  done

  case "$SIRVEN_PINNED_TAG" in
    '') fail "no release is pinned in this copy of the bootstrap, so nothing was downloaded or run. the maintainer pins one with: bash bootstrap/release.sh TAG" ;;
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "the pinned tag '$SIRVEN_PINNED_TAG' does not look like a release tag such as v0.1.0; nothing was downloaded or run" ;;
  esac
  case "$SIRVEN_PINNED_TAG" in
    *[!A-Za-z0-9.v-]*) fail "the pinned tag '$SIRVEN_PINNED_TAG' has characters a release tag does not use; nothing was downloaded or run" ;;
  esac
  case "$SIRVEN_PINNED_SHA256" in
    '' | *[!0-9a-f]*) fail "the pinned checksum is missing or malformed; nothing was downloaded or run" ;;
  esac
  if [ "${#SIRVEN_PINNED_SHA256}" -ne 64 ]; then
    fail "the pinned checksum must be 64 hexadecimal characters; nothing was downloaded or run"
  fi

  SIRVEN_BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sirven-bootstrap.XXXXXX")"
  trap cleanup EXIT
  trap 'stop_installer 143' TERM HUP
  trap 'stop_installer 130' INT

  archive="sirven-$SIRVEN_PINNED_TAG.tar.gz"
  url="https://github.com/$SIRVEN_REPOSITORY/releases/download/$SIRVEN_PINNED_TAG/$archive"
  echo "sirven bootstrap: downloading release $SIRVEN_PINNED_TAG" >&2
  bootstrap_fetch "$url" "$SIRVEN_BOOTSTRAP_DIR/$archive" || fail "could not download release $SIRVEN_PINNED_TAG from $url; nothing was run"

  # the checksum is checked before the archive is read by anything else: nothing is unpacked from an unverified file.
  actual="$(sha256_of "$SIRVEN_BOOTSTRAP_DIR/$archive")"
  if [ "$actual" != "$SIRVEN_PINNED_SHA256" ]; then
    fail "checksum mismatch for release $SIRVEN_PINNED_TAG: expected $SIRVEN_PINNED_SHA256, downloaded $actual. Nothing was unpacked or run. Do not retry through another path; tell the maintainer."
  fi

  mkdir "$SIRVEN_BOOTSTRAP_DIR/unpacked"
  tar -xzf "$SIRVEN_BOOTSTRAP_DIR/$archive" -C "$SIRVEN_BOOTSTRAP_DIR/unpacked"
  # the archive's one top folder is named after the tag, so it is found rather than guessed.
  installer=""
  for candidate in "$SIRVEN_BOOTSTRAP_DIR"/unpacked/*/install.sh; do
    # an unmatched pattern stays as the literal text, which does not exist, so it is skipped
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then installer="$candidate"; break; fi
  done
  [ -n "$installer" ] && [ -f "$installer" ] || fail "release $SIRVEN_PINNED_TAG does not contain install.sh"

  # Standard input is this piped script, so the installer gets none; it asks its questions on
  # the terminal when there is one, and uses its defaults when there is not. It runs in the
  # background, so a signal to this script reaches stop_installer before the folder is deleted.
  SIRVEN_PACKAGE_TAG="$SIRVEN_PINNED_TAG"
  SIRVEN_PACKAGE_SHA256="$SIRVEN_PINNED_SHA256"
  export SIRVEN_PACKAGE_TAG SIRVEN_PACKAGE_SHA256
  bash "$installer" ${1+"$@"} < /dev/null &
  SIRVEN_BOOTSTRAP_CHILD=$!
  wait "$SIRVEN_BOOTSTRAP_CHILD" || status=$?
  SIRVEN_BOOTSTRAP_CHILD=""
  return "$status"
}

main ${1+"$@"}
