# shellcheck shell=bash
# the per-booking card flow in lib/issuing, against the in-memory stand-in for Stripe test mode.
# the cases live in tests/issuing/test_issuing.py; this runs them inside tests/run.sh.

test_issuing_python_suite() {
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$REPO_DIR/tests/issuing" -p 'test_*.py' 2>&1 \
    || fail "lib/issuing unit tests failed"
}
