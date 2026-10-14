# keep-awake, for developers

The program behind `sirven awake`, and the library the menu bar app links. For what it does and
the helper's one-time approval, read the "Keep my Mac awake for my agent" section of the
[top-level README](../../README.md). Inspired by Sleepless by itskoosh (MIT).

## Layout

```
Package.swift
Sources/SirvenKeepAwake/          the library
  Identity.swift                  names, bundle identifiers, the credit line
  Store.swift                     the state files, one folder per user
  System.swift                    IOKit power assertions and kernel process lookups
  Holder.swift                    the reconcile pass: work queue in, one assertion out
  Client.swift                    begin, end, release, the switches, and status
  Helper.swift                    the helper's XPC protocol and its SMAppService registration
Sources/sirven-keep-awake/        the command (and, as `sirven-keep-awake hold`, the holder process)
Sources/sirven-keep-awake-helper/ the privileged helper, run by launchd after the user allows it
Support/                          the app bundle's Info.plist and the helper's launchd plist
scripts/build-app.sh              a development app bundle laid out the way SMAppService expects
Tests/                            the lifecycle against fakes, and one real assertion
```

## How it works

A power assertion belongs to the process that created it, and the system releases it when that
process exits. So the assertion lives in a small holder process (`sirven-keep-awake hold`),
started on demand by `begin` in its own session, and only one runs at a time (it holds a lock on
`holder.lock`). Every quarter second the holder:

1. reaps work whose owner process exited (or whose process number now belongs to a different
   process) or whose lease ran out, and logs why;
2. holds one `PreventUserIdleSystemSleep` assertion while keep-awake is on and some work is live
   and not released by the user, with the task names and reasons in the assertion's details;
3. releases it as soon as that stops being true;
4. asks the helper for lid-closed operation only while holding and only when the user's setting
   is on, and asks again every 15 seconds while it is wanted, because a helper that restarted has
   forgotten the request;
5. releases the hold while the Mac runs on battery below 20 percent, and holds again when it is on
   the charger. A Mac with no battery counts as plugged in, and a battery level that cannot be read
   does not trigger the release;
6. writes `holder.json`, then exits once the queue has been empty for the grace period
   (3 seconds; `SIRVEN_KEEP_AWAKE_GRACE` changes it).

State lives in `~/Library/Application Support/sirven/keep-awake` (`SIRVEN_KEEP_AWAKE_DIR`
changes it): `settings.json`, `work/<task>.json`, `holder.json`, `holder.lock`, and
`events.jsonl`, which records every begin, end, assert, release, and reap with the reason.

## For the agent runtime

Until the runtime has its own work queue, these are the integration points:

- `sirven awake run --task TASK --reason TEXT -- COMMAND` wraps one command end to end, and owns
  the work itself. Prefer it whenever the work is one command.
- `sirven awake begin TASK --reason TEXT --owner PROCESS [--lease SECONDS]` when a task starts.
  `--owner` is required: it is the process number of the agent doing the work, a long-lived
  process. There is no default, because an agent's shell tool runs each command in a shell that
  exits at once, and work owned by that shell would be reaped a moment later. `begin` returns
  once the holder confirms the hold. Beginning the same task again renews its lease.
- `sirven awake end TASK` when it finishes.
- From Swift: `KeepAwakeClient().begin(task:reason:owner:lease:)` and `end(task:)`. The library
  does not start the holder; run `sirven-keep-awake hold` (or call `begin` through the command).

## For the menu bar app: the status surface

`sirven awake status --json`, or `KeepAwakeClient().status(helper: ServiceManagementHelper())`,
returns:

```json
{
  "enabled": true,
  "lidClosed": false,
  "helper": "notRegistered",
  "holderRunning": true,
  "holding": true,
  "holderProcess": 67801,
  "holdingSince": "2026-10-12T00:10:42Z",
  "lidClosedActive": false,
  "systemAssertions": [
    { "process": 67801, "type": "PreventUserIdleSystemSleep",
      "name": "sirven keep-awake: your agent has work in flight",
      "details": "inbox-summary: summarize the inbox" }
  ],
  "work": [
    { "task": "inbox-summary", "reason": "summarize the inbox",
      "since": "2026-10-12T00:10:42Z", "ownerProcess": 66861,
      "expires": "2026-10-12T12:10:42Z", "holding": true }
  ],
  "releaseCommand": "sirven awake release",
  "credit": "Inspired by Sleepless by itskoosh (MIT)."
}
```

`helper` is one of `notRegistered`, `requiresApproval`, `enabled`, or `notFound` (this copy is not
running from an app bundle that carries the helper). `lidClosedProblem` appears when lid-closed
operation is on but cannot act, and says why. `systemAssertions` is read from macOS, not from
sirven's files; show it as the proof.

The one-click release is `KeepAwakeClient().releaseAll()` (or `sirven awake release`). The on and
off switch is `setEnabled(_:)`, and the lid-closed switch is `setLidClosed(_:)` followed, the
first time, by `ServiceManagementHelper().register()` and
`ServiceManagementHelper.openApprovalSettings()`. Show the credit line on the about surface:
`KeepAwakeIdentity.credit`.

## The lid-closed helper

The helper is the only part that runs as root, and it changes one system setting, the sleep-disabled
setting that `pmset -a disablesleep` controls. Its rules live in the library (`HelperCore.swift`,
`SleepSetting.swift`) so the tests run them without root.

- It asks the system for the setting, not its own record of it. While a holder asks, it checks the
  setting every 15 seconds and asserts it again if something cleared it. The policy: during a hold,
  the setting belongs to sirven. If you clear it on purpose mid-hold, it comes back within 15
  seconds. To get out, run `sirven awake release` or `sirven awake lid off`, which reverts it.
- It writes its marker before it runs `pmset`, so a crash between the two still reverts. The marker
  is what lets it put back only what sirven turned on. A setting that was already on before any hold
  is never touched.
- It reverts at every boot (`RunAtLoad`) and whenever it is stopped, and launchd restarts it if it is
  killed (`KeepAlive`), so a crash or a power loss mid-hold cannot leave the setting on for long.
- It accepts a connection only from the sirven app, signed by the team identifier built into the
  helper at build time. With no team identifier built in, it refuses every connection. Nothing
  personal is written into the source.
- `sirven awake status` reads the setting from `pmset`, which needs no privileges, and shows it next
  to what sirven believes. It reports the setting whoever set it. So it can read "on" while
  lid-closed operation is off, when you set `pmset -a disablesleep 1` yourself; sirven then leaves
  it alone, because it has no marker for it.

## The bb watcher

`bb-watcher/` holds the Mac awake while bb has agent work on it, with no change to bb itself.
`bb-watcher/install.sh` installs it as a user LaunchAgent (`xyz.sirven.keep-awake-bb-watcher`,
no administrator rights) that copies the watcher to `~/Library/Application Support/sirven/bb-watcher`
and runs it from there. Every 30 seconds it runs `bb thread list --json` and counts the threads on
the bb host of this Mac that are active or starting, or that have a workflow, background agent, or
background command running. (`bb workflows list` only answers inside a project thread, so workflows
are read from each thread's activity counts.) While the count is above zero it holds the task
`bb-agents`; after 5 minutes at zero it ends it.

The installer finds the bb host id from `bb status` when it runs inside a bb thread on this Mac, or
takes `SIRVEN_BB_HOST` from the environment. It refuses to install without one, and it checks every
prerequisite before it stops the running agent.

The watcher owns the work (`--owner` is its own process) with a 300 second lease renewed every 90
seconds, so if it dies or hangs the holder lets go by itself. A failed bb query counts toward the 5
idle minutes. After `sirven awake release` it does not take the hold back until bb has gone idle
once.

Ceiling: one continuous hold never runs longer than 12 hours (`SIRVEN_BB_MAX_HOLD`, in seconds),
whatever bb reports. At the ceiling the watcher releases the hold and logs `bb-watcher-max-hold`. It
holds again only after bb has been idle for the idle window. A thread stuck in an active state
therefore holds the Mac for at most 12 hours, then stops.

It calls the program inside `~/Applications/Sirven.app` directly, because only that copy can reach
the lid-closed helper. Its decisions go to `events.jsonl` (with `"source": "bb-watcher"`) and to
`watcher.log` next to it. The plist is readable only by you.

Remove it with `bb-watcher/install.sh remove`. It stops the agent, deletes the plist, the copied
watcher and its log, and asks the helper to unregister.

If you still have the older blanket agent `xyz.sirven.bb-keep-awake`, remove it: it runs
`/usr/bin/caffeinate -ims` with KeepAlive, so the Mac never sleeps whatever bb is doing, which
defeats the 12-hour ceiling and the battery release. Its plist is
`~/Library/LaunchAgents/xyz.sirven.bb-keep-awake.plist`. Stop it with
`launchctl bootout gui/$(id -u)/xyz.sirven.bb-keep-awake`, then delete that plist.

### Removing everything

1. `macos/keep-awake/bb-watcher/install.sh remove`
2. If lid-closed operation was ever on, run `~/Applications/Sirven.app/Contents/MacOS/sirven-keep-awake helper unregister`.
   It reverts the setting, then removes the helper's registration.
3. Only if `pmset -g` still shows `SleepDisabled 1` after step 2, run these two commands yourself
   (they need your administrator password): `sudo pmset -a disablesleep 0`, then
   `sudo rm -f "/Library/Application Support/sirven/keep-awake-helper/sleep-disabled-by-sirven"`.
4. Delete `~/Applications/Sirven.app`, and `~/Library/Application Support/sirven/keep-awake` if you
   want the work records and the event log gone too.

## Building and testing

```
make keep-awake          swift build -c release
make test-keep-awake     swift test: the lifecycle against fakes, plus one real assertion
make test                includes tests/unit/test_keep_awake.sh, which runs against the real
                         system when the program is built, and skips otherwise; and
                         tests/unit/test_keep_awake_watcher.sh, which runs the watcher against fakes
SIRVEN_TEAM_IDENTIFIER=<team> SIRVEN_SIGNING_IDENTITY="<certificate>" scripts/build-app.sh
                         a Sirven.app with the helper inside, signed with that certificate
```

Both variables are required. The build refuses without them, and it refuses ad hoc signing, which has
no team and so could never register the helper. `SIRVEN_TEAM_IDENTIFIER` is the ten-character
identifier in the parentheses of `security find-identity -v -p codesigning`. The build writes it into
the helper's executable only, not into the source.

The helper is never registered by the build or the tests. Registering it needs the signed app.
