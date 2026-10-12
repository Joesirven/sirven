# shellcheck shell=bash
# the Solo egress runtime in lib/sirven_runtime. its tests are python, in tests/runtime; they
# start sites on 127.0.0.1 and never touch the real network. the helper tests run when
# make runtime has built the fetch helper. live tests: SIRVEN_LIVE_TESTS=1 tests/run.sh runtime

test_runtime_python_suite() {
  command -v python3 >/dev/null 2>&1 || return 0
  assert_status 0 python3 -m unittest discover -s "$REPO_DIR/tests/runtime"
}

test_the_interface_document_names_every_endpoint_the_runtime_serves() {
  local doc endpoints endpoint
  doc="$(cat "$REPO_DIR/docs/runtime-interface.md")"
  endpoints="$(sed -n -E 's/.*\("(GET|PUT|POST)", "(\/v1\/[a-z]+)"\).*/\1 \2/p' "$REPO_DIR/lib/sirven_runtime/server.py")"
  assert_eq 6 "$(printf '%s\n' "$endpoints" | grep -c .)" "endpoints found in server.py"
  while IFS= read -r endpoint; do
    assert_contains "$doc" "$endpoint" "docs/runtime-interface.md is missing an endpoint"
  done <<END
$endpoints
END
}
