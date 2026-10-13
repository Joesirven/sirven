// sirven-keep-awake: the command behind `sirven awake`. it records agent work, starts the holder
// process when there is work, and shows what is holding the Mac awake and why.
import Foundation
import SirvenKeepAwake

let usage = """
usage:
  sirven awake begin TASK --reason TEXT --owner PROCESS [--lease SECONDS]
  sirven awake end TASK
  sirven awake run [--task TASK] --reason TEXT -- COMMAND [ARGUMENTS...]
  sirven awake status [--json]
  sirven awake release        release the hold now; the work keeps running
  sirven awake on | off       the keep-awake switch (on by default)
  sirven awake lid on | off   keep awake with the lid closed too (off by default)
  sirven awake helper unregister   remove the privileged helper's registration (reverts lid-closed first)
  sirven awake about

begin records work in flight and holds the Mac awake until end, until the owner process
exits, or until the lease runs out (12 hours by default; begin again to renew). the owner is
the process number of the agent doing the work: a long-lived process, not a shell that exits
right after begin. run wraps one command: work begins when it starts and ends when it exits,
however it exits, and owns the work itself.

\(KeepAwakeIdentity.credit)
"""

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(status)
}

func usageError(_ message: String) -> Never {
    fail("\(message)\nrun sirven awake --help for usage.", status: 64)
}

func say(_ text: String) { print(text) }

let timeFormat: DateFormatter = {
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return format
}()

func elapsed(since date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds) seconds" }
    if seconds < 3600 { return "\(seconds / 60) minutes" }
    return "\(seconds / 3600) hours \((seconds % 3600) / 60) minutes"
}

// MARK: the holder process

let store = KeepAwakeStore()
let client = KeepAwakeClient(store: store)

func executablePath() -> String {
    Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
}

/// start `sirven-keep-awake hold` in its own session, so a control-C aimed at the agent's
/// terminal does not take the holder down with it.
func startHolder() {
    guard !store.holderIsRunning() else { return }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, store.logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    let path = executablePath()
    let arguments = [path, "hold"].map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    var child: pid_t = 0
    let result = posix_spawn(&child, path, &actions, &attributes, arguments, environ)
    if result != 0 { fail("could not start the holder process: \(String(cString: strerror(result)))") }
}

/// wait until the holder reports holding this task, so begin returns only once the Mac is held.
func waitForHold(of task: String, seconds: Double = 5) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        // a holder that saw an empty queue may be exiting just as this work arrived. starting
        // one again does nothing while it runs, and replaces it once it is gone.
        startHolder()
        if store.holderIsRunning(), let state = store.readHolder(), state.heldFor.contains(task) { return true }
        usleep(50_000)
    }
    return false
}

var stopRequested: sig_atomic_t = 0

func hold() -> Never {
    guard let lock = store.acquireHolderLock() else { exit(0) } // another holder is already running
    _ = lock
    let grace = Double(ProcessInfo.processInfo.environment["SIRVEN_KEEP_AWAKE_GRACE"] ?? "") ?? 3
    let holder = KeepAwakeHolder(store: store, helper: ServiceManagementHelper())
    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
        signal(signalNumber) { _ in stopRequested = 1 }
    }
    store.log("holder-started")
    var emptySince: Date?
    while stopRequested == 0 {
        holder.reconcile()
        if holder.liveWork.isEmpty {
            emptySince = emptySince ?? Date()
            if Date().timeIntervalSince(emptySince!) >= grace { break }
        } else {
            emptySince = nil
        }
        usleep(250_000)
    }
    holder.shutdown(why: stopRequested != 0 ? "the holder was asked to stop" : "the work queue drained")
    exit(0)
}

// MARK: commands

func value(after flag: String, in arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < arguments.count else { usageError("\(flag) needs a value") }
    let found = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return found
}

func begin(_ arguments: [String]) {
    var rest = arguments
    let reason = value(after: "--reason", in: &rest) ?? ""
    let owner = value(after: "--owner", in: &rest).map { text -> Int32 in
        guard let number = Int32(text), number > 0 else { usageError("--owner must be a process number") }
        return number
    }
    let lease = value(after: "--lease", in: &rest).map { text -> Double in
        guard let seconds = Double(text), seconds > 0 else { usageError("--lease must be a number of seconds") }
        return seconds
    }
    guard rest.count == 1 else { usageError("begin needs exactly one task name") }
    // no default owner: the process that runs begin is often a shell that exits at once, and
    // work owned by it would be reaped a moment later.
    guard let owner else {
        usageError("begin needs --owner: the process number of the agent doing the work. to hold for one command, use sirven awake run")
    }
    let task = rest[0]
    let item: WorkItem
    do {
        item = try client.begin(task: task, reason: reason, owner: owner,
                                lease: lease ?? KeepAwakeClient.defaultLease)
    } catch {
        usageError("\(error)")
    }
    guard store.readSettings().enabled else {
        say("recorded \(task), but keep-awake is off, so the Mac may sleep. turn it on with: sirven awake on")
        return
    }
    startHolder()
    if waitForHold(of: task) {
        say("holding the Mac awake for \(task): \(item.reason) (until it ends, or owner process \(owner) exits)")
    } else {
        FileHandle.standardError.write(Data("warning: \(task) is recorded, but the holder has not confirmed the hold; see sirven awake status\n".utf8))
    }
}

func end(_ arguments: [String]) {
    guard arguments.count == 1 else { usageError("end needs exactly one task name") }
    guard KeepAwakeStore.validTaskName(arguments[0]) else { usageError("\(KeepAwakeError.badTaskName(arguments[0]))") }
    if client.end(task: arguments[0]) {
        say("ended \(arguments[0]). the hold is released when no other work remains.")
    } else {
        say("no work named \(arguments[0]) was in flight.")
    }
}

var runningChild: pid_t = 0

func run(_ arguments: [String]) -> Never {
    guard let separator = arguments.firstIndex(of: "--") else { usageError("run needs -- before the command") }
    var options = Array(arguments[..<separator])
    let command = Array(arguments[(separator + 1)...])
    guard !command.isEmpty else { usageError("run needs a command after --") }
    let reason = value(after: "--reason", in: &options) ?? ""
    let name = (command[0] as NSString).lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    let task = value(after: "--task", in: &options) ?? "run-\(name.isEmpty ? "command" : name)-\(getpid())"
    guard options.isEmpty else { usageError("unknown run option '\(options[0])'") }
    // this process owns the work: if it is killed outright, the holder notices and lets go.
    begin([task, "--reason", reason, "--owner", String(getpid())])
    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
        signal(signalNumber) { received in if runningChild > 0 { kill(runningChild, received) } }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    do {
        try process.run()
    } catch {
        client.end(task: task)
        fail("could not run \(command[0]): \(error.localizedDescription)", status: 127)
    }
    runningChild = process.processIdentifier
    process.waitUntilExit()
    client.end(task: task)
    exit(process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus)
}

func describeHelper(_ state: HelperState) -> String {
    switch state {
    case .enabled: return "the helper is allowed"
    case .requiresApproval: return "the helper is waiting for you in System Settings, General, Login Items and Extensions"
    case .notRegistered: return "the helper is not registered yet; turning lid-closed on registers it, once"
    case .notFound: return "this copy is not running from the signed sirven app, which carries the helper"
    }
}

func status(_ arguments: [String]) {
    let helper = ServiceManagementHelper()
    let report = client.status(helper: helper, sleepSetting: PmsetSleepSetting())
    if arguments == ["--json"] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! encoder.encode(report), as: UTF8.self))
        return
    }
    guard arguments.isEmpty else { usageError("status takes only --json") }
    say("keep-awake: \(report.enabled ? "on" : "off")")
    say("lid-closed: \(report.lidClosed ? "on" : "off")\(report.lidClosed ? ", \(describeHelper(report.helper ?? .notFound))" : "")")
    if report.holding, let process = report.holderProcess, let since = report.holdingSince {
        say("holding: yes, since \(timeFormat.string(from: since)) (\(elapsed(since: since))), by process \(process), sirven-keep-awake hold")
        if let confirmed = report.systemAssertions.first {
            say("system confirms: process \(process) holds \(confirmed.type) named \"\(confirmed.name)\"")
        } else {
            say("system confirms: nothing. the system lists no sirven assertion for process \(process)")
        }
        if report.lidClosedActive { say("lid-closed: active, the Mac stays awake with the lid closed") }
    } else {
        say("holding: no. the Mac sleeps as it normally would")
    }
    if let problem = report.lidClosedProblem { say("lid-closed problem: \(problem)") }
    switch report.systemSleepDisabled {
    case .some(true): say("system sleep-disabled setting: on (read from pmset now)")
    case .some(false): say("system sleep-disabled setting: off (read from pmset now)")
    case .none: say("system sleep-disabled setting: unknown, pmset did not answer")
    }
    if report.work.isEmpty {
        say("work in flight: none")
    } else {
        say("work in flight (\(report.work.count)):")
        for work in report.work {
            let state = work.holding ? "holding" : work.releasedAt != nil ? "released by you" : "not holding"
            say("  \(work.task)  since \(timeFormat.string(from: work.since))  owner process \(work.ownerProcess)  \(state)")
            say("    \(work.reason)")
        }
    }
    if report.holding { say("release now: \(report.releaseCommand)") }
}

func lid(_ arguments: [String]) {
    switch arguments {
    case ["on"]:
        client.setLidClosed(true)
        // the first action that needs the helper: this is the only place sirven registers it.
        let helper = ServiceManagementHelper()
        var state = helper.state
        if state == .notRegistered || state == .requiresApproval {
            do { state = try helper.register() } catch { say("lid-closed is on, but \(error)") }
        }
        switch state {
        case .enabled:
            say("lid-closed is on: while your agent has work in flight, closing the lid will not put the Mac to sleep.")
        case .requiresApproval:
            say("lid-closed is on. macOS needs your approval for sirven's helper, once: allow it in the System Settings pane that just opened (General, Login Items and Extensions). macOS asks for your fingerprint or password there, in its own prompt. sirven never sees either.")
            ServiceManagementHelper.openApprovalSettings()
        case .notRegistered, .notFound:
            say("lid-closed is on, but \(describeHelper(state)). until then, closing the lid still sleeps the Mac.")
        }
    case ["off"]:
        client.setLidClosed(false)
        say("lid-closed is off: closing the lid sleeps the Mac as usual.")
    default:
        usageError("lid takes on or off")
    }
}

/// remove the helper's registration. the lid-closed setting is reverted first, through the helper
/// itself, so the Mac sleeps as usual afterwards. only the registration this copy of sirven made is touched.
func helperCommand(_ arguments: [String]) {
    guard arguments == ["unregister"] else { usageError("helper takes only unregister") }
    let helper = ServiceManagementHelper()
    // a helper that is not allowed yet cannot be asked to revert; there is nothing on for it to revert.
    if helper.state == .enabled { try? helper.setSleepDisabled(false) }
    do {
        try helper.unregister()
        say("the helper is unregistered. lid-closed operation is off; the Mac sleeps as usual.")
    } catch {
        fail("\(error)")
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "" : arguments.removeFirst()
switch command {
case "begin": begin(arguments)
case "end": end(arguments)
case "run": run(arguments)
case "status": status(arguments)
case "release":
    let released = client.releaseAll()
    say(released.isEmpty ? "nothing was holding the Mac awake." : "released: \(released.joined(separator: ", ")). the work keeps running; the Mac may sleep.")
case "on":
    client.setEnabled(true)
    if !store.workItems().isEmpty { startHolder() }
    say("keep-awake is on: the Mac stays awake while your agent has work in flight.")
case "off": client.setEnabled(false); say("keep-awake is off: the Mac sleeps as usual, even with work in flight.")
case "lid": lid(arguments)
case "helper": helperCommand(arguments)
case "hold": hold()
case "about": say(KeepAwakeIdentity.about)
case "-h", "--help", "help": say(usage)
case "": usageError("a command is needed")
default: usageError("unknown command '\(command)'")
}
