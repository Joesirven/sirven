# shellcheck shell=bash
# idempotency: every step that changes something carries a read-only probe of its end state, so
# a re-run skips it. a step with no such probe must say so with the always tag.

# shellcheck source=install.sh
. "$REPO_DIR/install.sh"

# plan_for OPERATING_SYSTEM ARGUMENT...: build the plan install.sh would print, without printing.
plan_for() {
  local os="$1"
  shift
  SIRVEN_OS_OVERRIDE="$os"
  parse_arguments "$@" --dry-run --prefix "$TEST_TMP/root" --owner example
  OPERATING_SYSTEM="$os"
  PACKAGE=sirven
  layout_set_directories
  STAGE_DIR="$TEST_TMP/stage"
  mkdir -p "$STAGE_DIR"
  build_plan
}

# steps that change something but have neither a probe nor the always tag.
unprobed_steps() {
  local index=0
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    case "${PLAN_KIND[index]}" in
      run | system | planonly)
        if [ -z "${PLAN_CHECK[index]}" ] && [ "${PLAN_TAG[index]}" != always ]; then
          printf '%s\n' "${PLAN_TITLE[index]}"
        fi
        ;;
    esac
    index=$((index + 1))
  done
}

test_every_install_step_has_a_probe() {
  local os transport path
  for os in linux macos; do
    path=/srv/app
    [ "$os" = macos ] && path=/opt/work/app
    for transport in tailscale cloudflare none; do
      plan_for "$os" --level builder --path "$path" --transport "$transport" --with-bb
      assert_eq "" "$(unprobed_steps)" "install on $os over $transport"
    done
  done
}

test_every_kill_switch_step_has_a_probe() {
  local os transport
  for os in linux macos; do
    for transport in tailscale cloudflare none; do
      plan_for "$os" revoke --all --level builder --path /opt/work/app --transport "$transport"
      assert_eq "" "$(unprobed_steps)" "revoke on $os over $transport"
    done
  done
}

test_every_recorded_step_can_be_reversed_and_checked() {
  local index=0
  plan_for linux --level builder --path /srv/app --transport none
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    if [ -n "${PLAN_UNDO_TITLE[index]}" ] && [ "${PLAN_KIND[index]}" != owner ]; then
      [ -n "${PLAN_UNDO_CHECK[index]}" ] || fail "the undo of '${PLAN_TITLE[index]}' has no probe"
    fi
    index=$((index + 1))
  done
}
