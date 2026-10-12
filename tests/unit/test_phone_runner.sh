# shellcheck shell=bash
# the phone runner: sirven phone start supervises the tunnel and the launcher. the python unit
# tests in tests/phone/test_phone_runner.py run small fake processes in place of pymobiledevice3,
# so no phone, no network, and no real tunnel are needed.

test_phone_runner_unit_tests_pass() {
  assert_status 0 python3 -B -m unittest discover -s "$REPO_DIR/tests/phone" -p test_phone_runner.py
}
