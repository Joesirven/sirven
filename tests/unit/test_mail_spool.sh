# shellcheck shell=bash
# the empty mail spool Fedora's account tool leaves for the service user: found, removed, and kept when it is not ours.
# all on a fake root inside TEST_TMP; the account running the test stands in for the service user.

# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/plan.sh
. "$REPO_DIR/lib/plan.sh"
# shellcheck source=lib/layout.sh
. "$REPO_DIR/lib/layout.sh"
# shellcheck source=lib/service_user.sh
. "$REPO_DIR/lib/service_user.sh"

setup_spool_root() {
  PREFIX="$TEST_TMP/root"
  OPERATING_SYSTEM=linux
  ME="$(id -un)"
  mkdir -p "$PREFIX/var/spool/mail"
  ln -s spool/mail "$PREFIX/var/mail"
}

test_an_empty_plain_spool_owned_by_the_user_is_listed_and_removed() {
  setup_spool_root
  : > "$PREFIX/var/spool/mail/$ME"
  assert_contains "$(layout_mail_spool_removable "$ME")" "$PREFIX/var/spool/mail/$ME"
  layout_mail_spool_gone "$ME" && fail "a removable spool was reported as gone"
  assert_status 0 layout_remove_mail_spool "$ME"
  assert_no_file "$PREFIX/var/spool/mail/$ME"
  layout_mail_spool_gone "$ME" || fail "the spool is not reported gone after removal"
}

test_a_spool_with_mail_in_it_is_kept() {
  setup_spool_root
  printf 'a message\n' > "$PREFIX/var/spool/mail/$ME"
  layout_mail_spool_gone "$ME" || fail "a spool with mail in it must not be listed"
  assert_status 0 layout_remove_mail_spool "$ME"
  assert_file_exists "$PREFIX/var/spool/mail/$ME"
}

test_a_spool_owned_by_another_account_is_kept() {
  setup_spool_root
  : > "$PREFIX/var/spool/mail/someone-else"
  layout_mail_spool_gone someone-else || fail "a spool not owned by its name must not be listed"
  assert_status 0 layout_remove_mail_spool someone-else
  assert_file_exists "$PREFIX/var/spool/mail/someone-else"
}

test_a_link_in_place_of_the_spool_is_never_followed() {
  setup_spool_root
  : > "$TEST_TMP/target"
  ln -s "$TEST_TMP/target" "$PREFIX/var/spool/mail/$ME"
  layout_mail_spool_gone "$ME" || fail "a link must not be listed"
  assert_status 0 layout_remove_mail_spool "$ME"
  assert_file_exists "$TEST_TMP/target"
  [ -L "$PREFIX/var/spool/mail/$ME" ] || fail "the link was removed"
}

test_no_spool_at_all_is_already_done() {
  setup_spool_root
  layout_mail_spool_gone "$ME" || fail "nothing there must count as done"
  assert_status 0 layout_remove_mail_spool "$ME"
}

test_the_plan_has_the_step_and_its_undo_after_the_account_step() {
  PREFIX="" PACKAGE=sirven SERVICE_USER=agent OPERATING_SYSTEM=linux
  plan_reset
  plan_service_user_linux
  # step 0 makes the account, step 1 removes the spool: undo runs in reverse, so the spool goes before the account does
  assert_contains "${PLAN_ACTION[0]}" "useradd "
  assert_eq "layout_remove_mail_spool agent" "${PLAN_ACTION[1]}"
  assert_eq "layout_remove_mail_spool agent" "${PLAN_UNDO_ACTION[1]}"
  assert_contains "${PLAN_UNDO_ACTION[0]}" "userdel agent"
  assert_contains "${PLAN_CHECK[1]}" "id -u agent"
  assert_contains "${PLAN_CHECK[1]}" "layout_mail_spool_gone agent"
  assert_eq "layout_mail_spool_gone agent" "${PLAN_UNDO_CHECK[1]}"
}
