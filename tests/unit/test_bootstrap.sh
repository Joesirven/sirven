# shellcheck shell=bash
# bootstrap: the pinned download, the checksum check before anything runs, and the release step
# that writes the pin. no network: a fake curl on PATH serves a fixture tarball from disk.

BOOTSTRAP_SOURCE="$REPO_DIR/bootstrap/sirven-bootstrap.sh"
RELEASE_SOURCE="$REPO_DIR/bootstrap/release.sh"

# bootstrap_sha256 FILE: the checksum the bootstrap computes, with the same tool choice.
bootstrap_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# make_fixture_release: a release tarball at $TEST_TMP/fixture-release/release.tar.gz, with one top
# folder and a fake install.sh that echoes its arguments and the package tag the bootstrap passed it.
make_fixture_release() {
  local folder="$TEST_TMP/fixture-release/sirven-0.2.0"
  mkdir -p "$folder"
  printf '#!/usr/bin/env bash\necho "fixture installer: $*"\necho "package tag: ${SIRVEN_PACKAGE_TAG:-unset}"\n' > "$folder/install.sh"
  tar -czf "$TEST_TMP/fixture-release/release.tar.gz" -C "$TEST_TMP/fixture-release" sirven-0.2.0
}

# make_fake_curl: a curl that logs the URL it was asked for, then copies FAKE_CURL_FIXTURE to the -o file.
make_fake_curl() {
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/curl" <<'FAKE'
#!/bin/sh
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    --proto) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
[ -z "${FAKE_CURL_FAIL:-}" ] || exit 22
cp "$FAKE_CURL_FIXTURE" "$out"
FAKE
  chmod +x "$TEST_TMP/bin/curl"
  : > "$TEST_TMP/curl.log"
}

# pinned_bootstrap NAME TAG CHECKSUM: a copy of the bootstrap with its pin lines replaced.
pinned_bootstrap() {
  local file="$TEST_TMP/$1"
  sed -e "s|^SIRVEN_PINNED_TAG=.*|SIRVEN_PINNED_TAG=\"$2\"|" \
    -e "s|^SIRVEN_PINNED_SHA256=.*|SIRVEN_PINNED_SHA256=\"$3\"|" "$BOOTSTRAP_SOURCE" > "$file"
  printf '%s' "$file"
}

# run_bootstrap FILE ARGUMENT...: run a bootstrap with the fake curl, its download log, and the fixture.
run_bootstrap() {
  local file="$1"
  shift
  capture env PATH="$TEST_TMP/bin:$PATH" FAKE_CURL_LOG="$TEST_TMP/curl.log" \
    FAKE_CURL_FIXTURE="$TEST_TMP/fixture-release/release.tar.gz" bash "$file" "$@"
}

test_unpinned_bootstrap_downloads_and_runs_nothing() {
  make_fake_curl
  local file
  file="$(pinned_bootstrap unpinned.sh "" "")"
  run_bootstrap "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "no release is pinned"
  assert_eq "" "$(cat "$TEST_TMP/curl.log")" "nothing is downloaded without a pin"
  assert_eq "" "$CAPTURED_STDOUT"
}

test_malformed_pins_are_refused_before_download() {
  make_fake_curl
  local file
  file="$(pinned_bootstrap bad-tag.sh "main" "$(printf 'a%.0s' $(seq 1 64))")"
  run_bootstrap "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "does not look like a release tag"
  file="$(pinned_bootstrap short-sum.sh "v0.2.0" "abc123")"
  run_bootstrap "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "must be 64 hexadecimal characters"
  assert_eq "" "$(cat "$TEST_TMP/curl.log")" "a malformed pin downloads nothing"
}

test_matching_checksum_runs_the_pinned_installer() {
  make_fake_curl
  make_fixture_release
  local file sum
  sum="$(bootstrap_sha256 "$TEST_TMP/fixture-release/release.tar.gz")"
  file="$(pinned_bootstrap pinned.sh "v0.2.0" "$sum")"
  run_bootstrap "$file" --dry-run --level observer
  assert_eq 0 "$CAPTURED_STATUS" "a matching checksum runs the installer: $CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDOUT" "fixture installer: --dry-run --level observer"
  assert_contains "$CAPTURED_STDOUT" "package tag: v0.2.0"
  assert_eq "https://codeload.github.com/Joesirven/sirven/tar.gz/refs/tags/v0.2.0" "$(cat "$TEST_TMP/curl.log")" \
    "the download is the pinned tag, never main"
}

test_mismatched_checksum_runs_nothing() {
  make_fake_curl
  make_fixture_release
  local file
  file="$(pinned_bootstrap mismatch.sh "v0.2.0" "$(printf 'b%.0s' $(seq 1 64))")"
  run_bootstrap "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "checksum mismatch for release v0.2.0"
  assert_contains "$CAPTURED_STDERR" "Nothing was unpacked or run"
  assert_eq "" "$CAPTURED_STDOUT" "the installer never ran"
}

test_release_without_install_sh_is_refused() {
  make_fake_curl
  mkdir -p "$TEST_TMP/empty/sirven-0.2.0" "$TEST_TMP/fixture-release"
  printf 'readme\n' > "$TEST_TMP/empty/sirven-0.2.0/README.md"
  tar -czf "$TEST_TMP/fixture-release/release.tar.gz" -C "$TEST_TMP/empty" sirven-0.2.0
  local file sum
  sum="$(bootstrap_sha256 "$TEST_TMP/fixture-release/release.tar.gz")"
  file="$(pinned_bootstrap no-installer.sh "v0.2.0" "$sum")"
  run_bootstrap "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "does not contain install.sh"
}

test_a_failed_download_runs_nothing() {
  make_fake_curl
  make_fixture_release
  local file sum
  sum="$(bootstrap_sha256 "$TEST_TMP/fixture-release/release.tar.gz")"
  file="$(pinned_bootstrap offline.sh "v0.2.0" "$sum")"
  capture env PATH="$TEST_TMP/bin:$PATH" FAKE_CURL_LOG="$TEST_TMP/curl.log" FAKE_CURL_FAIL=1 \
    FAKE_CURL_FIXTURE="$TEST_TMP/fixture-release/release.tar.gz" bash "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "could not download release v0.2.0"
  assert_eq "" "$CAPTURED_STDOUT"
}

test_release_step_pins_the_tag_and_checksum_and_nothing_else() {
  make_fixture_release
  mkdir -p "$TEST_TMP/bootstrap"
  cp "$RELEASE_SOURCE" "$TEST_TMP/bootstrap/release.sh"
  cp "$BOOTSTRAP_SOURCE" "$TEST_TMP/bootstrap/sirven-bootstrap.sh"
  chmod +x "$TEST_TMP/bootstrap/sirven-bootstrap.sh"
  cp "$TEST_TMP/bootstrap/sirven-bootstrap.sh" "$TEST_TMP/original.sh"
  capture bash "$TEST_TMP/bootstrap/release.sh" v0.2.0 --tarball "$TEST_TMP/fixture-release/release.tar.gz"
  assert_eq 0 "$CAPTURED_STATUS" "release pins from a tarball: $CAPTURED_STDERR"
  local sum
  sum="$(bootstrap_sha256 "$TEST_TMP/fixture-release/release.tar.gz")"
  assert_contains "$CAPTURED_STDOUT" "pinned v0.2.0"
  assert_contains "$(cat "$TEST_TMP/bootstrap/sirven-bootstrap.sh")" "SIRVEN_PINNED_TAG=\"v0.2.0\""
  assert_contains "$(cat "$TEST_TMP/bootstrap/sirven-bootstrap.sh")" "SIRVEN_PINNED_SHA256=\"$sum\""
  diff "$TEST_TMP/original.sh" "$TEST_TMP/bootstrap/sirven-bootstrap.sh" > "$TEST_TMP/change.diff" || true
  assert_eq 4 "$(grep -c '^[<>]' "$TEST_TMP/change.diff")" "exactly the two pin lines change"
  assert_eq 2 "$(grep -c '^[<>] SIRVEN_PINNED_TAG=' "$TEST_TMP/change.diff" || true)" "the tag line is the one change, shown as old and new"
  if [ ! -x "$TEST_TMP/bootstrap/sirven-bootstrap.sh" ]; then fail "the bootstrap keeps its executable mode"; fi
}

test_release_refuses_what_is_not_a_release_tag() {
  mkdir -p "$TEST_TMP/bootstrap"
  cp "$RELEASE_SOURCE" "$TEST_TMP/bootstrap/release.sh"
  cp "$BOOTSTRAP_SOURCE" "$TEST_TMP/bootstrap/sirven-bootstrap.sh"
  assert_status 1 bash "$TEST_TMP/bootstrap/release.sh" main
  assert_status 1 bash "$TEST_TMP/bootstrap/release.sh" "v0.2.0;rm"
  assert_status 64 bash "$TEST_TMP/bootstrap/release.sh"
}
