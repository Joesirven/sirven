# shellcheck shell=bash
# package directories and file writes. every path goes through rooted so --prefix fakes the root.
#
# reads: PREFIX, CONFIG_DIR, STATE_DIR, STAGE_DIR

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

# layout_directory PATH MODE TITLE
layout_directory() {
  local path
  path="$(rooted "$1")"
  plan_step run "$3" "[ -d $path ]" "mkdir -p $path && chmod $2 $path"
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
}

plan_layout() {
  plan_section "package directories"
  plan_note "owned by root. the agent can read its policy but never change it."
  layout_directory "$CONFIG_DIR" 0755 "create the policy directory $CONFIG_DIR"
  layout_directory "$CONFIG_DIR/levels" 0755 "create $CONFIG_DIR/levels for the level in force"
  layout_directory "$CONFIG_DIR/grants" 0755 "create $CONFIG_DIR/grants for grant records"
  layout_directory "$STATE_DIR" 0700 "create the state directory $STATE_DIR"
}
