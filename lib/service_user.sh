# shellcheck shell=bash
# service user plan steps. the agent runs as its own account: no administrator group, no
# password, SSH keys only.
#
# linux uses useradd and usermod. macos uses dscl: sysadminctl -addUser wants a password and
# this account never gets one. the macos steps run on a fake root (--prefix, recorded not run); a real
# macos apply stays switched off until tests/macos/real-install-check.sh has passed (lib/plan.sh).
#
# undo: removing the account keeps its home folder. what the agent left there was not created
# by this package, so the owner looks before deleting it.
# reads: PREFIX, PACKAGE, OPERATING_SYSTEM, SERVICE_USER

# shellcheck source=lib/service_user_macos.sh
. "$(dirname "${BASH_SOURCE[0]}")/service_user_macos.sh"

service_user_home() {
  case "$OPERATING_SYSTEM" in
    macos) printf '/Users/%s' "$SERVICE_USER" ;;
    *) printf '/home/%s' "$SERVICE_USER" ;;
  esac
}

# fail when the user sits in an administrator group. used as an apply step.
service_user_refuse_admin() {
  local groups
  groups=" $(id -nG "$1") "
  case "$groups" in
    *" sudo "* | *" wheel "* | *" admin "*)
      printf 'error: %s is in an administrator group (%s); remove it before going on\n' "$1" "$groups" >&2
      return 1
      ;;
  esac
}

# first free macos account number at or above 601. a fake root always gets 601.
service_user_macos_number() {
  local number=601
  if [ -z "$PREFIX" ] && [ "$OPERATING_SYSTEM" = macos ] && command -v dscl >/dev/null 2>&1; then
    while dscl . -search /Users UniqueID "$number" 2>/dev/null | grep -q .; do
      number=$((number + 1))
    done
  fi
  printf '%s' "$number"
}

plan_service_user_linux() {
  local user="$SERVICE_USER" home ssh keys
  home="$(rooted "$(service_user_home)")"
  ssh="$(rooted "$(service_user_home)/.ssh")"
  keys="$(rooted "$(service_user_home)/.ssh/authorized_keys")"
  plan_step system "create the service user $user, not an administrator" \
    "id -u $user >/dev/null 2>&1" \
    "useradd --create-home --home-dir $home --shell /bin/bash --user-group --comment '$PACKAGE agent' $user"
  plan_undo "end every process of $user, then remove the account, keeping $(service_user_home)" \
    "! id -u $user >/dev/null 2>&1" \
    "{ pkill -KILL -u $user || true; } && userdel $user"
  plan_step system "turn off password login for $user, keys only" \
    "[ \"\$(getent shadow $user 2>/dev/null | cut -d: -f2)\" = '*' ]" \
    "usermod --password '*' $user"
  plan_step system "confirm $user is not in sudo, wheel, or admin" "" \
    "service_user_refuse_admin $user" \
    "id -nG $user   # must not list sudo, wheel, or admin"
  plan_tag always
  plan_step system "create the SSH folder for $user" "[ -d $ssh ]" \
    "install -d -m 0700 -o $user -g $user $ssh"
  plan_undo "remove the SSH folder of $user if nothing else is inside" "[ ! -d $ssh ]" \
    "layout_remove_directory $ssh" "rmdir $ssh   # kept if anything else is inside"
  plan_step system "create an empty authorized_keys file" "[ -f $keys ]" \
    "install -m 0600 -o $user -g $user /dev/null $keys"
  plan_undo "remove every authorized key of $user" "[ ! -e $keys ]" "rm -f $keys"
}

# service_user_macos_real_name: the real name the macos account is created with. an account that
# carries it was made by an earlier run of this package, which is how a re-run tells it from an
# account someone else made under the same name.
service_user_macos_real_name() {
  printf '%s agent' "$PACKAGE"
}

# service_user_macos_complete USER HOME: exit 0 only when the account is whole: a number, the hidden flag,
# the home folder it names, no password, and the home folder on disk. a half-made account is not done.
service_user_macos_complete() {
  [ -n "$(service_user_macos_field "$1" UniqueID)" ] || return 1
  [ -n "$(service_user_macos_field "$1" GeneratedUID)" ] || return 1
  [ "$(service_user_macos_field "$1" IsHidden)" = 1 ] || return 1
  [ "$(service_user_macos_field "$1" NFSHomeDirectory)" = "$2" ] || return 1
  [ "$(service_user_macos_field "$1" Password)" = '*' ] || return 1
  [ -d "$2" ]
}

# service_user_macos_create USER NUMBER HOME REAL_NAME: make the account, or finish one an earlier run left
# half made. an account this call started and could not finish is removed again, so a failed run leaves
# nothing to find. errexit is off inside a plan step, so every command is chained.
service_user_macos_create() {
  local user="$1" number="$2" home="$3" real_name="$4" existed=no existing
  existing="$(service_user_macos_field "$user" UniqueID)"
  if service_user_macos_exists "$user"; then
    existed=yes
  fi
  if [ -n "$existing" ]; then
    number="$existing"
  fi
  if ! {
    dscl . -create "/Users/$user" &&
      dscl . -create "/Users/$user" UserShell /bin/zsh &&
      dscl . -create "/Users/$user" RealName "$real_name" &&
      dscl . -create "/Users/$user" UniqueID "$number" &&
      dscl . -create "/Users/$user" PrimaryGroupID 20 &&
      dscl . -create "/Users/$user" NFSHomeDirectory "$home" &&
      dscl . -create "/Users/$user" Password '*' &&
      dscl . -create "/Users/$user" IsHidden 1 &&
      { [ -n "$(service_user_macos_field "$user" GeneratedUID)" ] || dscl . -create "/Users/$user" GeneratedUID "$(uuidgen)"; } &&
      createhomedir -c -u "$user" >/dev/null &&
      chmod 0700 "$home" &&
      service_user_macos_complete "$user" "$home"
  }; then
    printf 'error: could not finish creating the account %s\n' "$user" >&2
    if [ "$existed" = no ]; then dscl . -delete "/Users/$user" >/dev/null 2>&1 || true; fi
    return 1
  fi
}

# service_user_macos_refuse_foreign: stop before any change when an account of this name is already on
# the machine and this package did not make it. the removal at the end of a grant (and uninstall) sweeps
# every access list entry of the account, which is only exact for an account that held none before.
service_user_macos_refuse_foreign() {
  local user="$SERVICE_USER" real_name
  [ -z "$PREFIX" ] || return 0
  command -v dscl >/dev/null 2>&1 || return 0
  service_user_macos_exists "$user" || return 0
  real_name="$(service_user_macos_field "$user" RealName)"
  [ "$real_name" != "$(service_user_macos_real_name)" ] || return 0
  if [ "${SIRVEN_MACOS_REAL_APPLY:-}" = 1 ]; then
    DIE_STATUS=2 die "the account $user is already on this machine and this package did not make it (its real name is not '$(service_user_macos_real_name)').
this package keeps and removes only what it created, so it will not set up or take away access for an account it does not own.
run again with --user NAME for a name no account has yet. nothing was changed."
  fi
  plan_note "an account named $user is already on this machine and this package did not make it; a real apply would stop here and ask for another --user NAME."
}

plan_service_user_macos() {
  local user="$SERVICE_USER" home number ssh keys real_name
  home="$(rooted "$(service_user_home)")"
  ssh="$(rooted "$(service_user_home)/.ssh")"
  keys="$(rooted "$(service_user_home)/.ssh/authorized_keys")"
  number="$(service_user_macos_number)"
  real_name="$(service_user_macos_real_name)"
  service_user_macos_refuse_foreign
  plan_step system "create the service user $user, hidden, not an administrator" \
    "service_user_macos_complete $user $home" \
    "service_user_macos_create $user $number $home $(shell_quote "$real_name")" \
"dscl . -create /Users/$user
dscl . -create /Users/$user UserShell /bin/zsh
dscl . -create /Users/$user RealName '$real_name'
dscl . -create /Users/$user UniqueID $number
dscl . -create /Users/$user PrimaryGroupID 20
dscl . -create /Users/$user NFSHomeDirectory $home
dscl . -create /Users/$user Password '*'
dscl . -create /Users/$user IsHidden 1
dscl . -create /Users/$user GeneratedUID \"\$(uuidgen)\"   # only when the directory service gave none
createhomedir -c -u $user
chmod 0700 $home
# if any command fails, an account this step started is deleted again: dscl . -delete /Users/$user"
  plan_undo "end every process of $user, then remove the account, keeping $(service_user_home)" \
    "! dscl . -read /Users/$user >/dev/null 2>&1" \
    "bash $(rooted "$STATE_DIR/package/lib/service_user_macos.sh") remove $user $(shell_quote "$real_name")" \
    "{ pkill -KILL -u $user || true; } && dscl . -delete /Users/$user   # only while its real name is still '$real_name'"
  plan_step system "confirm $user is not in the admin group" "" \
    "service_user_refuse_admin $user" \
    "id -nG $user   # must not list admin"
  plan_tag always
  plan_step system "create the SSH folder for $user" "[ -d $ssh ]" \
    "install -d -m 0700 -o $user -g staff $ssh"
  plan_undo "remove the SSH folder of $user if nothing else is inside" "[ ! -d $ssh ]" \
    "layout_remove_directory $ssh" "rmdir $ssh   # kept if anything else is inside"
  plan_step system "create an empty authorized_keys file" "[ -f $keys ]" \
    "install -m 0600 -o $user -g staff /dev/null $keys"
  plan_undo "remove every authorized key of $user" "[ ! -e $keys ]" "rm -f $keys"
  plan_owner "allow $user in remote login" \
    "system settings, general, sharing, remote login: if it lists allowed users, add $user."
}

plan_service_user() {
  plan_section "service user"
  case "$OPERATING_SYSTEM" in
    macos)
      plan_note "dscl, not sysadminctl -addUser: that one wants a password, and this account never has one."
      plan_service_user_macos
      ;;
    *) plan_service_user_linux ;;
  esac
  plan_owner "add the public key of your agent client" \
    "append its public key, one line, to $(service_user_home)/.ssh/authorized_keys.
keys only: no password is ever set, stored, or typed." \
    "[ -s $(rooted "$(service_user_home)/.ssh/authorized_keys") ]"
}
