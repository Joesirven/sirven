# shellcheck shell=bash
# the Cloudflare transport in the installer's plan: the step that makes the tunnel, its undo in the install record, the kill switch and
# uninstall that take it away (also a tunnel a failed run left half made), the refusals before any change, and the token that reaches
# only the steps that need it. the helper itself, against a fake API, is tested in test_cloudflare_tunnel.sh.

SENTINEL_TOKEN="cfapi""SENTINELtoken0123456789_ZZZZ-9876543210abc"
ACCOUNT="0123456789abcdef0123456789abcdef"
HOST_NAME="agent.example.org"

install_sh() {
  SIRVEN_OS_OVERRIDE="${TEST_OS:-linux}" SIRVEN_TAILSCALE=none SIRVEN_BB=none "$REPO_DIR/install.sh" "$@" --owner example
}

uninstall_sh() {
  SIRVEN_OS_OVERRIDE="${TEST_OS:-linux}" "$REPO_DIR/uninstall.sh" "$@"
}

cloudflare_install() {
  install_sh --prefix "$TEST_ROOT" --level "${LEVEL_FOR_RUN:-observer}" --transport cloudflare --cloudflare-hostname "$HOST_NAME" --cloudflare-account "$ACCOUNT" "$@"
}

# nothing under the folders, or in the last output, holds the token.
assert_token_nowhere() {
  if grep -rl -F -- "$SENTINEL_TOKEN" "$@" >/dev/null 2>&1; then fail "the API token was written under: $*"; fi
  assert_not_contains "$CAPTURED_STDOUT" "$SENTINEL_TOKEN" "standard output"
  assert_not_contains "$CAPTURED_STDERR" "$SENTINEL_TOKEN" "standard error"
}

# the lines of the plan that belong to the cloudflare transport, without the prefix of the fake root, to compare levels
cloudflare_section() {
  printf '%s\n' "$1" | sed -n '/^transport: cloudflare tunnel/,/^summary:/p' | sed '$d' | sed "s|$TEST_ROOT||g"
}

test_the_apply_on_a_fake_root_records_the_tunnel_step_and_its_undo() {
  TEST_ROOT="$TEST_TMP/root"
  SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" assert_status 0 cloudflare_install
  assert_not_contains "$CAPTURED_STDERR" "not yet"
  assert_contains "$CAPTURED_STDOUT" "make the tunnel, point the hostname at it, and run it as a service"
  assert_contains "$(cat "$TEST_ROOT/var/lib/sirven/simulated-system-commands.log")" "cloudflare_tunnel.sh up"
  assert_contains "$(cat "$TEST_ROOT/var/lib/sirven/install-record.tsv")" "cloudflare_tunnel.sh down --marker $TEST_ROOT/var/lib/sirven/cloudflare-tunnel.json"
  assert_no_file "$TEST_ROOT/var/lib/sirven/cloudflare-tunnel.json"
  assert_token_nowhere "$TEST_ROOT"
  # a second run finds the step recorded and does nothing more
  assert_status 0 cloudflare_install
  assert_contains "$CAPTURED_STDOUT" "applied 0 steps"
}

test_the_plan_names_the_hostname_the_account_and_the_service_and_no_token() {
  TEST_ROOT="$TEST_TMP/root"
  SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" assert_status 0 cloudflare_install --dry-run
  assert_contains "$CAPTURED_STDOUT" "--hostname $HOST_NAME --account $ACCOUNT"
  assert_contains "$CAPTURED_STDOUT" "sirven-cloudflared.service"
  assert_contains "$CAPTURED_STDOUT" "/etc/sirven/cloudflare-api-token"
  assert_token_nowhere "$TEST_ROOT"
}

# the flags and the environment variables answer the same question
test_the_hostname_and_the_account_can_come_from_the_environment() {
  TEST_ROOT="$TEST_TMP/root"
  SIRVEN_CLOUDFLARE_HOSTNAME="from-env.example.org" SIRVEN_CLOUDFLARE_ACCOUNT_ID="$ACCOUNT" SIRVEN_CLOUDFLARE_ZONE_ID="fedcba9876543210fedcba9876543210" \
    assert_status 0 install_sh --dry-run --prefix "$TEST_ROOT" --level observer --transport cloudflare
  assert_contains "$CAPTURED_STDOUT" "--hostname from-env.example.org --account $ACCOUNT --zone fedcba9876543210fedcba9876543210"
}

test_bad_hostnames_and_numbers_are_usage_errors() {
  assert_status 64 install_sh --dry-run --transport cloudflare --cloudflare-hostname "Agent.Example.org"
  assert_contains "$CAPTURED_STDERR" "--cloudflare-hostname must be a plain lowercase host name"
  assert_status 64 install_sh --dry-run --transport cloudflare --cloudflare-hostname "nodots"
  assert_status 64 install_sh --dry-run --transport cloudflare --cloudflare-hostname "a b.example.org"
  assert_status 64 install_sh --dry-run --transport cloudflare --cloudflare-account "12345"
  assert_contains "$CAPTURED_STDERR" "--cloudflare-account must be the 32 character account number"
  SIRVEN_CLOUDFLARE_ZONE_ID=nonsense assert_status 64 install_sh --dry-run --transport cloudflare
  assert_contains "$CAPTURED_STDERR" "SIRVEN_CLOUDFLARE_ZONE_ID must be the 32 character zone number"
  assert_status 64 install_sh --dry-run --transport cloudflare --cloudflare-hostname
  assert_contains "$CAPTURED_STDERR" "--cloudflare-hostname needs a value"
}

# the routing does not depend on the level: the cloudflare part of the plan is the same text for all three
test_the_routing_is_the_same_for_every_level() {
  local observer builder operator
  TEST_ROOT="$TEST_TMP/root"
  LEVEL_FOR_RUN=observer assert_status 0 cloudflare_install --dry-run --path /srv/app
  observer="$(cloudflare_section "$CAPTURED_STDOUT")"
  LEVEL_FOR_RUN=builder assert_status 0 cloudflare_install --dry-run --path /srv/app
  builder="$(cloudflare_section "$CAPTURED_STDOUT")"
  LEVEL_FOR_RUN=operator assert_status 0 cloudflare_install --dry-run --path /srv/app
  operator="$(cloudflare_section "$CAPTURED_STDOUT")"
  assert_contains "$observer" "routes exactly one hostname, $HOST_NAME, to this machine's SSH server (ssh://localhost:22), whatever the level"
  assert_eq "$observer" "$builder" "observer and builder"
  assert_eq "$observer" "$operator" "observer and operator"
  # nothing in any level file names a network route that could widen it
  assert_eq "" "$(grep -il -e 'ingress' -e 'tunnel' -e 'route' "$REPO_DIR"/levels/*.json || true)" "a level that talks about routes"
}

test_on_macos_the_apply_stops_before_any_change_and_says_why() {
  TEST_OS=macos
  TEST_ROOT="$TEST_TMP/root"
  assert_status 0 cloudflare_install --dry-run
  assert_contains "$CAPTURED_STDOUT" "make the tunnel, point the hostname at it, and run it as a service (plan only)"
  assert_status 3 cloudflare_install
  assert_contains "$CAPTURED_STDERR" "the tunnel service is a systemd unit, which only linux has"
  assert_no_file "$TEST_ROOT"
}

test_the_pinned_copy_holds_the_scripts_the_undo_calls() {
  TEST_ROOT="$TEST_TMP/root"
  assert_status 0 cloudflare_install
  assert_file_exists "$TEST_ROOT/var/lib/sirven/package/lib/cloudflare_tunnel.sh"
  assert_file_exists "$TEST_ROOT/var/lib/sirven/package/lib/cloudflare_api.py"
  assert_file_exists "$TEST_ROOT/var/lib/sirven/package/lib/secret_file.sh"
}

test_the_install_record_takes_the_tunnel_away_before_the_pinned_copy_goes() {
  local down_line copy_line
  TEST_ROOT="$TEST_TMP/root"
  assert_status 0 cloudflare_install
  assert_status 0 uninstall_sh --dry-run --prefix "$TEST_ROOT"
  assert_contains "$CAPTURED_STDOUT" "take this machine's Cloudflare tunnel away, if this installer made it"
  down_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n "take this machine's Cloudflare tunnel away" | cut -d: -f1 | head -n 1)"
  copy_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n 'remove the pinned copy of this package' | cut -d: -f1)"
  [ "$down_line" -lt "$copy_line" ] || fail "the teardown (line $down_line) must come before the pinned copy goes (line $copy_line)"
}

# ---- the kill switch

test_revoke_takes_the_tunnel_away_whatever_transport_it_names_but_only_when_this_installer_made_one() {
  TEST_ROOT="$TEST_TMP/root"
  assert_status 0 cloudflare_install
  assert_status 0 install_sh revoke --all --dry-run --prefix "$TEST_ROOT" --transport cloudflare
  assert_not_contains "$CAPTURED_STDOUT" "take this machine's Cloudflare tunnel away"
  printf '{"tunnel_id": "x"}\n' > "$TEST_ROOT/var/lib/sirven/cloudflare-tunnel.json"
  assert_status 0 install_sh revoke --all --dry-run --prefix "$TEST_ROOT" --transport cloudflare
  assert_contains "$CAPTURED_STDOUT" "take this machine's Cloudflare tunnel away: its service and credentials, and in your account the tunnel and the alias record this installer made, and only those (to do"
  # a revoke that names no transport, or the default one, still takes it away: the record says what to remove
  assert_status 0 install_sh revoke --all --dry-run --prefix "$TEST_ROOT" --transport none
  assert_contains "$CAPTURED_STDOUT" "take this machine's Cloudflare tunnel away"
  assert_status 0 install_sh revoke --all --dry-run --prefix "$TEST_ROOT"
  assert_contains "$CAPTURED_STDOUT" "take this machine's Cloudflare tunnel away"
  # the old step that stopped a service of the owner's own cloudflared is gone
  assert_not_contains "$CAPTURED_STDOUT" "cloudflared service uninstall"
  assert_not_contains "$CAPTURED_STDOUT" "stop the tunnel service"
}

test_the_revoke_step_continues_on_failure_and_is_checked_at_the_end() {
  TEST_ROOT="$TEST_TMP/root"
  local index=0 found=no
  # shellcheck source=install.sh
  . "$REPO_DIR/install.sh"
  ROOT_DIR="$REPO_DIR"
  mkdir -p "$TEST_ROOT/var/lib/sirven"
  printf '{"tunnel_id": "x"}\n' > "$TEST_ROOT/var/lib/sirven/cloudflare-tunnel.json"
  parse_arguments revoke --all --prefix "$TEST_ROOT" --level observer --transport none --owner example
  OPERATING_SYSTEM=linux
  PACKAGE="$(package_name "$ROOT_DIR/project.json")"
  layout_set_directories
  STAGE_DIR="$TEST_TMP/stage"; mkdir -p "$STAGE_DIR"
  PLAN_PREFIX="$PREFIX"; PLAN_OPERATING_SYSTEM=linux
  build_plan
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    case "${PLAN_TITLE[index]}" in
      "take this machine's Cloudflare tunnel away"*)
        found=yes
        assert_eq yes "${PLAN_CONTINUE[index]}" "a failure of the teardown must not stop the steps after it"
        assert_eq verify "${PLAN_TAG[index]}" "the last check of the kill switch reads it again"
        ;;
    esac
    index=$((index + 1))
  done
  assert_eq yes "$found" "the plan has the teardown step"
}

# ---- uninstall, with a tunnel the install record does not know about

test_uninstall_takes_away_a_tunnel_a_failed_run_left_half_made() {
  TEST_ROOT="$TEST_TMP/root"
  local record="$TEST_ROOT/var/lib/sirven/install-record.tsv" down_line copy_line
  assert_status 0 cloudflare_install
  # the tunnel step made the tunnel and then failed: its record file is there, the install record has no line for it
  grep -v 'cloudflare_tunnel.sh down' "$record" > "$TEST_TMP/record.without" || true
  cp "$TEST_TMP/record.without" "$record"
  printf '{"tunnel_id": "x"}\n' > "$TEST_ROOT/var/lib/sirven/cloudflare-tunnel.json"
  assert_status 0 uninstall_sh --dry-run --prefix "$TEST_ROOT"
  assert_contains "$CAPTURED_STDOUT" "take this machine's Cloudflare tunnel away: the one a run left behind, and in your account only what its record names (to do"
  down_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n "Cloudflare tunnel away" | cut -d: -f1 | head -n 1)"
  copy_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n 'remove the pinned copy of this package' | cut -d: -f1)"
  [ "$down_line" -lt "$copy_line" ] || fail "the teardown (line $down_line) must come before the pinned copy goes (line $copy_line)"
}

test_uninstall_adds_nothing_without_a_tunnel_and_does_not_take_it_away_twice() {
  TEST_ROOT="$TEST_TMP/root"
  assert_status 0 cloudflare_install
  assert_status 0 uninstall_sh --dry-run --prefix "$TEST_ROOT"
  assert_not_contains "$CAPTURED_STDOUT" "a run left behind"
  printf '{"tunnel_id": "x"}\n' > "$TEST_ROOT/var/lib/sirven/cloudflare-tunnel.json"
  assert_status 0 uninstall_sh --dry-run --prefix "$TEST_ROOT"
  assert_contains "$CAPTURED_STDOUT" "take this machine's Cloudflare tunnel away, if this installer made it"
  assert_not_contains "$CAPTURED_STDOUT" "a run left behind" "the install record already undoes it, and once is enough"
}

# ---- the refusals before any change

test_an_apply_that_cannot_make_the_tunnel_is_refused_before_any_change() {
  # install.sh is sourced so the refusal is read in a real-apply state without root or a container
  # shellcheck source=install.sh
  . "$REPO_DIR/install.sh"
  ROOT_DIR="$REPO_DIR"
  COMMAND=install TRANSPORT=cloudflare DRY_RUN=no PREFIX="" OPERATING_SYSTEM=linux SERVICE_USER=agent
  CONFIG_DIR="$TEST_TMP/etc-sirven" STATE_DIR="$TEST_TMP/var-sirven"
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  CLOUDFLARE_HOSTNAME="" CLOUDFLARE_ACCOUNT="" CLOUDFLARE_ZONE=""
  unset SIRVEN_CLOUDFLARE_API_TOKEN
  HELD_SIRVEN_CLOUDFLARE_API_TOKEN=""
  assert_status 2 cloudflare_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "refused: no hostname is named for the tunnel. nothing was changed."
  assert_contains "$CAPTURED_STDERR" "--cloudflare-hostname"
  CLOUDFLARE_HOSTNAME="$HOST_NAME"
  assert_status 2 cloudflare_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "refused: no Cloudflare account number is named. nothing was changed."
  CLOUDFLARE_ACCOUNT="$ACCOUNT"
  assert_status 2 cloudflare_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "refused: there is no Cloudflare API token to make the tunnel with. nothing was changed."
  assert_contains "$CAPTURED_STDERR" "--transport none"
  assert_contains "$CAPTURED_STDERR" "$CONFIG_DIR/cloudflare-api-token"
  # a token file that others can read is named as the reason, not reported as "no token"
  printf '%s\n' "$SENTINEL_TOKEN" > "$CONFIG_DIR/cloudflare-api-token"
  chmod 666 "$CONFIG_DIR/cloudflare-api-token"
  assert_status 2 cloudflare_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "its mode is"
  assert_contains "$CAPTURED_STDERR" "cannot be trusted"
  assert_contains "$CAPTURED_STDERR" "setfacl -b"
  assert_not_contains "$CAPTURED_STDERR" "there is no Cloudflare API token"
  assert_not_contains "$CAPTURED_STDERR" "$SENTINEL_TOKEN"
  rm -f "$CONFIG_DIR/cloudflare-api-token"
  # a dry run, a fake root, another transport, or macos: no refusal
  DRY_RUN=yes assert_status 0 cloudflare_refuse_before_apply
  DRY_RUN=no PREFIX=/tmp/fake assert_status 0 cloudflare_refuse_before_apply
  TRANSPORT=none assert_status 0 cloudflare_refuse_before_apply
  OPERATING_SYSTEM=macos assert_status 0 cloudflare_refuse_before_apply
  COMMAND=revoke assert_status 0 cloudflare_refuse_before_apply
}

test_an_apply_the_tunnel_step_would_refuse_late_is_refused_up_front_by_its_own_first_look() {
  # shellcheck source=install.sh
  . "$REPO_DIR/install.sh"
  ROOT_DIR="$REPO_DIR"
  COMMAND=install TRANSPORT=cloudflare DRY_RUN=no PREFIX="" OPERATING_SYSTEM=linux SERVICE_USER=agent
  CONFIG_DIR="$TEST_TMP/etc-sirven" STATE_DIR="$TEST_TMP/var-sirven"
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  CLOUDFLARE_HOSTNAME="$HOST_NAME" CLOUDFLARE_ACCOUNT="$ACCOUNT" CLOUDFLARE_ZONE=""
  HELD_SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN"
  # no cloudflared: the first look says how to install it and that nothing was changed (as non-root the seam names none)
  SIRVEN_CLOUDFLARED=none SIRVEN_SYSTEMCTL=none assert_status 2 cloudflare_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "cloudflared is not installed on this machine"
  assert_contains "$CAPTURED_STDERR" "nothing was changed"
  assert_not_contains "$CAPTURED_STDERR" "$SENTINEL_TOKEN"
}

test_cloudflared_missing_or_too_old_is_refused_by_the_preflight_with_how_to_get_it() {
  local bin="$TEST_TMP/bin"
  mkdir -p "$bin"
  # shellcheck source=lib/preflight.sh
  . "$REPO_DIR/lib/preflight.sh"
  PREFLIGHT_PROBLEMS=0
  PATH="/usr/bin:/bin" capture preflight_all linux cloudflare yes
  assert_contains "$CAPTURED_STDERR" "cloudflared 2024.1.0 or newer is not installed. install it from https://developers.cloudflare.com/"
  assert_contains "$CAPTURED_STDERR" "apt install cloudflared"
  printf '#!/bin/sh\necho "cloudflared version 2023.5.0 (built 2023-05-01)"\n' > "$bin/cloudflared"
  chmod 755 "$bin/cloudflared"
  PREFLIGHT_PROBLEMS=0
  PATH="$bin:/usr/bin:/bin" capture preflight_tool yes cloudflared 2024.1.0 --version
  assert_contains "$CAPTURED_STDERR" "cloudflared 2023.5.0 is older than the pinned minimum 2024.1.0"
}

# ---- the token reaches only the steps that need it

# stand-ins for the commands the installer's steps run, each recording the NAMES (never the values) of the variables in the environment
# it was started with, then running the real command. sets SHIM_BIN and SHIM_LOG.
shim_commands_that_record_their_environment() {
  local bin="$TEST_TMP/shims" name real
  mkdir -p "$bin"
  SHIM_BIN="$bin"
  SHIM_LOG="$TEST_TMP/child-environment-names"
  : > "$SHIM_LOG"
  for name in mkdir chmod chown install ln touch cp mv rm id grep cut awk mktemp rmdir; do
    real="$(command -v "$name")" || continue
    cat > "$bin/$name" <<SHIM
#!/bin/sh
printf '%s: %s\\n' "$name" "\$(env | /usr/bin/sed 's/=.*//' | /usr/bin/tr '\\n' ' ')" >> "$SHIM_LOG"
exec "$real" "\$@"
SHIM
    chmod 755 "$bin/$name"
  done
}

test_no_step_starts_a_child_that_inherits_the_token() {
  TEST_ROOT="$TEST_TMP/root"
  shim_commands_that_record_their_environment
  # the held name is exported by the caller with junk in it: it must not become an exported copy of the token
  PATH="$SHIM_BIN:$PATH" SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" HELD_SIRVEN_CLOUDFLARE_API_TOKEN=junk \
    assert_status 0 cloudflare_install
  assert_contains "$(cat "$SHIM_LOG")" "mkdir:" "the steps before the tunnel started children (else this test proves nothing)"
  assert_contains "$(cat "$SHIM_LOG")" "chmod:"
  assert_not_contains "$(cat "$SHIM_LOG")" "CLOUDFLARE_API_TOKEN" "the environment of every child the steps started"
  assert_token_nowhere "$TEST_ROOT" "$SHIM_LOG"
}

test_with_another_transport_a_token_in_the_environment_reaches_no_child() {
  TEST_ROOT="$TEST_TMP/root"
  shim_commands_that_record_their_environment
  PATH="$SHIM_BIN:$PATH" SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" \
    assert_status 0 install_sh --prefix "$TEST_ROOT" --level observer --transport none
  assert_contains "$(cat "$SHIM_LOG")" "mkdir:" "children were started (else this test proves nothing)"
  assert_not_contains "$(cat "$SHIM_LOG")" "CLOUDFLARE_API_TOKEN" "the environment of every child"
}

test_the_step_after_the_tunnel_starts_a_child_that_does_not_inherit_the_token() {
  TEST_ROOT="$TEST_TMP/root"
  local bin="$TEST_TMP/bin" real_rm
  real_rm="$(command -v rm)"
  mkdir -p "$bin" "$TEST_ROOT/etc/sirven"
  cat > "$bin/rm" <<SHIM
#!/bin/sh
case "\$*" in
  *cloudflare-api-token*) env | sed 's/=.*//' > "$TEST_TMP/rm-environment-names" ;;
esac
exec "$real_rm" "\$@"
SHIM
  chmod 755 "$bin/rm"
  printf '%s\n' "$SENTINEL_TOKEN" > "$TEST_ROOT/etc/sirven/cloudflare-api-token"
  chmod 600 "$TEST_ROOT/etc/sirven/cloudflare-api-token"
  PATH="$bin:$PATH" SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" assert_status 0 cloudflare_install
  assert_contains "$CAPTURED_STDOUT" "remove the used API token file"
  assert_file_exists "$TEST_TMP/rm-environment-names"
  assert_not_contains "$(cat "$TEST_TMP/rm-environment-names")" "CLOUDFLARE_API_TOKEN" "the environment of the step after the tunnel"
  assert_no_file "$TEST_ROOT/etc/sirven/cloudflare-api-token"
  assert_token_nowhere "$TEST_ROOT" "$TEST_TMP/rm-environment-names"
}

test_an_uninstall_child_does_not_see_an_exported_token() {
  TEST_ROOT="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$TEST_ROOT" --level observer --transport none
  shim_commands_that_record_their_environment
  PATH="$SHIM_BIN:$PATH" SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" assert_status 0 uninstall_sh --dry-run --prefix "$TEST_ROOT"
  assert_contains "$(cat "$SHIM_LOG")" "mktemp:" "children were started (else this test proves nothing)"
  assert_not_contains "$(cat "$SHIM_LOG")" "CLOUDFLARE_API_TOKEN" "the environment of every child the removal started"
  assert_token_nowhere "$TEST_ROOT" "$SHIM_LOG"
}

# the plan names the held token in the tunnel step, in its undo, and nowhere else
test_the_held_token_is_named_only_by_the_steps_that_use_it() {
  TEST_ROOT="$TEST_TMP/root"
  local index=0 text up_index=-1 handed="$TEST_TMP/handed" joiner="$TEST_TMP/joiner" script
  cat > "$joiner" <<SHIM
#!/bin/sh
# stands in for lib/cloudflare_tunnel.sh: records whether the variable was handed to it, never its value
printf '%s\\n' "\${SIRVEN_CLOUDFLARE_API_TOKEN:+handed}" > "$handed"
SHIM
  chmod 755 "$joiner"
  . "$REPO_DIR/install.sh"
  ROOT_DIR="$REPO_DIR"
  SIRVEN_CLOUDFLARE_API_TOKEN="$SENTINEL_TOKEN" cloudflare_hold_token
  assert_eq "" "$(env | grep CLOUDFLARE_API_TOKEN || true)" "nothing left in the environment after cloudflare_hold_token"
  assert_eq "$SENTINEL_TOKEN" "$HELD_SIRVEN_CLOUDFLARE_API_TOKEN"
  parse_arguments --prefix "$TEST_ROOT" --level observer --transport cloudflare --cloudflare-hostname "$HOST_NAME" --cloudflare-account "$ACCOUNT" --owner example
  setup_from_environment
  OPERATING_SYSTEM=linux
  PACKAGE="$(package_name "$ROOT_DIR/project.json")"
  layout_set_directories
  STAGE_DIR="$TEST_TMP/stage"; mkdir -p "$STAGE_DIR"
  PLAN_PREFIX="$PREFIX"; PLAN_OPERATING_SYSTEM="$OPERATING_SYSTEM"; PLAN_SIMULATION_LOG=""
  build_plan
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    [ "${PLAN_TITLE[index]}" != "make the tunnel, point the hostname at it, and run it as a service" ] || up_index="$index"
    index=$((index + 1))
  done
  [ "$up_index" -ge 0 ] || fail "the install plan has no tunnel step"
  script="$(rooted "$(cloudflare_tunnel_script)")"
  mkdir -p "$(dirname "$script")"
  cp "$joiner" "$script"
  ( eval "${PLAN_ACTION[up_index]}" )
  assert_eq "handed" "$(cat "$handed")" "the tunnel step is handed the held token"
  index=0
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    if [ "$index" -ne "$up_index" ]; then
      for text in "${PLAN_ACTION[index]}" "${PLAN_CHECK[index]}"; do
        assert_not_contains "$text" "CLOUDFLARE_API_TOKEN" "step '${PLAN_TITLE[index]}' names the token's variable"
        assert_not_contains "$text" "$SENTINEL_TOKEN" "step '${PLAN_TITLE[index]}' carries the token"
      done
    fi
    for text in "${PLAN_ACTION[index]}" "${PLAN_CHECK[index]}" "${PLAN_UNDO_ACTION[index]}" "${PLAN_UNDO_CHECK[index]}" "${PLAN_SHOWN[index]}"; do
      assert_not_contains "$text" "$SENTINEL_TOKEN" "step '${PLAN_TITLE[index]}' carries the token"
    done
    index=$((index + 1))
  done
  assert_eq "HELD_SIRVEN_CLOUDFLARE_API_TOKEN SIRVEN_CLOUDFLARE_API_TOKEN" "${PLAN_FORGET[up_index]}" "the tunnel step is the last to need the token"
  assert_eq "" "$(env | grep CLOUDFLARE_API_TOKEN || true)"
}

# the service of the owner's own cloudflared is never named
test_the_plan_never_touches_a_cloudflared_service_of_the_owner() {
  TEST_ROOT="$TEST_TMP/root"
  assert_status 0 cloudflare_install --dry-run
  assert_not_contains "$CAPTURED_STDOUT" "cloudflared service install"
  assert_not_contains "$CAPTURED_STDOUT" "cloudflared service uninstall"
  assert_not_contains "$CAPTURED_STDOUT" "/etc/cloudflared"
  assert_not_contains "$CAPTURED_STDOUT" "tunnel login"
  assert_not_contains "$CAPTURED_STDOUT" "route dns"
}
