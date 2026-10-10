# shellcheck shell=bash
# tiny assertion helpers. each test runs in its own subshell, so a failed assertion just exits.

fail() {
  printf '    assertion failed: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="${3:-values differ}"
  if [ "$expected" != "$actual" ]; then
    fail "$message
      expected: $expected
      actual:   $actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" message="${3:-text is missing}"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$message: expected to find '$needle' in:
$haystack" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" message="${3:-unexpected text}"
  case "$haystack" in
    *"$needle"*) fail "$message: did not expect '$needle' in:
$haystack" ;;
  esac
}

assert_file_exists() {
  [ -e "$1" ] || fail "expected $1 to exist"
}

assert_no_file() {
  [ ! -e "$1" ] || fail "expected $1 not to exist"
}

# capture COMMAND...: run it in a subshell and keep its status, standard output, and standard
# error in CAPTURED_STATUS, CAPTURED_STDOUT, and CAPTURED_STDERR. the subshell means a command
# that calls die, or changes variables, cannot end or disturb the test itself.
capture() {
  local out="$TEST_TMP/.captured-out" err="$TEST_TMP/.captured-err"
  CAPTURED_STATUS=0
  ( "$@" ) > "$out" 2> "$err" || CAPTURED_STATUS=$?
  CAPTURED_STDOUT="$(cat "$out")"
  CAPTURED_STDERR="$(cat "$err")"
}

assert_status() {
  local expected="$1"
  shift
  capture "$@"
  if [ "$CAPTURED_STATUS" != "$expected" ]; then
    fail "expected status $expected, got $CAPTURED_STATUS from: $*
--- standard output
$CAPTURED_STDOUT
--- standard error
$CAPTURED_STDERR"
  fi
}
