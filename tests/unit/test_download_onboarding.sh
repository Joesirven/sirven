# shellcheck shell=bash
# the consumer install path: the app build pipeline's credential seam, the onboarding
# wizard's shape, and the download page. none of these build anything; the pipeline is
# checked through --dry-run, the wizard through its copy file and step list, and the page
# through its markup. the wizard's behavior has its own Swift tests: make app-test.

BUILD="$REPO_DIR/app/macos/build.sh"
WIZARD_COPY="$REPO_DIR/copy/onboarding-wizard.json"
PAGE="$REPO_DIR/site/download"

# run_build STATUS [build options]: a dry run with neither credential set.
run_build() {
  assert_status "$1" env -u SIRVEN_SIGNING_IDENTITY -u SIRVEN_NOTARY_PROFILE bash "$BUILD" "${@:2}" --out "$TEST_TMP/out" --dry-run
}

test_release_build_without_credentials_fails_before_building() {
  run_build 2 --release
  assert_contains "$CAPTURED_STDERR" "SIRVEN_SIGNING_IDENTITY"
  assert_contains "$CAPTURED_STDERR" "SIRVEN_NOTARY_PROFILE"
  assert_contains "$CAPTURED_STDERR" "docs/DOWNLOAD-AND-ONBOARDING.md"
  assert_not_contains "$CAPTURED_STDOUT" "swift build"
  assert_no_file "$TEST_TMP/out"
}

test_release_build_names_the_one_missing_credential() {
  assert_status 2 env -u SIRVEN_NOTARY_PROFILE SIRVEN_SIGNING_IDENTITY="Example Distribution Certificate (ABCDE12345)" \
    bash "$BUILD" --release --dry-run --out "$TEST_TMP/out"
  assert_contains "$CAPTURED_STDERR" "not set: SIRVEN_NOTARY_PROFILE"
  assert_not_contains "$CAPTURED_STDERR" "not set: SIRVEN_SIGNING_IDENTITY"
}

test_release_dry_run_plans_hardened_signing_and_notarization() {
  assert_status 0 env SIRVEN_SIGNING_IDENTITY="Example Distribution Certificate (ABCDE12345)" SIRVEN_NOTARY_PROFILE=example-profile \
    bash "$BUILD" --release --dry-run --out "$TEST_TMP/out"
  assert_contains "$CAPTURED_STDOUT" "--arch arm64 --arch x86_64"
  assert_contains "$CAPTURED_STDOUT" "--options runtime --timestamp"
  assert_contains "$CAPTURED_STDOUT" "Example\\ Distribution\\ Certificate"
  assert_contains "$CAPTURED_STDOUT" "notarytool submit"
  assert_contains "$CAPTURED_STDOUT" "--keychain-profile example-profile"
  assert_contains "$CAPTURED_STDOUT" "stapler staple"
  assert_contains "$CAPTURED_STDOUT" "signing developer-id, notarized true"
  assert_contains "$CAPTURED_STDOUT" "dry run: nothing was built"
  assert_no_file "$TEST_TMP/out"
}

test_local_dry_run_is_ad_hoc_and_needs_no_credentials() {
  run_build 0
  assert_contains "$CAPTURED_STDOUT" "local build"
  assert_contains "$CAPTURED_STDOUT" "codesign --force --sign -"
  assert_contains "$CAPTURED_STDOUT" "signing ad-hoc, notarized false"
  assert_not_contains "$CAPTURED_STDOUT" "notarytool"
  assert_no_file "$TEST_TMP/out"
}

test_build_rejects_unknown_options() {
  assert_status 1 bash "$BUILD" --sign-with-anything
  assert_contains "$CAPTURED_STDERR" "unknown option"
}

# Jose's bar: connecting a personal agent is two or three steps plus a confirmation.
test_wizard_is_three_steps_plus_a_confirmation() {
  local steps
  steps="$(sed -n 's/^  case \(welcome, .*confirmation\)$/\1/p' "$REPO_DIR/app/macos/Sources/SirvenOnboarding/OnboardingModel.swift")"
  assert_eq "welcome, tier, permissions, confirmation" "$steps" "the wizard's step list changed"
}

test_wizard_copy_matches_the_steps_and_keeps_peer_tiers_closed() {
  command -v python3 >/dev/null 2>&1 || return 0
  assert_status 0 python3 - "$WIZARD_COPY" <<'PYTHON'
import json, sys
copy = json.load(open(sys.argv[1]))
assert [k for k in copy if not k.startswith("_")] == ["welcome", "tier", "permissions", "confirmation", "navigation"], list(copy)
options = {o["id"]: o for o in copy["tier"]["options"]}
assert list(options) == ["solo", "neighborly", "coop"], list(options)
# ship gate: no peer routing of authenticated traffic until attestation and the site
# allowlist review workflow both work end to end.
assert options["solo"]["available"] is True
assert options["neighborly"]["available"] is False and options["coop"]["available"] is False
assert all(o["unavailableNote"] for o in options.values() if not o["available"])
assert "5 gigabytes" in options["neighborly"]["lends"]
assert [p["id"] for p in copy["permissions"]["items"]] == ["notifications", "openAtLogin"]
PYTHON
}

test_download_page_has_exactly_one_download_button() {
  assert_eq 1 "$(grep -c 'data-download ' "$PAGE/index.html")" "one obvious button"
}

test_download_page_never_starts_a_download_by_itself() {
  assert_not_contains "$(cat "$PAGE/index.html")" 'http-equiv="refresh"'
  assert_not_contains "$(cat "$PAGE/download.js")" "location.href"
  assert_not_contains "$(cat "$PAGE/download.js")" ".click()"
  assert_not_contains "$(cat "$PAGE/download.js")" "window.open"
}

test_download_page_loads_nothing_from_other_sites() {
  local hits
  hits="$(grep -n -E '<(script|link|img|iframe)[^>]*(src|href)="(https?:)?//' "$PAGE/index.html" || true)"
  assert_eq "" "$hits" "no third-party scripts, styles, images, or trackers"
}

test_download_page_states_requirements_and_signing_honestly() {
  local page script
  page="$(cat "$PAGE/index.html")"
  script="$(cat "$PAGE/download.js")"
  assert_contains "$page" "System requirements"
  assert_contains "$page" "data-requirement-macos"
  assert_contains "$page" "data-requirement-processor"
  assert_contains "$script" "not notarized"
  assert_contains "$script" "not available right now"
}

test_sample_manifest_has_every_field_the_build_writes() {
  local written sample
  written="$(sed -n '/^cat > "\$MANIFEST_PATH" <<JSON$/,/^JSON$/p' "$BUILD" | sed -n 's/^  "\([A-Za-z0-9]*\)":.*/\1/p' | sort | tr '\n' ' ')"
  sample="$(sed -n 's/^  "\([A-Za-z0-9]*\)":.*/\1/p' "$PAGE/release.json" | sort | tr '\n' ' ')"
  assert_contains "$written" "sha256"
  assert_eq "$written" "$sample" "site/download/release.json drifted from what build.sh writes"
}
