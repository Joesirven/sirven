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

# the pinned copy of this package: the files the installer, the uninstaller, and sirven run from.
# it lives under the state directory, so revoke, rollback, and uninstall work after the
# repository or the download is gone. the marker names the release the copy came from.
LAYOUT_PACKAGE_FILES="install.sh uninstall.sh bin lib levels components project.json"
LAYOUT_PACKAGE_MARKER="PINNED-COPY"

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
  for item in $LAYOUT_PACKAGE_FILES; do
    [ -e "$destination/$item" ] || return 1
    if [ "$tag" = unpinned ]; then
      diff -rq -x __pycache__ "$source/$item" "$destination/$item" >/dev/null 2>&1 || return 1
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
  find "$staging" -name __pycache__ -type d -prune -exec rm -rf {} + || return 1
  chmod -R go-w "$staging" || return 1
  for item in $LAYOUT_PACKAGE_FILES; do
    [ -e "$staging/$item" ] || return 1
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
  local state record simulation copy
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
  copy="$(rooted "$(layout_package_copy)")"
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
      "# copies $LAYOUT_PACKAGE_FILES into a new folder, then moves it into place; a copy of another release is replaced"
    plan_undo "remove the pinned copy of this package in $(layout_package_copy), if this package made it" \
      "[ ! -e $copy ]" "layout_remove_package_copy $copy" "rm -rf $copy   # only when it holds $LAYOUT_PACKAGE_MARKER"
  fi
  plan_note "later, without this repository: sudo bash $(layout_package_copy)/uninstall.sh (revoke by uninstall until the kill switch applies)"
}
