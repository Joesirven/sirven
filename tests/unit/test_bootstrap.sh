# shellcheck shell=bash
# bootstrap: the pinned download, the checksum check before anything is unpacked or run, piped and
# signal behavior, and the release step that builds the archive and writes the pin. no network: a
# fake curl on PATH serves a fixture archive from disk, and the release round trip builds its archive
# from a throwaway git repository.

BOOTSTRAP_SOURCE="$REPO_DIR/bootstrap/sirven-bootstrap.sh"
RELEASE_SOURCE="$REPO_DIR/bootstrap/release.sh"
FIXTURE_ARCHIVE="${TEST_TMP:-}/fixture-release/sirven-v0.2.0.tar.gz"

# bootstrap_sha256 FILE: the checksum the bootstrap computes, with the same tool choice.
bootstrap_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# make_fixture_release: a release archive at $FIXTURE_ARCHIVE, with one top folder and a fake install.sh
# that echoes its arguments and the package tag the bootstrap passed it. with FIXTURE_PIDFILE set, it
# writes its process number there and then sleeps, so a test can stop the bootstrap while it runs.
make_fixture_release() {
  local folder="$TEST_TMP/fixture-release/sirven-v0.2.0"
  mkdir -p "$folder"
  cat > "$folder/install.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "fixture installer: $*"
echo "package tag: ${SIRVEN_PACKAGE_TAG:-unset}"
if [ -n "${FIXTURE_PIDFILE:-}" ]; then
  echo "$$" > "$FIXTURE_PIDFILE"
  exec sleep 30
fi
FIXTURE
  tar -czf "$FIXTURE_ARCHIVE" -C "$TEST_TMP/fixture-release" sirven-v0.2.0
}

# make_fake_tar: a tar that logs each call, then runs the real tar. tests use it to prove tar never reads an unverified archive.
make_fake_tar() {
  local real
  real="$(command -v tar)"
  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/tar" <<FAKE
#!/bin/sh
echo "tar \$*" >> "$TEST_TMP/tar.log"
exec "$real" "\$@"
FAKE
  chmod +x "$TEST_TMP/bin/tar"
  : > "$TEST_TMP/tar.log"
}

# make_fake_curl: a curl that logs its arguments, then copies FAKE_CURL_FIXTURE to the -o file.
make_fake_curl() {
  mkdir -p "$TEST_TMP/bin" "$TEST_TMP/tmp"
  cat > "$TEST_TMP/bin/curl" <<'FAKE'
#!/bin/sh
all="$*"
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
printf 'args: %s\n' "$all" >> "$FAKE_CURL_LOG.args"
[ -z "${FAKE_CURL_FAIL:-}" ] || exit 22
cp "$FAKE_CURL_FIXTURE" "$out"
FAKE
  chmod +x "$TEST_TMP/bin/curl"
  : > "$TEST_TMP/curl.log"
  : > "$TEST_TMP/curl.log.args"
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
    FAKE_CURL_FIXTURE="$FIXTURE_ARCHIVE" TMPDIR="$TEST_TMP/tmp" bash "$file" "$@"
}

# piped_bootstrap FILE ARGUMENT...: the way users run it, the script on standard input and the
# arguments after bash -s --. standard output and standard error go to CAPTURED_*.
piped_bootstrap() {
  local file="$1"
  shift
  capture sh -c 'script=$1; path=$2; log=$3; fixture=$4; tmp=$5; shift 5
    cat "$script" | env PATH="$path" FAKE_CURL_LOG="$log" FAKE_CURL_FIXTURE="$fixture" TMPDIR="$tmp" bash -s -- "$@"' \
    sh "$file" "$TEST_TMP/bin:$PATH" "$TEST_TMP/curl.log" "$FIXTURE_ARCHIVE" "$TEST_TMP/tmp" "$@"
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
  file="$(pinned_bootstrap odd-tag.sh "v0.2.0;x" "$(printf 'a%.0s' $(seq 1 64))")"
  run_bootstrap "$file" --dry-run
  assert_contains "$CAPTURED_STDERR" "characters a release tag does not use"
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
  sum="$(bootstrap_sha256 "$FIXTURE_ARCHIVE")"
  file="$(pinned_bootstrap pinned.sh "v0.2.0" "$sum")"
  run_bootstrap "$file" --dry-run --level observer
  assert_eq 0 "$CAPTURED_STATUS" "a matching checksum runs the installer: $CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDOUT" "fixture installer: --dry-run --level observer"
  assert_contains "$CAPTURED_STDOUT" "package tag: v0.2.0"
  assert_eq "https://github.com/Joesirven/sirven/releases/download/v0.2.0/sirven-v0.2.0.tar.gz" "$(cat "$TEST_TMP/curl.log")" \
    "the download is the release asset of the pinned tag, never main or a generated archive"
}

test_the_download_uses_https_only_with_timeouts() {
  make_fake_curl
  make_fixture_release
  local file sum args
  sum="$(bootstrap_sha256 "$FIXTURE_ARCHIVE")"
  file="$(pinned_bootstrap flags.sh "v0.2.0" "$sum")"
  run_bootstrap "$file" --dry-run
  args="$(cat "$TEST_TMP/curl.log.args")"
  assert_contains "$args" "--proto =https" "the first request must be https only"
  assert_contains "$args" "--tlsv1.2" "the request must refuse old TLS"
  assert_contains "$args" "--proto-redir =https" "a redirect must not leave https"
  assert_contains "$args" "--max-time" "a stalled download must end"
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

test_the_checksum_is_checked_before_the_archive_is_unpacked() {
  make_fake_curl
  make_fake_tar
  mkdir -p "$TEST_TMP/fixture-release"
  printf 'this is not a tar archive\n' > "$FIXTURE_ARCHIVE"
  local file
  file="$(pinned_bootstrap not-a-tar.sh "v0.2.0" "$(printf 'c%.0s' $(seq 1 64))")"
  run_bootstrap "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "checksum mismatch" "a file that is not a tar archive must fail the checksum first"
  assert_eq "" "$(cat "$TEST_TMP/tar.log")" "tar must never run on an archive whose checksum is not verified"
}

test_release_without_install_sh_is_refused() {
  make_fake_curl
  mkdir -p "$TEST_TMP/empty/sirven-v0.2.0" "$TEST_TMP/fixture-release"
  printf 'readme\n' > "$TEST_TMP/empty/sirven-v0.2.0/README.md"
  tar -czf "$FIXTURE_ARCHIVE" -C "$TEST_TMP/empty" sirven-v0.2.0
  local file sum
  sum="$(bootstrap_sha256 "$FIXTURE_ARCHIVE")"
  file="$(pinned_bootstrap no-installer.sh "v0.2.0" "$sum")"
  run_bootstrap "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "does not contain install.sh"
}

test_a_failed_download_runs_nothing() {
  make_fake_curl
  make_fixture_release
  local file sum
  sum="$(bootstrap_sha256 "$FIXTURE_ARCHIVE")"
  file="$(pinned_bootstrap offline.sh "v0.2.0" "$sum")"
  capture env PATH="$TEST_TMP/bin:$PATH" FAKE_CURL_LOG="$TEST_TMP/curl.log" FAKE_CURL_FAIL=1 \
    FAKE_CURL_FIXTURE="$FIXTURE_ARCHIVE" TMPDIR="$TEST_TMP/tmp" bash "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "could not download release v0.2.0"
  assert_eq "" "$CAPTURED_STDOUT"
}

test_the_temporary_folder_is_removed_on_success_and_on_mismatch() {
  make_fake_curl
  make_fixture_release
  local file sum
  mkdir -p "$TEST_TMP/tmp"
  sum="$(bootstrap_sha256 "$FIXTURE_ARCHIVE")"
  file="$(pinned_bootstrap cleanup-ok.sh "v0.2.0" "$sum")"
  run_bootstrap "$file" --dry-run
  assert_eq 0 "$CAPTURED_STATUS"
  assert_eq "" "$(ls -A "$TEST_TMP/tmp")" "success leaves no folder behind"
  file="$(pinned_bootstrap cleanup-bad.sh "v0.2.0" "$(printf 'd%.0s' $(seq 1 64))")"
  run_bootstrap "$file" --dry-run
  assert_eq 1 "$CAPTURED_STATUS"
  assert_eq "" "$(ls -A "$TEST_TMP/tmp")" "a mismatch leaves no folder behind"
}

test_piped_run_passes_the_arguments_to_the_installer() {
  make_fake_curl
  make_fixture_release
  local file sum
  sum="$(bootstrap_sha256 "$FIXTURE_ARCHIVE")"
  file="$(pinned_bootstrap piped.sh "v0.2.0" "$sum")"
  mkdir -p "$TEST_TMP/tmp"
  piped_bootstrap "$file" --dry-run --level builder
  assert_eq 0 "$CAPTURED_STATUS" "piped run failed: $CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDOUT" "fixture installer: --dry-run --level builder"
}

# the last line of the bootstrap is the call to main. a download cut off anywhere in its final 80
# bytes must run nothing, except the one cut that loses only the final newline: that is the whole
# command. a cut that keeps part of the arguments must never run the installer with different ones.
test_a_download_cut_off_in_its_last_line_runs_nothing() {
  make_fake_curl
  make_fixture_release
  local file sum size cut out
  sum="$(bootstrap_sha256 "$FIXTURE_ARCHIVE")"
  file="$(pinned_bootstrap cut.sh "v0.2.0" "$sum")"
  mkdir -p "$TEST_TMP/tmp"
  size="$(wc -c < "$file" | tr -d ' ')"
  cut=$((size - 80))
  while [ "$cut" -le "$size" ]; do
    head -c "$cut" "$file" > "$TEST_TMP/truncated-download.sh"
    out="$(env PATH="$TEST_TMP/bin:$PATH" FAKE_CURL_LOG="$TEST_TMP/curl.log" FAKE_CURL_FIXTURE="$FIXTURE_ARCHIVE" \
      TMPDIR="$TEST_TMP/tmp" bash -s -- --dry-run < "$TEST_TMP/truncated-download.sh" 2>/dev/null)" || true
    if [ "$cut" -ge $((size - 1)) ]; then
      assert_contains "$out" "fixture installer: --dry-run" "a complete command (cut at $cut of $size) runs with its arguments"
    else
      assert_not_contains "$out" "fixture installer" "a download cut at byte $cut of $size ran the installer"
    fi
    cut=$((cut + 1))
  done
}

# stopping the bootstrap stops the installer it started, before the folder the installer runs from is deleted.
test_stopping_the_bootstrap_stops_its_installer_and_removes_the_folder() {
  make_fake_curl
  make_fixture_release
  local file sum pid_file installer_pid status=0 waited=0
  sum="$(bootstrap_sha256 "$FIXTURE_ARCHIVE")"
  file="$(pinned_bootstrap signal.sh "v0.2.0" "$sum")"
  mkdir -p "$TEST_TMP/tmp"
  pid_file="$TEST_TMP/installer.pid"
  env PATH="$TEST_TMP/bin:$PATH" FAKE_CURL_LOG="$TEST_TMP/curl.log" FAKE_CURL_FIXTURE="$FIXTURE_ARCHIVE" \
    TMPDIR="$TEST_TMP/tmp" FIXTURE_PIDFILE="$pid_file" bash "$file" --dry-run < /dev/null > "$TEST_TMP/signal.out" 2>&1 &
  local boot=$!
  while [ ! -s "$pid_file" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_file_exists "$pid_file"
  installer_pid="$(cat "$pid_file")"
  kill -TERM "$boot"
  wait "$boot" 2>/dev/null || status=$?
  assert_eq 143 "$status" "a terminated bootstrap exits as terminated"
  if kill -0 "$installer_pid" 2>/dev/null; then
    fail "the installer $installer_pid is still running after the bootstrap was stopped"
  fi
  assert_eq "" "$(ls -A "$TEST_TMP/tmp")" "the folder is removed once the installer is stopped"
}

# the release step, run on a throwaway repository with a tag and an install.sh. the archive it builds
# is the one the pinned bootstrap accepts and runs.
make_release_repository() {
  local repo="$TEST_TMP/repo"
  mkdir -p "$repo/bootstrap"
  cp "$RELEASE_SOURCE" "$repo/bootstrap/release.sh"
  cp "$BOOTSTRAP_SOURCE" "$repo/bootstrap/sirven-bootstrap.sh"
  printf '#!/usr/bin/env bash\necho "fixture installer: $*"\necho "package tag: ${SIRVEN_PACKAGE_TAG:-unset}"\n' > "$repo/install.sh"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -q -m "release fixture"
  git -C "$repo" tag v0.2.0
}

test_release_builds_the_archive_pins_its_checksum_and_the_bootstrap_runs_it() {
  make_fake_curl
  make_release_repository
  local repo="$TEST_TMP/repo" archive sum
  capture bash "$repo/bootstrap/release.sh" v0.2.0
  assert_eq 0 "$CAPTURED_STATUS" "release builds the tag: $CAPTURED_STDERR"
  archive="$repo/dist/release/sirven-v0.2.0.tar.gz"
  assert_file_exists "$archive"
  sum="$(bootstrap_sha256 "$archive")"
  assert_contains "$(cat "$repo/bootstrap/sirven-bootstrap.sh")" "SIRVEN_PINNED_SHA256=\"$sum\""
  assert_contains "$(cat "$repo/bootstrap/sirven-bootstrap.sh")" "SIRVEN_PINNED_TAG=\"v0.2.0\""
  assert_contains "$CAPTURED_STDOUT" "nothing was uploaded"
  assert_contains "$CAPTURED_STDOUT" "gh release create v0.2.0 dist/release/sirven-v0.2.0.tar.gz"
  FIXTURE_ARCHIVE="$archive"
  capture env PATH="$TEST_TMP/bin:$PATH" FAKE_CURL_LOG="$TEST_TMP/curl.log" FAKE_CURL_FIXTURE="$archive" \
    TMPDIR="$TEST_TMP/tmp" bash "$repo/bootstrap/sirven-bootstrap.sh" --dry-run
  assert_eq 0 "$CAPTURED_STATUS" "the pinned bootstrap accepts the archive release built: $CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDOUT" "fixture installer: --dry-run"
}

test_release_refuses_a_tag_that_does_not_exist_and_what_is_not_a_tag() {
  make_release_repository
  local repo="$TEST_TMP/repo"
  capture bash "$repo/bootstrap/release.sh" v9.9.9
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "there is no tag v9.9.9"
  assert_no_file "$repo/dist/release/sirven-v9.9.9.tar.gz"
  assert_status 1 bash "$repo/bootstrap/release.sh" main
  assert_status 1 bash "$repo/bootstrap/release.sh" "v0.2.0;rm"
  assert_status 64 bash "$repo/bootstrap/release.sh"
}

test_release_refuses_the_removed_tarball_option() {
  make_release_repository
  local repo="$TEST_TMP/repo"
  assert_status 64 bash "$repo/bootstrap/release.sh" v0.2.0 --tarball /tmp/anything.tar.gz
}

# the repository name and the asset name are written in both files; this fails if one moves alone.
test_the_bootstrap_and_the_release_step_agree_on_the_repository_and_the_asset() {
  local repository asset
  repository="$(sed -n 's/^SIRVEN_REPOSITORY="\(.*\)"$/\1/p' "$BOOTSTRAP_SOURCE")"
  assert_eq "Joesirven/sirven" "$repository"
  assert_contains "$(cat "$RELEASE_SOURCE")" "REPOSITORY=\"$repository\""
  asset='archive="sirven-$SIRVEN_PINNED_TAG.tar.gz"'
  assert_contains "$(cat "$BOOTSTRAP_SOURCE")" "$asset"
  assert_contains "$(cat "$RELEASE_SOURCE")" 'asset="sirven-$tag.tar.gz"'
}
