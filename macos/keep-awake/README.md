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
   is on;
5. writes `holder.json`, then exits once the queue has been empty for the grace period
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

## Building and testing

```
make keep-awake          swift build -c release
make test-keep-awake     swift test: the lifecycle against fakes, plus one real assertion
make test                includes tests/unit/test_keep_awake.sh, which runs against the real
                         system when the program is built, and skips otherwise
scripts/build-app.sh     a development Sirven.app with the helper inside, signed ad hoc unless
                         SIRVEN_SIGNING_IDENTITY names a Developer ID certificate
```

The helper is never registered by the build or the tests. Registering it needs the app signed with
a Developer ID certificate, and the release build must add that certificate's team identifier to
`KeepAwakeIdentity.clientRequirement`.
