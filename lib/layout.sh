# shellcheck shell=bash
# package directories and file writes. every path goes through rooted so --prefix fakes the root.
#
# every directory and file written here carries an undo, so uninstall.sh can reverse it. the
# state directory comes first: it holds the install record, so every later step can be recorded.
# reads: PREFIX, PACKAGE, CONFIG_DIR, STATE_DIR, STAGE_DIR

# layout_set_directories: the package directories, named after the package.
layout_set_directories() {
  # the kept copy is at the fixed path /var/lib/sirven/package (the gate and the launcher use that constant), so the directories must
  # be named sirven too; another name would install and then leave root commands unable to find the kept copy
  if [ "$PACKAGE" != sirven ]; then
    DIE_STATUS=2 die "the package name is '$PACKAGE', but the root gate and the launcher run the kept copy at /var/lib/sirven/package, so this build would install and then find nothing to run. keep the name sirven. nothing was changed."
  fi
  CONFIG_DIR="/etc/$PACKAGE"
  STATE_DIR="/var/lib/$PACKAGE"
  AUDIT_DIR="/var/log/$PACKAGE"
}

# the install record: one undo per applied step. see lib/plan.sh.
layout_record_file() {
  printf '%s/install-record.tsv' "$STATE_DIR"
}

# where system commands are written instead of run under --prefix.
layout_simulation_log() {
  printf '%s/simulated-system-commands.log' "$STATE_DIR"
}

# rooted PATH: the path under the prefix, quoted for a command line.
rooted() {
  shell_quote "${PREFIX}$1"
}

# stage_file NAME: copy standard input into the staging directory and print the staged path.
stage_file() {
  local staged="$STAGE_DIR/$1"
  cat > "$staged"
  printf '%s' "$staged"
}

# layout_state_private PATH: true when the state directory is mode 0700 and, on a real root, owned by root. read only.
layout_state_private() {
  # ls shows the owner and mode the same way on linux and macos, unlike stat
  # shellcheck disable=SC2012
  [ -d "$1" ] || return 1
  # shellcheck disable=SC2012
  [ "$(ls -ldn "$1" | cut -c1-10)" = drwx------ ] || return 1
  # shellcheck disable=SC2012
  [ -n "$PREFIX" ] || [ "$(ls -ldn "$1" | awk '{print $3}')" = 0 ]
}

layout_make_state_private() {
  chmod 0700 "$1" || return 1
  [ -n "$PREFIX" ] || chown 0:0 "$1"
}

# layout_remove_directory PATH: remove a directory this package created, but only when it is
# empty. anything else inside was not created by the package, so the directory is kept.
layout_remove_directory() {
  [ -d "$1" ] || return 0
  if rmdir "$1" 2>/dev/null; then
    return 0
  fi
  printf '       kept %s: it holds files this package did not create\n' "$1"
}

# the agent owns its home folder, so a name inside it may be a link it planted to something of root's. the undo of the
# keys and the ssh folder never goes by path below the home folder: lib/kill_switch.py opens each folder without
# following a link and removes names with unlinkat. HOME is the agent's home folder (under the prefix on a fake root).
layout_helper() {
  python3 -I "$ROOT_DIR/lib/kill_switch.py" "$@"
}

layout_remove_keys() {
  layout_helper remove-keys "$1"
}

layout_keys_gone() {
  layout_helper keys-gone "$1"
}

layout_remove_ssh_folder() {
  layout_helper remove-ssh-folder "$1"
}

# layout_directory PATH MODE TITLE
layout_directory() {
  local path
  path="$(rooted "$1")"
  plan_step run "$3" "[ -d $path ]" "mkdir -p $path && chmod $2 $path"
  plan_undo "remove $1 if nothing else is inside" "[ ! -d $path ]" \
    "layout_remove_directory $path" "rmdir $path   # kept if anything else is inside"
}

# layout_write_file TITLE DESTINATION MODE STAGED_FILE DESCRIPTION
# the staged file holds the exact content; the plan shows where it comes from, not the temp path.
layout_write_file() {
  local title="$1" destination staged description="$5" mode="$3"
  destination="$(rooted "$2")"
  staged="$(shell_quote "$4")"
  plan_step run "$title" "cmp -s $staged $destination" \
    "cp $staged $destination && chmod $mode $destination" \
    "# write $destination (mode $mode): $description"
  plan_undo "remove $2" "[ ! -e $destination ]" "rm -f $destination"
}

# the pinned copy of this package: the files the installer, the uninstaller, and sirven run from.
# it lives under the state directory, so revoke, rollback, and uninstall work after the
# repository or the download is gone. the marker names the release the copy came from.
LAYOUT_PACKAGE_FILES="install.sh uninstall.sh bin lib levels project.json"
# components is optional: a core-only copy of this package has no components folder, and needs none.
LAYOUT_PACKAGE_OPTIONAL_FILES="components"
LAYOUT_PACKAGE_MARKER="PINNED-COPY"

# the launcher: a small script at a fixed path, owned by root, that runs the kept copy of the package with the caller's
# arguments. it is the one invocation the documentation gives for every root command, so no command ever starts from a
# copy in a folder the agent can write. it sets its own search path and reads nothing but the kept copy.
LAYOUT_LAUNCHER="/usr/local/sbin/sirven"

# layout_launcher_safe: true when the folder the launcher goes in, and every folder above it, can be written by root alone, so a
# launcher put there cannot be replaced by anyone else and then run as root. judged with the gate's own checker (sirven_vet, from the
# entry script), on a real linux machine only; a fake root and other systems have nothing real to judge. a folder that does not exist
# yet is judged by the nearest one that does, since the install creates the rest as root.
layout_launcher_safe() {
  local folder
  [ -z "$PREFIX" ] && [ "$OPERATING_SYSTEM" = linux ] || return 0
  command -v sirven_vet >/dev/null 2>&1 || return 1
  folder="$(dirname "$LAYOUT_LAUNCHER")"
  while [ ! -d "$folder" ] && [ "$folder" != / ]; do folder="$(dirname "$folder")"; done
  sirven_vet "$folder" root >/dev/null 2>&1
}

# layout_root_command KIND: the command to give the owner for a root command (revoke, uninstall or rollback): the launcher, unless its
# folder is not safe (or the launcher was refused for that), in which case the kept copy. never a path that was not secured.
layout_root_command() {
  if layout_launcher_safe; then
    case "$1" in
      revoke) printf 'sudo %s revoke --all' "$LAYOUT_LAUNCHER" ;;
      uninstall) printf 'sudo %s uninstall' "$LAYOUT_LAUNCHER" ;;
      rollback) printf 'sudo %s grant rollback' "$LAYOUT_LAUNCHER" ;;
    esac
  else
    case "$1" in
      revoke) printf 'sudo bash %s/install.sh revoke --all' "$(layout_package_copy)" ;;
      uninstall) printf 'sudo bash %s/uninstall.sh' "$(layout_package_copy)" ;;
      rollback) printf 'sudo bash %s/bin/sirven grant rollback' "$(layout_package_copy)" ;;
    esac
  fi
}

# layout_launcher_current PATH: the launcher is there with this text, mode 0755, and (a real root) owned by root. read only.
layout_launcher_current() {
  layout_launcher_text | cmp -s - "$1" || return 1
  # ls shows the owner and mode the same way on linux and macos, unlike stat
  # shellcheck disable=SC2012
  [ "$(ls -ln "$1" | cut -c1-10)" = -rwxr-xr-x ] || return 1
  # shellcheck disable=SC2012
  [ -n "$PREFIX" ] || [ "$(ls -ln "$1" | awk '{print $3}')" = 0 ]
}

# layout_install_launcher PATH: write it beside, set mode and owner, move it into place, so it is never half written.
layout_install_launcher() {
  # judged again now, not only when the plan was made: the folder may have changed since
  layout_launcher_safe || { printf 'error: %s is no longer safe for the launcher (an account other than root can change it); nothing was written\n' "$(dirname "$1")" >&2; return 1; }
  mkdir -p "$(dirname "$1")" || return 1
  layout_launcher_text > "$1.new" || return 1
  chmod 0755 "$1.new" || { rm -f "$1.new"; return 1; }
  if [ -z "$PREFIX" ]; then chown 0:0 "$1.new" || { rm -f "$1.new"; return 1; }; fi
  mv -f "$1.new" "$1"
}

layout_launcher_text() {
  cat <<'END'
#!/bin/sh
# sirven launcher: runs the root-owned kept copy of the package. written by install.sh, owned by root.
#   sirven install ARGUMENTS      the installer
#   sirven revoke --all           the kill switch
#   sirven uninstall              the uninstaller
#   sirven grant inspect|rollback|repair ...   and the other sirven commands
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset BASH_ENV ENV CDPATH LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT PYTHONPATH PYTHONHOME PYTHONSTARTUP
kept=/var/lib/sirven/package
[ -f "$kept/install.sh" ] || { echo "error: no kept copy of the package at $kept: nothing to run. nothing was changed." >&2; exit 2; }
case "${1:-}" in
  install) shift; exec bash "$kept/install.sh" "$@" ;;
  revoke) exec bash "$kept/install.sh" "$@" ;;
  uninstall) shift; exec bash "$kept/uninstall.sh" "$@" ;;
  *) exec bash "$kept/bin/sirven" "$@" ;;
esac
END
}

layout_package_copy() {
  printf '%s/package' "$STATE_DIR"
}

# layout_real_folder PATH: the resolved absolute path of an existing folder, nothing otherwise.
layout_real_folder() {
  [ -d "$1" ] && (cd "$1" && pwd -P)
}

# layout_package_current DESTINATION TAG CHECKSUM SOURCE: true only when DESTINATION is a complete
# copy of release TAG with CHECKSUM. a copy made from a repository checkout (unpinned) has no
# release to compare, so it is current only when its files match SOURCE exactly.
layout_package_current() {
  local destination="$1" tag="$2" checksum="$3" source="$4" item
  if [ "$tag" = unpinned ]; then
    grep -qxF "tag=unpinned" "$destination/$LAYOUT_PACKAGE_MARKER" 2>/dev/null || return 1
  else
    grep -qxF "tag=$tag" "$destination/$LAYOUT_PACKAGE_MARKER" 2>/dev/null || return 1
    grep -qxF "sha256=$checksum" "$destination/$LAYOUT_PACKAGE_MARKER" 2>/dev/null || return 1
  fi
  for item in $LAYOUT_PACKAGE_FILES $LAYOUT_PACKAGE_OPTIONAL_FILES; do
    if [ -e "$source/$item" ]; then
      [ -e "$destination/$item" ] || return 1
      if [ "$tag" = unpinned ]; then
        diff -rq -x __pycache__ "$source/$item" "$destination/$item" >/dev/null 2>&1 || return 1
      fi
    else
      [ ! -e "$destination/$item" ] || return 1
    fi
  done
}

# layout_stage_package SOURCE STAGING: copy the package files into STAGING, checking every step.
# errexit is off inside a plan step, so every command returns its own failure.
layout_stage_package() {
  local source="$1" staging="$2" item
  mkdir "$staging" || return 1
  for item in $LAYOUT_PACKAGE_FILES; do
    [ -e "$source/$item" ] || { printf 'error: the package has no %s to keep\n' "$item" >&2; return 1; }
    cp -R "$source/$item" "$staging/" || { printf 'error: could not copy %s\n' "$item" >&2; return 1; }
  done
  for item in $LAYOUT_PACKAGE_OPTIONAL_FILES; do
    if [ -e "$source/$item" ]; then
      cp -R "$source/$item" "$staging/" || { printf 'error: could not copy %s\n' "$item" >&2; return 1; }
    fi
  done
  find "$staging" -name __pycache__ -type d -prune -exec rm -rf {} + || return 1
  chmod -R go-w "$staging" || return 1
  for item in $LAYOUT_PACKAGE_FILES; do
    [ -e "$staging/$item" ] || return 1
  done
  for item in $LAYOUT_PACKAGE_OPTIONAL_FILES; do
    if [ -e "$source/$item" ]; then [ -e "$staging/$item" ] || return 1; fi
  done
  printf 'tag=%s\nsha256=%s\n' "${SIRVEN_PACKAGE_TAG:-unpinned}" "${SIRVEN_PACKAGE_SHA256:-unpinned}" \
    > "$staging/$LAYOUT_PACKAGE_MARKER" || return 1
}

# layout_keep_package SOURCE DESTINATION: replace DESTINATION with a complete copy of SOURCE. the
# copy is built beside it and moved into place only when every step succeeded, so a failure leaves
# the old copy, or nothing, never a partial one. the marker is written last.
layout_keep_package() {
  local source="$1" destination="$2" source_real parent_real staging
  case "$destination" in
    */package) ;;
    *) printf 'error: refusing to keep a copy of this package at %s\n' "$destination" >&2; return 1 ;;
  esac
  source_real="$(layout_real_folder "$source")" || { printf 'error: no package folder at %s\n' "$source" >&2; return 1; }
  parent_real="$(layout_real_folder "$(dirname "$destination")")" || return 1
  # never copy from the copy itself, or from inside it: replacing the folder would delete the source.
  case "$source_real/" in
    "$parent_real/package/"*) printf 'error: the package runs from its kept copy, which is already in place\n' >&2; return 1 ;;
  esac
  staging="$destination.new"
  rm -rf "$staging" || return 1
  layout_stage_package "$source_real" "$staging" || { rm -rf "$staging"; return 1; }
  rm -rf "$destination" || { rm -rf "$staging"; return 1; }
  mv "$staging" "$destination" || { rm -rf "$staging"; return 1; }
}

# layout_remove_package_copy PATH: remove the copy only when this package made it, so a folder
# with the same name that is not ours is kept.
layout_remove_package_copy() {
  if [ ! -f "$1/$LAYOUT_PACKAGE_MARKER" ]; then
    printf '       kept %s: it is not a copy this package made\n' "$1"
    return 0
  fi
  rm -rf "$1"
}

plan_layout() {
  local state record simulation copy launcher
  state="$(rooted "$STATE_DIR")"
  record="$(rooted "$(layout_record_file)")"
  simulation="$(rooted "$(layout_simulation_log)")"
  plan_section "package directories"
  plan_note "owned by root. the agent can read its policy but never change it."
  plan_step run "create the state directory $STATE_DIR, which records what this install creates" \
    "[ -d $state ]" "mkdir -p $state && chmod 0700 $state"
  plan_tag state
  plan_undo "remove the install record and the state directory $STATE_DIR" "[ ! -d $state ]" \
    "rm -f $record $simulation && layout_remove_directory $state" \
    "rm -f $record && rmdir $state"
  # a state directory that already exists keeps the mode it has, and a 0755 one would let the agent open it and hold the
  # installer lock; so its mode and owner are checked and set whether this run made it or not
  plan_step run "make $STATE_DIR private to root: mode 0700, owned by root" \
    "layout_state_private $state" "layout_make_state_private $state"
  layout_directory "$CONFIG_DIR" 0755 "create the policy directory $CONFIG_DIR"
  layout_directory "$CONFIG_DIR/levels" 0755 "create $CONFIG_DIR/levels for the level in force"
  layout_directory "$CONFIG_DIR/grants" 0755 "create $CONFIG_DIR/grants for grant records"
  copy="$(rooted "$(layout_package_copy)")"
  launcher="$(rooted "$LAYOUT_LAUNCHER")"
  local tag="${SIRVEN_PACKAGE_TAG:-unpinned}" checksum="${SIRVEN_PACKAGE_SHA256:-unpinned}" running_from_copy=""
  if [ -n "$(layout_real_folder "$ROOT_DIR")" ] && \
    [ "$(layout_real_folder "$ROOT_DIR")" = "$(layout_real_folder "$PREFIX$(layout_package_copy)")" ]; then
    running_from_copy=yes
  fi
  if [ -n "$running_from_copy" ]; then
    # the copy never rewrites itself: the folder this installer runs from is the copy already in place.
    plan_note "this package runs from its pinned copy in $(layout_package_copy), which is already in place"
  else
    plan_step run "keep a pinned copy of this package in $(layout_package_copy), so revoke, rollback, and uninstall need no download" \
      "layout_package_current $copy $(shell_quote "$tag") $(shell_quote "$checksum") $(shell_quote "$ROOT_DIR")" \
      "layout_keep_package $(shell_quote "$ROOT_DIR") $copy" \
      "# copies $LAYOUT_PACKAGE_FILES, and $LAYOUT_PACKAGE_OPTIONAL_FILES when present, into a new folder, then moves it into place"
    plan_undo "remove the pinned copy of this package in $(layout_package_copy), if this package made it" \
      "[ ! -e $copy ]" "layout_remove_package_copy $copy" "rm -rf $copy   # only when it holds $LAYOUT_PACKAGE_MARKER"
  fi
  if layout_launcher_safe; then
    plan_step system "install the launcher $LAYOUT_LAUNCHER, root-owned, mode 0755: the one command that runs the kept copy" \
      "layout_launcher_current $launcher" "layout_install_launcher $launcher"
    plan_undo "remove the launcher $LAYOUT_LAUNCHER" "[ ! -e $launcher ]" "rm -f $launcher"
    plan_note "from now on run every root command through the launcher, not from a folder the agent may have been granted: sudo $LAYOUT_LAUNCHER revoke --all (cut the agent off, keep the records), sudo $LAYOUT_LAUNCHER uninstall, sudo $LAYOUT_LAUNCHER grant rollback. each runs the root-owned copy in $(layout_package_copy)."
  else
    plan_note "the launcher $LAYOUT_LAUNCHER is NOT installed: $(dirname "$LAYOUT_LAUNCHER"), or a folder above it, can be changed by an account other than root, so a launcher there could be replaced and then run as root. nothing was written there. fix who can write it and run this again, or run every root command with the kept copy: $(layout_root_command revoke) (cut the agent off, keep the records), $(layout_root_command uninstall), $(layout_root_command rollback)."
  fi
  plan_note "the folder you unpacked this package in is code the agent can change if you granted it. delete it after the install, or grant a path that does not hold it."
}
