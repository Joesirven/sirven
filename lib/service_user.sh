# shellcheck shell=bash
# service user plan steps. the agent runs as its own account: no administrator group, no
# password, SSH keys only.
#
# linux uses useradd and usermod. macos uses dscl: sysadminctl -addUser wants a password and
# this account never gets one. macos steps are plan only until a macos virtual machine run
# verifies them.
#
# undo: removing the account keeps its home folder. what the agent left there was not created
# by this package, so the owner looks before deleting it.
# reads: PREFIX, PACKAGE, OPERATING_SYSTEM, SERVICE_USER

SERVICE_USER_MACOS_REASON="macos account creation is plan output in the alpha cut; apply needs a run in a macos virtual machine"

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
  plan_undo "remove the SSH folder of $user if nothing else is inside" "[ ! -d $ssh ] && [ ! -L $ssh ]" \
    "layout_remove_ssh_folder $home" "rmdir $ssh   # kept if anything else is inside; a link in its place is removed, never followed"
  plan_step system "create an empty authorized_keys file" "[ -f $keys ]" \
    "install -m 0600 -o $user -g $user /dev/null $keys"
  plan_undo "remove every authorized key of $user" "layout_keys_gone $home" "layout_remove_keys $home" \
    "rm -f $keys   # by name, never through a link"
}

plan_service_user_macos() {
  local user="$SERVICE_USER" home number ssh keys
  home="$(rooted "$(service_user_home)")"
  ssh="$(rooted "$(service_user_home)/.ssh")"
  keys="$(rooted "$(service_user_home)/.ssh/authorized_keys")"
  number="$(service_user_macos_number)"
  plan_planonly "create the service user $user, hidden, not an administrator" \
"dscl . -create /Users/$user
dscl . -create /Users/$user UserShell /bin/zsh
dscl . -create /Users/$user RealName '$PACKAGE agent'
dscl . -create /Users/$user UniqueID $number
dscl . -create /Users/$user PrimaryGroupID 20
dscl . -create /Users/$user NFSHomeDirectory $home
dscl . -create /Users/$user Password '*'
dscl . -create /Users/$user IsHidden 1
createhomedir -c -u $user" \
    "$SERVICE_USER_MACOS_REASON" \
    "dscl . -read /Users/$user >/dev/null 2>&1"
  plan_undo "end every process of $user, then remove the account, keeping $(service_user_home)" \
    "! dscl . -read /Users/$user >/dev/null 2>&1" \
    "{ pkill -KILL -u $user || true; } && dscl . -delete /Users/$user"
  plan_planonly "confirm $user is not in the admin group" \
    "dseditgroup -o checkmember -m $user admin   # must answer no" \
    "$SERVICE_USER_MACOS_REASON" \
    "! dseditgroup -o checkmember -m $user admin >/dev/null 2>&1"
  plan_planonly "create the SSH folder and an empty authorized_keys file" \
"install -d -m 0700 -o $user -g staff $ssh
install -m 0600 -o $user -g staff /dev/null $keys" \
    "$SERVICE_USER_MACOS_REASON" \
    "[ -f $keys ]"
  plan_undo "remove the SSH folder and every authorized key of $user" "[ ! -d $ssh ] && [ ! -L $ssh ]" \
    "layout_remove_keys $home && layout_remove_ssh_folder $home" "rm -f $keys && rmdir $ssh   # by name, never through a link"
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
