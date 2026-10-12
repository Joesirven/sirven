# shellcheck shell=bash
# allowlist review workflow: intake, votes, the registry, and publishing. every test works on
# a copy of the policy in TEST_TMP, never on the committed allowlist folder, except the checks
# that read the committed registry.

review() {
  python3 "$REPO_DIR/lib/allowlist_review.py" --root "$TEST_TMP/allowlist" "$@"
}

committed() {
  python3 "$REPO_DIR/lib/allowlist_review.py" "$@"
}

json_value() {
  python3 -c 'import json, sys; print(eval("data" + sys.argv[2], {"data": json.load(open(sys.argv[1]))}))' "$@"
}

# sha256 check of a published file: shasum on macos, sha256sum on minimal linux.
check_sha256() {
  if command -v shasum > /dev/null 2>&1; then shasum -a 256 -c "$1"; else sha256sum -c "$1"; fi
}

setup_root() {
  mkdir -p "$TEST_TMP/allowlist"
  cat > "$TEST_TMP/allowlist/policy.json" <<'END'
{"created": "2026-10-01", "reviewers": ["Jose Sirven"], "quorum": 1, "notice_days": 7, "max_additions_per_version": 2}
END
}

# file a request for $1 on 2026-10-01, prepare it, and fill every rubric answer.
prepared_decision() {
  local domain="$1"
  review request --domain "$domain" --requested-by sirven_user --case "a user books for themself" --date 2026-10-01 > /dev/null
  review prepare "2026-10-01-$domain-1" --prepared-by "the preparer" --date 2026-10-02 > /dev/null
  python3 - "$TEST_TMP/allowlist/decisions/2026-10-02-$domain-1.json" <<'END'
import json, sys
record = json.load(open(sys.argv[1]))
for answer in record["rubric"].values():
    answer.update(rating="pass", finding="checked")
record["recommendation"] = {"decision": "approve", "scope": ["public_pages"], "rationale": "fine"}
json.dump(record, open(sys.argv[1], "w"), indent=2)
END
}

test_the_committed_registry_approves_nothing() {
  local registry="$REPO_DIR/allowlist/registry.json"
  assert_eq 0 "$(json_value "$registry" '["approved"].__len__()')" "nothing is allowlisted until Jose approves it"
}

test_the_committed_allowlist_validates_and_is_current() {
  assert_status 0 committed validate
  assert_status 0 committed build --check
}

test_the_committed_policy_names_jose_as_the_only_reviewer() {
  assert_eq "['Jose Sirven']" "$(json_value "$REPO_DIR/allowlist/policy.json" '["reviewers"]')"
  assert_eq 1 "$(json_value "$REPO_DIR/allowlist/policy.json" '["quorum"]')"
}

test_domains_are_normalized_and_bare() {
  setup_root
  capture review request --domain "WayMo.COM." --requested-by sirven --case "x" --date 2026-10-01
  assert_eq 0 "$CAPTURED_STATUS"
  assert_eq "2026-10-01-waymo.com-1" "$CAPTURED_STDOUT"
  assert_eq waymo.com "$(json_value "$TEST_TMP/allowlist/requests/2026-10-01-waymo.com-1.json" '["domain"]')"
  for bad in "https://waymo.com" "waymo.com:443" "*.waymo.com" "waymo.com/rides" "localhost"; do
    capture review request --domain "$bad" --requested-by sirven --case "x" --date 2026-10-01
    assert_eq 1 "$CAPTURED_STATUS" "should refuse $bad"
  done
}

test_a_leading_www_label_is_dropped() {
  setup_root
  capture review request --domain www.zillow.com --requested-by sirven --case "x" --date 2026-10-01
  assert_eq "2026-10-01-zillow.com-1" "$CAPTURED_STDOUT"
  capture review request --domain www.example --requested-by sirven --case "x" --date 2026-10-01
  assert_eq "2026-10-01-www.example-1" "$CAPTURED_STDOUT"
}

test_unicode_domains_become_punycode() {
  setup_root
  capture review request --domain "bücher.example" --requested-by sirven --case "x" --date 2026-10-01
  assert_eq "2026-10-01-xn--bcher-kva.example-1" "$CAPTURED_STDOUT"
}

test_a_request_needs_a_case_and_a_known_requester() {
  setup_root
  assert_status 1 review request --domain a.example --requested-by stranger --case "x"
  assert_status 1 review request --domain a.example --requested-by sirven --case "  "
  assert_status 1 review request --domain a.example --requested-by sirven --case "x" --link terms=http://a.example
}

test_a_prepared_decision_starts_pending_with_no_votes() {
  setup_root
  prepared_decision a.example
  review build > /dev/null
  local registry="$TEST_TMP/allowlist/registry.json"
  assert_eq 0 "$(json_value "$registry" '["approved"].__len__()')"
  assert_eq a.example "$(json_value "$registry" '["pending"][0]["domain"]')"
  assert_eq "pending reviewer approval" "$(json_value "$registry" '["pending"][0]["status"]')"
}

test_only_a_listed_reviewer_can_vote() {
  setup_root
  prepared_decision a.example
  capture review vote 2026-10-02-a.example-1 --reviewer "the preparer" --decision approve --scope public_pages --date 2026-10-09
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "not a reviewer"
}

test_approval_waits_for_the_notice_period() {
  setup_root
  prepared_decision a.example
  capture review vote 2026-10-02-a.example-1 --reviewer "Jose Sirven" --decision approve --scope public_pages --date 2026-10-07
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "notice period runs until 2026-10-08"
  capture review vote 2026-10-02-a.example-1 --reviewer "Jose Sirven" --decision approve --scope public_pages --date 2026-10-08
  assert_eq 0 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDOUT" "a.example is now approved for public_pages"
}

test_approval_needs_a_scope_and_a_finished_rubric() {
  setup_root
  review request --domain b.example --requested-by sirven --case "x" --date 2026-10-01 > /dev/null
  review prepare 2026-10-01-b.example-1 --prepared-by "the preparer" --date 2026-10-01 > /dev/null
  assert_status 1 review vote 2026-10-01-b.example-1 --reviewer "Jose Sirven" --decision approve --date 2026-10-09
  capture review vote 2026-10-01-b.example-1 --reviewer "Jose Sirven" --decision approve --scope public_pages --date 2026-10-09
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "every rubric question needs a finding"
}

test_an_approved_site_enters_the_registry_with_its_scope_and_a_new_version() {
  setup_root
  prepared_decision a.example
  review build > /dev/null
  review vote 2026-10-02-a.example-1 --reviewer "Jose Sirven" --decision approve --scope public_pages --date 2026-10-09 > /dev/null
  capture review build
  assert_contains "$CAPTURED_STDOUT" "version 2"
  local registry="$TEST_TMP/allowlist/registry.json"
  assert_eq a.example "$(json_value "$registry" '["approved"][0]["domain"]')"
  assert_eq "['public_pages']" "$(json_value "$registry" '["approved"][0]["scope"]')"
  assert_eq 2026-10-09 "$(json_value "$registry" '["approved"][0]["reviewed"]')"
  assert_eq 0 "$(json_value "$registry" '["pending"].__len__()')"
  assert_eq "['a.example']" "$(json_value "$registry" '["history"][-1]["added_to_approved"]')"
  assert_status 0 review validate
}

test_a_council_needs_quorum_and_shares_only_the_common_scope() {
  setup_root
  cat > "$TEST_TMP/allowlist/policy.json" <<'END'
{"created": "2026-10-01", "reviewers": ["Jose Sirven", "Second Reviewer"], "quorum": 2, "notice_days": 0, "max_additions_per_version": 2}
END
  prepared_decision a.example
  capture review vote 2026-10-02-a.example-1 --reviewer "Jose Sirven" --decision approve --scope public_pages --scope authenticated_sessions --date 2026-10-03
  assert_contains "$CAPTURED_STDOUT" "a.example is now pending"
  capture review vote 2026-10-02-a.example-1 --reviewer "Second Reviewer" --decision approve --scope public_pages --date 2026-10-03
  assert_contains "$CAPTURED_STDOUT" "a.example is now approved for public_pages"
}

test_a_decline_is_published_with_the_reviewers_reason() {
  setup_root
  prepared_decision a.example
  review vote 2026-10-02-a.example-1 --reviewer "Jose Sirven" --decision decline --note "the site sues agents" --date 2026-10-03 > /dev/null
  review build > /dev/null
  local registry="$TEST_TMP/allowlist/registry.json"
  assert_eq "the site sues agents" "$(json_value "$registry" '["declined"][0]["rationale"]')"
  assert_eq 0 "$(json_value "$registry" '["approved"].__len__()')"
}

test_a_new_review_supersedes_and_removal_is_recorded() {
  setup_root
  prepared_decision a.example
  review vote 2026-10-02-a.example-1 --reviewer "Jose Sirven" --decision approve --scope public_pages --date 2026-10-09 > /dev/null
  review build > /dev/null
  review request --domain a.example --requested-by site_operator --case "the site asked to be removed" --date 2026-11-01 > /dev/null
  capture review prepare 2026-11-01-a.example-1 --prepared-by "the preparer" --date 2026-11-01
  assert_eq "2026-11-01-a.example-1" "$CAPTURED_STDOUT"
  assert_eq 2026-10-02-a.example-1 "$(json_value "$TEST_TMP/allowlist/decisions/2026-11-01-a.example-1.json" '["supersedes"]')"
  assert_status 1 review vote 2026-10-02-a.example-1 --reviewer "Jose Sirven" --decision decline --date 2026-11-02
  review build > /dev/null
  local registry="$TEST_TMP/allowlist/registry.json"
  assert_eq "['a.example']" "$(json_value "$registry" '["history"][-1]["removed_from_approved"]')"
  assert_eq 0 "$(json_value "$registry" '["approved"].__len__()')"
}

test_records_are_append_only() {
  setup_root
  review request --domain c.example --requested-by sirven --case "x" --date 2026-10-01 > /dev/null
  capture review request --domain c.example --requested-by sirven --case "again" --date 2026-10-01
  assert_eq "2026-10-01-c.example-2" "$CAPTURED_STDOUT"
}

test_growth_is_capped_per_version() {
  setup_root
  local domain
  for domain in a.example b.example c.example; do
    prepared_decision "$domain"
  done
  review build > /dev/null
  for domain in a.example b.example c.example; do
    review vote "2026-10-02-$domain-1" --reviewer "Jose Sirven" --decision approve --scope public_pages --date 2026-10-09 > /dev/null
  done
  capture review build
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "allows 2 per version"
}

test_a_hand_edited_approval_fails_validation() {
  setup_root
  prepared_decision a.example
  review build > /dev/null
  python3 - "$TEST_TMP/allowlist/registry.json" <<'END'
import json, sys
registry = json.load(open(sys.argv[1]))
registry["approved"] = [dict(registry["pending"][0], scope=["public_pages"])]
json.dump(registry, open(sys.argv[1], "w"), indent=2)
END
  capture review validate
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "a.example is in both approved and pending"
  assert_contains "$CAPTURED_STDERR" "approved without enough reviewer votes"
}

test_build_writes_no_clock_dates() {
  setup_root
  prepared_decision a.example
  review build > /dev/null
  assert_eq 2026-10-02 "$(json_value "$TEST_TMP/allowlist/registry.json" '["updated"]')"
  assert_status 0 review build --check
}

test_staging_publish_writes_versions_and_checksums() {
  setup_root
  prepared_decision a.example
  review build > /dev/null
  capture review publish --dest "$TEST_TMP/site" --staging
  assert_eq 0 "$CAPTURED_STATUS"
  assert_file_exists "$TEST_TMP/site/registry.json"
  assert_file_exists "$TEST_TMP/site/versions/registry-v1.json"
  (cd "$TEST_TMP/site" && check_sha256 registry.json.sha256 > /dev/null) || fail "registry checksum does not match"
  (cd "$TEST_TMP/site/versions" && check_sha256 registry-v1.json.sha256 > /dev/null) || fail "version checksum does not match"
  assert_status 0 review publish --dest "$TEST_TMP/site" --staging
}

test_publish_never_rewrites_a_published_version() {
  setup_root
  prepared_decision a.example
  review build > /dev/null
  review publish --dest "$TEST_TMP/site" --staging > /dev/null
  printf 'tampered\n' >> "$TEST_TMP/site/versions/registry-v1.json"
  capture review publish --dest "$TEST_TMP/site" --staging
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "already published with different content"
}

test_a_public_publish_needs_a_named_reviewer() {
  setup_root
  review build > /dev/null
  assert_status 2 review publish --dest "$TEST_TMP/site"
  capture review publish --dest "$TEST_TMP/site" --confirmed-by "the preparer"
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "naming a reviewer in policy.json"
  assert_no_file "$TEST_TMP/site/registry.json"
}

test_the_review_sheet_shows_the_vote_commands() {
  setup_root
  prepared_decision a.example
  capture review sheet 2026-10-02-a.example-1
  assert_contains "$CAPTURED_STDOUT" "approval counts from 2026-10-08"
  assert_contains "$CAPTURED_STDOUT" "vote 2026-10-02-a.example-1 --reviewer NAME --decision approve --scope public_pages"
  capture review queue
  assert_contains "$CAPTURED_STDOUT" "a.example	recommended: approve public_pages"
}

test_a_single_reviewer_may_vote_on_a_review_they_prepared() {
  setup_root
  review request --domain a.example --requested-by sirven --case "x" --date 2026-10-01 > /dev/null
  review prepare 2026-10-01-a.example-1 --prepared-by "Jose Sirven" --date 2026-10-01 > /dev/null
  assert_status 0 review vote 2026-10-01-a.example-1 --reviewer "Jose Sirven" --decision decline --note "no" --date 2026-10-02
  review build > /dev/null
  assert_status 0 review validate
}

test_a_council_keeps_preparer_and_voter_apart() {
  setup_root
  cat > "$TEST_TMP/allowlist/policy.json" <<'END'
{"created": "2026-10-01", "reviewers": ["Jose Sirven", "Second Reviewer"], "quorum": 2, "notice_days": 0, "max_additions_per_version": 2}
END
  review request --domain a.example --requested-by sirven --case "x" --date 2026-10-01 > /dev/null
  review prepare 2026-10-01-a.example-1 --prepared-by "Jose Sirven" --date 2026-10-01 > /dev/null
  capture review vote 2026-10-01-a.example-1 --reviewer "Jose Sirven" --decision decline --date 2026-10-02
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "the preparer does not vote"
}

test_a_council_handoff_is_a_new_registry_version() {
  setup_root
  review build > /dev/null
  cat > "$TEST_TMP/allowlist/policy.json" <<'END'
{"created": "2026-10-01", "reviewers": ["Jose Sirven", "Second Reviewer"], "quorum": 2, "notice_days": 7, "max_additions_per_version": 2}
END
  assert_status 1 review build --check
  assert_status 1 review validate
  review build > /dev/null
  local registry="$TEST_TMP/allowlist/registry.json"
  assert_eq 2 "$(json_value "$registry" '["version"]')"
  assert_eq 2 "$(json_value "$registry" '["quorum"]')"
  assert_eq "['Jose Sirven', 'Second Reviewer']" "$(json_value "$registry" '["history"][-1]["reviewers_now"]')"
}
