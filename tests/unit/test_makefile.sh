# shellcheck shell=bash
# the Makefile targets. make test is checked with make -n, since running it here would recurse.

have_make() {
  command -v make >/dev/null 2>&1
}

test_make_test_runs_the_test_runner() {
  have_make || return 0
  assert_status 0 make -s -C "$REPO_DIR" -n test
  assert_contains "$CAPTURED_STDOUT" "bash tests/run.sh"
}

# lint needs shellcheck: without it lint fails, unless SIRVEN_SKIP_SHELLCHECK=1 is set, which
# passes and says loudly that shellcheck was skipped. the scratch PATH holds only make and bash,
# so this does not depend on where shellcheck is installed on this machine.
test_make_lint_needs_shellcheck_unless_it_is_skipped() {
  local tools="$TEST_TMP/lint-tools"
  have_make || return 0
  mkdir -p "$tools"
  ln -s "$(command -v make)" "$tools/make"
  ln -s "$(command -v bash)" "$tools/bash"
  assert_status 2 env PATH="$tools" SIRVEN_SKIP_SHELLCHECK= make -s -C "$REPO_DIR" lint
  assert_contains "$CAPTURED_STDERR" "shellcheck is not installed, so lint cannot pass"
  assert_status 0 env PATH="$tools" SIRVEN_SKIP_SHELLCHECK=1 make -s -C "$REPO_DIR" lint
  assert_contains "$CAPTURED_STDOUT" "lint: bash -n found no syntax errors"
  assert_contains "$CAPTURED_STDERR" "WARNING: shellcheck is not installed and SIRVEN_SKIP_SHELLCHECK=1 is set"
}

test_make_lint_runs_the_installed_shellcheck() {
  have_make || return 0
  command -v shellcheck >/dev/null 2>&1 || return 0
  assert_status 0 make -s -C "$REPO_DIR" lint
  assert_contains "$CAPTURED_STDOUT" "lint: shellcheck passed"
}

test_make_package_ships_tracked_files_only() {
  local tarball listing
  have_make || return 0
  command -v git >/dev/null 2>&1 && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 || return 0
  assert_status 0 make -s -C "$REPO_DIR" package DIST="$TEST_TMP/dist"
  tarball="$(ls "$TEST_TMP"/dist/sirven-*.tar.gz)"
  listing="$(tar -tzf "$tarball")"
  assert_contains "$listing" "/install.sh"
  assert_contains "$listing" "/uninstall.sh"
  assert_contains "$listing" "/bin/sirven"
  assert_contains "$listing" "/levels/observer.json"
  assert_not_contains "$listing" "/.git/"
  assert_not_contains "$listing" "node_modules"
  assert_not_contains "$listing" ".claude"
  assert_not_contains "$listing" "/recordings/"
  assert_eq 1 "$(printf '%s\n' "$listing" | cut -d/ -f1 | sort -u | grep -c .)" "one top folder"
}

# one package (Jose's ruling): the npm files list carries every product folder the wired
# product runs from, so an npm install is not missing the tier dial or the ride connector.
test_the_npm_package_carries_every_product_folder() {
  local folder
  for folder in bin lib app copy connectors levels; do
    assert_contains "$(cat "$REPO_DIR/package.json")" "\"$folder\"" "package.json files is missing $folder"
  done
}
