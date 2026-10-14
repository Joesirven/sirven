#!/usr/bin/env bash
# run every test: the unit tests in tests/unit, then the golden files in tests/golden.
#
# each test_* function in tests/unit/test_*.sh runs in its own subshell with a fresh
# TEST_TMP directory. pass a word to run only test files whose name contains it, or
# golden for only the golden files:
#   tests/run.sh preflight

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FILTER="${1:-}"
export REPO_DIR TESTS_DIR
# the setup questions must never wait on whoever runs the tests: tests get no terminal on
# standard input and none of the caller's answers.
unset SIRVEN_LEVEL SIRVEN_PATH SIRVEN_YES SIRVEN_INTERACTIVE
# nor the Tailscale and bb of the machine running them: the adopt tests point these at fakes.
SIRVEN_TAILSCALE=none
SIRVEN_BB=none
export SIRVEN_TAILSCALE SIRVEN_BB

passed=0
failed=0
failed_names=""

run_test() {
  local file="$1" name="$2" log status
  # /tmp, not TMPDIR: on macOS TMPDIR sits under /var, which the grant policy refuses as a folder
  # to grant, so a test that grants its own project folder would get no default path there.
  TEST_TMP="$(mktemp -d /tmp/sirven-test.XXXXXX)"
  log="$TEST_TMP/.log"
  (
    export TEST_TMP
    # shellcheck source=tests/lib/assert.sh
    . "$TESTS_DIR/lib/assert.sh"
    # shellcheck disable=SC1090
    . "$file"
    "$name"
  ) < /dev/null > "$log" 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    printf 'ok      %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'not ok  %s\n' "$name"
    sed 's/^/        /' "$log"
    failed=$((failed + 1))
    failed_names="$failed_names $name"
  fi
  rm -rf "$TEST_TMP"
}

for file in "$TESTS_DIR"/unit/test_*.sh; do
  case "$file" in *"$FILTER"*) ;; *) continue ;; esac
  printf '\n# %s\n' "${file#"$REPO_DIR"/}"
  names="$(
    # shellcheck disable=SC1090,SC1091
    . "$TESTS_DIR/lib/assert.sh" && . "$file" && declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p'
  )"
  for name in $names; do
    run_test "$file" "$name"
  done
done

if [ -z "$FILTER" ] || [ "$FILTER" = golden ]; then
  printf '\n# tests/golden\n'
  golden_output="$(bash "$TESTS_DIR/golden/run.sh" < /dev/null 2>&1)"
  printf '%s\n' "$golden_output"
  golden_passed="$(printf '%s\n' "$golden_output" | grep -c '^ok ' || true)"
  golden_failed="$(printf '%s\n' "$golden_output" | grep -c '^not ok ' || true)"
  passed=$((passed + golden_passed))
  failed=$((failed + golden_failed))
  if [ "$golden_failed" -gt 0 ]; then
    failed_names="$failed_names golden"
  fi
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
  printf 'failed:%s\n' "$failed_names"
  exit 1
fi
