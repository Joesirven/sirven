# shellcheck shell=bash
# one installer run at a time. install, uninstall, grant rollback and grant repair take an exclusive lock on the
# state directory itself (a lock on its descriptor, so no file is left behind for uninstall to find). the
# kill switch waits a short, bounded time and then goes on whatever happens: the emergency command must never
# be blocked by a hung install, and its steps are written to be safe next to another run.
# the lock needs flock (util-linux); where there is none (macos, which applies nothing yet) there is no lock.
# reads: PREFIX, STATE_DIR

LOCK_DESCRIPTOR=8

# lock_take SECONDS refuse|go_on: wait up to SECONDS for the lock. refuse stops the run (exit 75); go_on warns.
# nothing is locked before the state directory exists, which is the first thing the first install makes.
lock_take() {
  local seconds="$1" mode="$2" directory="${PREFIX}${STATE_DIR}"
  command -v flock >/dev/null 2>&1 || return 0
  [ -d "$directory" ] && [ -r "$directory" ] || return 0
  exec 8< "$directory"
  if flock -w "$seconds" "$LOCK_DESCRIPTOR"; then
    return 0
  fi
  if [ "$mode" = refuse ]; then
    DIE_STATUS=75 die "another run of this installer holds the lock on $directory, and it did not finish in $seconds seconds. wait for it, or find it with: ps aux | grep -e install.sh -e uninstall.sh -e sirven. nothing was changed."
  fi
  warn "another run holds the lock on $directory and did not finish in $seconds seconds; going on, because this command must not wait."
}
