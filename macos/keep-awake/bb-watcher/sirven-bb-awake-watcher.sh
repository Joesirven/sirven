#!/usr/bin/env bash
# sirven-bb-awake-watcher: keeps this Mac awake while bb has agent work on it, and only then.
#
# every 30 seconds it asks bb whether any thread on this machine is active or starting, or is
# running a bb workflow, a background agent, or a background command (an idle thread can still be
# running a workflow). bb workflows list only answers inside a project thread, so workflows are
# read from each thread's activity counts instead. while there is, it holds the keep-awake task "bb-agents"; once there has
# been none for 5 minutes, it ends the task and the Mac sleeps as usual.
#
# it runs as one long-lived process under launchd (see install.sh) and owns the work itself: the
# work is begun with --owner set to this process and a 300 second lease renewed every 90 seconds, so if
# this watcher dies or hangs, the holder lets go on its own.
#
# a failed bb query counts toward the idle window, so an unreachable bb server cannot hold the Mac
# awake forever. if the user releases the hold (sirven awake release), the watcher does not take it
# back until bb has gone idle once.
#
# settings, all optional, mostly for testing:
#   SIRVEN_BB_HOST          the bb host to watch (default host_na8kye9eas, Jose's MacBook Pro)
#   SIRVEN_BB_COMMAND       the bb command (default: bb)
#   SIRVEN_KEEP_AWAKE_BIN   the keep-awake program (default: the one inside ~/Applications/Sirven.app)
#   SIRVEN_BB_INTERVAL      seconds between checks (default 30)
#   SIRVEN_BB_IDLE          seconds with nothing active before release (default 300)
#   SIRVEN_BB_LEASE         lease on the work, in seconds (default 300)
#   SIRVEN_BB_RENEW         renew the lease after this many seconds (default 90)
#   SIRVEN_BB_TIMEOUT       give up on one bb query after this many seconds (default 60)
#   SIRVEN_BB_ONCE          1: check once, act, and exit (no hold survives the exit)
set -uo pipefail

HOST="${SIRVEN_BB_HOST:-host_na8kye9eas}"
BB="${SIRVEN_BB_COMMAND:-bb}"
AWAKE="${SIRVEN_KEEP_AWAKE_BIN:-$HOME/Applications/Sirven.app/Contents/MacOS/sirven-keep-awake}"
INTERVAL="${SIRVEN_BB_INTERVAL:-30}"
IDLE="${SIRVEN_BB_IDLE:-300}"
LEASE="${SIRVEN_BB_LEASE:-300}"
RENEW="${SIRVEN_BB_RENEW:-90}"
QUERY_TIMEOUT="${SIRVEN_BB_TIMEOUT:-60}"
TASK="bb-agents"
EVENTS="${SIRVEN_KEEP_AWAKE_DIR:-$HOME/Library/Application Support/sirven/keep-awake}/events.jsonl"

# one line in the keep-awake events file, in the same shape the keep-awake program writes.
log_event() {
  local event="$1" detail="${2:-}"
  mkdir -p "$(dirname "$EVENTS")"
  /usr/bin/python3 -c '
import json, sys, datetime
record = {"event": sys.argv[1], "process": sys.argv[2], "source": "bb-watcher",
          "time": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
if sys.argv[3]: record["detail"] = sys.argv[3]
print(json.dumps(record, sort_keys=True))' "$event" "$$" "$detail" >>"$EVENTS"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $event${detail:+: $detail}"
}

# prints "<busy threads> <workflows>" for this machine, or "error <why>" when bb cannot be asked.
# the thread list goes through a file, not the environment, which has a size limit; stderr is kept
# apart so a warning from node cannot spoil the JSON. a hung bb is killed after QUERY_TIMEOUT.
count_work() {
  local out err pid waited=0 status
  out="$(mktemp -t sirven-bb-threads)"; err="$(mktemp -t sirven-bb-errors)"
  "$BB" thread list --json >"$out" 2>"$err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge $((QUERY_TIMEOUT * 5)) ]; then
      kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
      echo "error bb thread list did not answer within ${QUERY_TIMEOUT}s"; rm -f "$out" "$err"; return
    fi
    sleep 0.2; waited=$((waited + 1))
  done
  wait "$pid"; status=$?
  if [ "$status" != 0 ]; then
    echo "error bb thread list failed with status $status: $(head -c 200 "$err" | tr '\n' ' ')"; rm -f "$out" "$err"; return
  fi
  /usr/bin/python3 -c '
import json, sys
try:
    threads = json.load(open(sys.argv[2]))
    assert isinstance(threads, list)
except (ValueError, AssertionError):
    print("error bb did not answer with a JSON list of threads"); sys.exit()
busy = ("active", "starting", "running")
def state(item, *keys):
    value = item
    for key in keys:
        value = value.get(key) if isinstance(value, dict) else None
    return str(value or "").lower()
def count(thread, key):
    try: return int((thread.get("activity") or {}).get(key) or 0)
    except (TypeError, ValueError): return 0
mine = [t for t in threads if isinstance(t, dict) and t.get("environmentHostId") == sys.argv[1]]
active = [t for t in mine if state(t, "status") in busy or state(t, "runtime", "displayStatus") in busy
          or count(t, "activeBackgroundAgentCount") or count(t, "activeBackgroundCommandCount")
          or count(t, "activeWorkflowCount")]
print(len(active), sum(count(t, "activeWorkflowCount") for t in mine))' "$HOST" "$out" || echo "error the thread list could not be read"
  rm -f "$out" "$err"
}

# true when the user released the bb-agents hold (sirven awake release) and it is still listed.
released_by_user() {
  "$AWAKE" status --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try: report = json.load(sys.stdin)
except ValueError: sys.exit(1)
sys.exit(0 if any(w.get("task") == sys.argv[1] and w.get("releasedAt") for w in report.get("work", [])) else 1)' "$TASK"
}

holding=0          # 1 while this watcher has begun the task and not ended it
user_released=0    # 1 after the user released the hold, until bb goes idle
idle_since=""      # when bb was last seen busy-free (or unreachable), empty while busy
last_renew=0
last_reason=""

begin_work() {
  local reason="$1" output
  if output="$("$AWAKE" begin "$TASK" --reason "$reason" --owner $$ --lease "$LEASE" 2>&1)"; then
    [ "$holding" = 1 ] && [ "$reason" = "$last_reason" ] || log_event bb-watcher-hold "$reason"
    # renewals are timed from the start of the pass, so a slow bb query cannot stretch the gap.
    holding=1; last_renew=$now; last_reason="$reason"
  else
    log_event bb-watcher-begin-failed "$output"
  fi
}

end_work() {
  local why="$1"
  "$AWAKE" end "$TASK" >/dev/null 2>&1
  log_event bb-watcher-release "$why"
  holding=0; last_reason=""
}

trap 'log_event bb-watcher-stopped "the watcher was asked to stop"; [ "$holding" = 1 ] && "$AWAKE" end "$TASK" >/dev/null 2>&1; exit 0' TERM INT HUP

log_event bb-watcher-started "watching $HOST every ${INTERVAL}s, release after ${IDLE}s idle"
while true; do
  now=$(date +%s)
  result="$(count_work)"
  if [ -z "$result" ]; then
    threads=0; workflows=0; problem="the thread count came back empty"
  elif [ "${result%% *}" = error ]; then
    threads=0; workflows=0; problem="${result#error }"
  else
    read -r threads workflows <<<"$result"; problem=""
  fi

  if [ -z "$problem" ] && [ $((threads + workflows)) -gt 0 ]; then
    idle_since=""
    reason="$threads bb threads active"
    [ "$workflows" -gt 0 ] && reason="$reason, $workflows bb workflows running"
    if [ "$holding" = 1 ] && released_by_user; then
      [ "$user_released" = 1 ] || log_event bb-watcher-respecting-release "the hold was released by the user; not renewing until bb goes idle"
      user_released=1
    elif [ "$user_released" = 0 ] && { [ "$holding" = 0 ] || [ "$reason" != "$last_reason" ] || [ $((now - last_renew)) -ge "$RENEW" ]; }; then
      begin_work "$reason"
    fi
  else
    if [ -z "$idle_since" ]; then
      idle_since=$now
      [ "$holding" = 1 ] && log_event bb-watcher-idle "${problem:-no bb threads active on this machine and no bb workflows running}; releasing in ${IDLE}s unless work returns"
    elif [ -n "$problem" ]; then
      log_event bb-watcher-query-failed "$problem"
    fi
    if [ $((now - idle_since)) -ge "$IDLE" ]; then
      [ "$holding" = 1 ] && end_work "nothing active for ${IDLE}s"
      user_released=0
    elif [ "$holding" = 1 ] && [ "$user_released" = 0 ] && [ $((now - last_renew)) -ge "$RENEW" ]; then
      # keep the hold through the idle window (the reason is unchanged, so this logs nothing),
      # unless the user released it meanwhile: begin would take the release back.
      if released_by_user; then
        log_event bb-watcher-respecting-release "the hold was released by the user during the idle window"
        user_released=1
      else
        begin_work "$last_reason"
      fi
    fi
  fi

  if [ "${SIRVEN_BB_ONCE:-0}" = 1 ]; then
    [ "$holding" = 1 ] && "$AWAKE" end "$TASK" >/dev/null 2>&1
    exit 0
  fi
  sleep "$INTERVAL" &
  wait $!
done
