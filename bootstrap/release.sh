#!/usr/bin/env bash
# bootstrap/release.sh: build the release archive for one tag, and pin the bootstrap to it.
#
#   bash bootstrap/release.sh v0.2.0
#
# It builds dist/release/sirven-TAG.tar.gz with git archive from the tag's commit, builds it a
# second time to check the bytes repeat, writes the two pin lines in bootstrap/sirven-bootstrap.sh,
# and prints the upload command. It uploads nothing, pushes nothing, creates no tag, and deploys
# nothing. The file you upload must be the file this script checksummed, so the pin matches.
#
# runs on macos bash 3.2 and on linux bash.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "error: run this with bash, for example: bash $0 v0.2.0" >&2
  exit 1
fi

set -euo pipefail

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_FILE="$BOOTSTRAP_DIR/sirven-bootstrap.sh"
REPO_ROOT="$(cd "$BOOTSTRAP_DIR/.." && pwd)"
REPOSITORY="Joesirven/sirven"

usage() {
  cat <<END
usage:
  bash bootstrap/release.sh TAG

TAG is a git tag such as v0.2.0 that already exists in this repository. The tag's commit is
archived with git archive, so the archive holds exactly what the tag holds.
END
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 64
fi
case "$1" in
  -h | --help) usage; exit 0 ;;
esac
tag="$1"
case "$tag" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) die "'$tag' does not look like a release tag such as v0.2.0" ;;
esac
case "$tag" in
  *[!A-Za-z0-9.v-]*) die "'$tag' has characters a release tag does not use" ;;
esac

git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null ||
  die "there is no tag $tag in this repository. create it on the merged commit first: git tag -a $tag -m \"sirven $tag\""

if command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else
  die "needs shasum or sha256sum"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/sirven-release.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

asset="sirven-$tag.tar.gz"
git -C "$REPO_ROOT" archive --format=tar.gz --prefix="sirven-$tag/" -o "$scratch/first.tar.gz" "$tag^{commit}"
git -C "$REPO_ROOT" archive --format=tar.gz --prefix="sirven-$tag/" -o "$scratch/second.tar.gz" "$tag^{commit}"
if [ "$(sha256_of "$scratch/first.tar.gz")" != "$(sha256_of "$scratch/second.tar.gz")" ]; then
  die "two builds of $tag gave different bytes; the archive is not reproducible here, so no pin was written"
fi
tar -tzf "$scratch/first.tar.gz" | grep '^[^/]*/install\.sh$' > /dev/null ||
  die "the archive of $tag has no install.sh at its top folder; it is not a sirven release"

mkdir -p "$REPO_ROOT/dist/release"
archive="$REPO_ROOT/dist/release/$asset"
cp "$scratch/first.tar.gz" "$archive"
checksum="$(sha256_of "$archive")"

# rewrite the two pin lines through a scratch file, so the bootstrap keeps its mode and nothing else changes.
pinned="$scratch/sirven-bootstrap.sh"
awk -v tag="$tag" -v sum="$checksum" '
  /^SIRVEN_PINNED_TAG=/ { print "SIRVEN_PINNED_TAG=\"" tag "\""; tags++; next }
  /^SIRVEN_PINNED_SHA256=/ { print "SIRVEN_PINNED_SHA256=\"" sum "\""; sums++; next }
  { print }
  END { if (tags != 1 || sums != 1) exit 3 }
' "$BOOTSTRAP_FILE" > "$pinned" || die "$BOOTSTRAP_FILE does not have exactly one SIRVEN_PINNED_TAG and one SIRVEN_PINNED_SHA256 line"
cat "$pinned" > "$BOOTSTRAP_FILE"

printf 'built %s\n' "dist/release/$asset"
printf 'pinned %s in bootstrap/sirven-bootstrap.sh\n' "$tag"
printf '  sha256: %s\n' "$checksum"
cat <<END

nothing was uploaded. the maintainer does these steps, in order:
  1. review the pin: git diff bootstrap/
  2. push the tag, if it is not pushed yet: git push origin $tag
  3. upload the exact file this script checksummed, as a release asset of $tag:
       gh release create $tag dist/release/$asset --repo $REPOSITORY --verify-tag --title "sirven $tag"
  4. check the uploaded bytes match the pin:
       curl -fsSL -o "\$(mktemp -d)/$asset" https://github.com/$REPOSITORY/releases/download/$tag/$asset
     and compare its shasum -a 256 with $checksum
  5. commit bootstrap/sirven-bootstrap.sh on a branch and merge it to main, then copy it to the file
     the server serves at cli.sirven.xyz and deploy that server
  6. check: curl -fsSL https://cli.sirven.xyz | cmp - bootstrap/sirven-bootstrap.sh
END
