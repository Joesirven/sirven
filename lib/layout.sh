# shellcheck shell=bash
# package directories and file writes. every path goes through rooted so --prefix fakes the root.
#
# every directory and file written here carries an undo, so uninstall.sh can reverse it. the
# state directory comes first: it holds the install record, so every later step can be recorded.
# reads: PREFIX, PACKAGE, CONFIG_DIR, STATE_DIR, STAGE_DIR

# layout_set_directories: the package directories, named after the package.
layout_set_directories() {
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

# layout_remove_directory PATH: remove a directory this package created, but only when it is
# empty. anything else inside was not created by the package, so the directory is kept.
layout_remove_directory() {
  [ -d "$1" ] || return 0
  if rmdir "$1" 2>/dev/null; then
    return 0
  fi
  printf '       kept %s: it holds files this package did not create\n' "$1"
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

plan_layout() {
  local state record simulation
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
  layout_directory "$CONFIG_DIR" 0755 "create the policy directory $CONFIG_DIR"
  layout_directory "$CONFIG_DIR/levels" 0755 "create $CONFIG_DIR/levels for the level in force"
  layout_directory "$CONFIG_DIR/grants" 0755 "create $CONFIG_DIR/grants for grant records"
}
