#!/usr/bin/env bash
# sirven bootstrap, served at https://cli.sirven.xyz
#
# What this does, and nothing else:
#   1. downloads one pinned release of the public sirven repository: the tarball of a git tag
#   2. checks the tarball's checksum (a 256-bit secure hash) against the one pinned below, before anything runs
#   3. unpacks it into a fresh temporary directory, runs its install.sh with the arguments you
#      passed, then deletes the directory
#
# Read it before running:   curl -fsSL https://cli.sirven.xyz
# Preview the plan safely:  curl -fsSL https://cli.sirven.xyz | bash -s -- --dry-run
# Installer options:        curl -fsSL https://cli.sirven.xyz | bash -s -- --help
#
# The two pin lines below are written by bootstrap/release.sh, never by hand. An empty pin means
# no release has been pinned yet, and this file refuses to install anything.

set -euo pipefail

SIRVEN_REPOSITORY="Joesirven/sirven"

# release pin, written by bootstrap/release.sh: the git tag, and the checksum of its tarball (a 256-bit secure hash).
SIRVEN_PINNED_TAG=""
SIRVEN_PINNED_SHA256=""

SIRVEN_BOOTSTRAP_DIR=""

cleanup() {
  if [ -n "$SIRVEN_BOOTSTRAP_DIR" ]; then
    rm -rf "$SIRVEN_BOOTSTRAP_DIR"
  fi
}

fail() {
  echo "sirven bootstrap: $1" >&2
  exit 1
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

# bootstrap_fetch URL DESTINATION: download over https only. a function, so tests can replace it.
bootstrap_fetch() {
  curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
}

# Everything runs from the pinned release, called on the last line, so a download cut off midway runs nothing.
main() {
  local tool url actual installer
  for tool in curl tar mktemp; do
    command -v "$tool" >/dev/null 2>&1 || fail "needs $tool, which was not found"
  done

  case "$SIRVEN_PINNED_TAG" in
    '') fail "no release is pinned in this copy of the bootstrap, so nothing was downloaded or run. the maintainer pins one with: bash bootstrap/release.sh TAG" ;;
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "the pinned tag '$SIRVEN_PINNED_TAG' does not look like a release tag such as v0.1.0; nothing was downloaded or run" ;;
  esac
  case "$SIRVEN_PINNED_SHA256" in
    [0-9a-f]*) ;;
    *) fail "the pinned checksum is missing or malformed; nothing was downloaded or run" ;;
  esac
  if [ "${#SIRVEN_PINNED_SHA256}" -ne 64 ]; then
    fail "the pinned checksum must be 64 hexadecimal characters; nothing was downloaded or run"
  fi

  SIRVEN_BOOTSTRAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sirven-bootstrap.XXXXXX")"
  trap cleanup EXIT

  url="https://codeload.github.com/$SIRVEN_REPOSITORY/tar.gz/refs/tags/$SIRVEN_PINNED_TAG"
  echo "sirven bootstrap: downloading release $SIRVEN_PINNED_TAG" >&2
  bootstrap_fetch "$url" "$SIRVEN_BOOTSTRAP_DIR/release.tar.gz" || fail "could not download release $SIRVEN_PINNED_TAG from $url; nothing was run"

  actual="$(sha256_of "$SIRVEN_BOOTSTRAP_DIR/release.tar.gz")"
  if [ "$actual" != "$SIRVEN_PINNED_SHA256" ]; then
    fail "checksum mismatch for release $SIRVEN_PINNED_TAG: expected $SIRVEN_PINNED_SHA256, downloaded $actual. Nothing was unpacked or run. Do not retry through another path; tell the maintainer."
  fi

  mkdir "$SIRVEN_BOOTSTRAP_DIR/unpacked"
  tar -xzf "$SIRVEN_BOOTSTRAP_DIR/release.tar.gz" -C "$SIRVEN_BOOTSTRAP_DIR/unpacked"
  # the tarball's one top folder is named after the tag, so it is found rather than guessed.
  installer="$(ls "$SIRVEN_BOOTSTRAP_DIR"/unpacked/*/install.sh 2>/dev/null | head -n 1 || true)"
  [ -n "$installer" ] && [ -f "$installer" ] || fail "release $SIRVEN_PINNED_TAG does not contain install.sh"

  # Standard input is this piped script, so the installer gets none; it asks its questions on
  # the terminal when there is one, and uses its defaults when there is not.
  SIRVEN_PACKAGE_TAG="$SIRVEN_PINNED_TAG"
  SIRVEN_PACKAGE_SHA256="$SIRVEN_PINNED_SHA256"
  export SIRVEN_PACKAGE_TAG SIRVEN_PACKAGE_SHA256
  bash "$installer" ${1+"$@"} < /dev/null
}

main ${1+"$@"}
