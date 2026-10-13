#!/usr/bin/env bash
# bootstrap/release.sh: pin the bootstrap that cli.sirven.xyz serves to one release tag.
#
#   bash bootstrap/release.sh v0.1.0                  download the tag's tarball and pin its checksum
#   bash bootstrap/release.sh v0.1.0 --tarball FILE   pin from a tarball already on disk
#
# It writes the two pin lines in bootstrap/sirven-bootstrap.sh and changes nothing else. It does
# not create the tag, push it, or deploy the bootstrap: those are separate steps, listed at the end
# of its output. The tag must already be pushed to the repository, because the download comes from
# GitHub's archive of that tag.
#
# runs on macos bash 3.2 and on linux bash.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: run this with bash, for example: bash $0 v0.1.0" >&2
  exit 1
fi

set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_FILE="$BOOTSTRAP_DIR/sirven-bootstrap.sh"
REPOSITORY="Joesirven/sirven"

usage() {
  cat <<END
usage:
  bash bootstrap/release.sh TAG [--tarball FILE]

TAG is a release tag such as v0.1.0. --tarball FILE pins from a tarball already downloaded
(for example from GitHub's archive of TAG) instead of downloading it.
END
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

tag=""
tarball=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball)
      [ "$#" -ge 2 ] || die "--tarball needs a file"
      tarball="$2"
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown option '$1'. run with --help for usage." ;;
    *)
      [ -z "$tag" ] || die "only one tag at a time"
      tag="$1"
      ;;
  esac
  shift
done

[ -n "$tag" ] || { usage >&2; exit 64; }
case "$tag" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) die "'$tag' does not look like a release tag such as v0.1.0" ;;
esac
case "$tag" in
  *[!A-Za-z0-9.v-]*) die "'$tag' has characters a release tag does not use" ;;
esac

if command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else
  die "needs shasum or sha256sum"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/sirven-release.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

if [ -z "$tarball" ]; then
  tarball="$scratch/release.tar.gz"
  url="https://codeload.github.com/$REPOSITORY/tar.gz/refs/tags/$tag"
  printf 'downloading %s\n' "$url"
  if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$tarball" "$url"; then
    die "could not download $tag. push the tag first: git push origin $tag"
  fi
fi
[ -f "$tarball" ] || die "no such file: $tarball"

tar -tzf "$tarball" | grep '/install\.sh$' > /dev/null || die "$tarball does not contain install.sh; it is not a sirven release"

checksum="$(sha256_of "$tarball")"

# rewrite the two pin lines through a scratch file, so the bootstrap keeps its mode and nothing else changes.
pinned="$scratch/sirven-bootstrap.sh"
awk -v tag="$tag" -v sum="$checksum" '
  /^SIRVEN_PINNED_TAG=/ { print "SIRVEN_PINNED_TAG=\"" tag "\""; tags++; next }
  /^SIRVEN_PINNED_SHA256=/ { print "SIRVEN_PINNED_SHA256=\"" sum "\""; sums++; next }
  { print }
  END { if (tags != 1 || sums != 1) exit 3 }
' "$BOOTSTRAP_FILE" > "$pinned" || die "$BOOTSTRAP_FILE does not have exactly one SIRVEN_PINNED_TAG and one SIRVEN_PINNED_SHA256 line"
cat "$pinned" > "$BOOTSTRAP_FILE"

printf 'pinned %s in bootstrap/sirven-bootstrap.sh\n' "$tag"
printf '  sha256: %s\n' "$checksum"
cat <<END

next steps, in order, for the maintainer:
  1. review the change: git diff bootstrap/
  2. commit it on a branch and merge it to main, so the file the Worker serves is in git
  3. copy bootstrap/sirven-bootstrap.sh to the file the Worker serves at cli.sirven.xyz
     (public/install.sh in the sirven-cli Worker project), then deploy that Worker
  4. check the served bytes match: curl -fsSL https://cli.sirven.xyz | cmp - bootstrap/sirven-bootstrap.sh
     and run: curl -fsSL https://cli.sirven.xyz | bash -s -- --dry-run
END
