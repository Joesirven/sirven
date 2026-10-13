import Foundation

/// the holder brings the system in line with the work queue, one pass at a time:
///   1. reap work whose owner process is gone or whose lease ran out, and log why
///   2. hold one power assertion while keep-awake is on and some unreleased work remains
///   3. release it the moment that stops being true, including when the queue drains
///   4. ask the helper for lid-closed operation only while holding and only if the user turned it on
/// it never holds an assertion without work to point to: the assertion's details name every task.
/// on battery below 20 percent it releases the hold, so a bag with the lid closed cannot run the battery flat.
public final class KeepAwakeHolder {
    /// the battery level below which the hold is released while the Mac runs on battery.
    public static let lowBatteryPercent = 20
    /// while lid-closed operation is wanted, the helper is asked again this often (see setLidClosed).
    static let resendInterval: TimeInterval = 15

    private let store: KeepAwakeStore
    private let power: PowerAssertionBackend
    private let liveness: ProcessLiveness
    private let helper: LidClosedHelper?
    private let batteries: PowerSourceBackend
    private let now: () -> Date
    private let process: Int32

    public private(set) var assertion: UInt32?
    public private(set) var holdingSince: Date?
    public private(set) var lidClosedActive = false
    public private(set) var liveWork: [WorkItem] = []
    private var details = ""
    private var lidClosedProblem: String?
    private var lastAsked: Date?

    public init(store: KeepAwakeStore, power: PowerAssertionBackend = SystemPowerAssertions(),
                liveness: ProcessLiveness = KernelProcessLiveness(), helper: LidClosedHelper? = nil,
                batteries: PowerSourceBackend = SystemPowerSource(),
                now: @escaping () -> Date = Date.init, process: Int32 = getpid()) {
        self.store = store
        self.power = power
        self.liveness = liveness
        self.helper = helper
        self.batteries = batteries
        self.now = now
        self.process = process
    }

    /// why a piece of work no longer counts, or nil while it still does.
    public static func endReason(of item: WorkItem, at time: Date, liveness: ProcessLiveness) -> String? {
        if time >= item.expires { return "its lease ran out" }
        guard let started = liveness.startTime(of: item.ownerProcess) else {
            return "its owner process \(item.ownerProcess) is no longer running"
        }
        if let expected = item.ownerStartedAt, abs(started - expected) > 1 {
            return "process number \(item.ownerProcess) now belongs to a different process"
        }
        return nil
    }

    static func describe(_ work: [WorkItem]) -> String {
        work.map { "\($0.task): \($0.reason)" }.joined(separator: "; ")
    }

    @discardableResult
    public func reconcile() -> HolderState {
        let time = now()
        let settings = store.readSettings()
        var live: [WorkItem] = []
        for item in store.workItems() {
            if let why = Self.endReason(of: item, at: time, liveness: liveness) {
                store.remove(task: item.task)
                store.log("reaped", ["task": item.task, "reason": item.reason, "why": why])
            } else {
                live.append(item)
            }
        }
        liveWork = live
        let battery = batteries.current()
        // a battery whose level cannot be read is not treated as low: the limit applies only to a known level.
        let lowBattery = battery.onBattery && (battery.percent ?? Self.lowBatteryPercent) < Self.lowBatteryPercent
        let unreleased = live.filter { $0.releasedAt == nil }
        let held = settings.enabled && !lowBattery ? unreleased : []

        if held.isEmpty {
            let why: String
            if live.isEmpty {
                why = "the work queue drained"
            } else if !settings.enabled {
                why = "the user turned keep-awake off"
            } else if lowBattery && !unreleased.isEmpty {
                why = "the Mac is on battery at \(battery.percent ?? 0) percent, below \(Self.lowBatteryPercent) percent"
            } else {
                why = "the user released the hold"
            }
            releaseAssertion(why: why)
        } else {
            let wanted = Self.describe(held)
            if let assertion {
                if wanted != details {
                    power.update(assertion, details: wanted)
                    details = wanted
                }
            } else {
                do {
                    assertion = try power.create(name: KeepAwakeIdentity.assertionName, details: wanted)
                    holdingSince = time
                    details = wanted
                    store.log("asserted", ["tasks": held.map(\.task).joined(separator: ","), "details": wanted])
                } catch {
                    store.log("assert-failed", ["error": "\(error)"])
                }
            }
        }

        setLidClosed(assertion != nil && settings.lidClosed)

        let state = HolderState(process: process, holding: assertion != nil, holdingSince: holdingSince,
                                assertionName: assertion == nil ? nil : KeepAwakeIdentity.assertionName,
                                heldFor: assertion == nil ? [] : held.map(\.task),
                                lidClosedActive: lidClosedActive, lidClosedProblem: lidClosedProblem,
                                updated: time)
        store.writeHolder(state)
        return state
    }

    private func releaseAssertion(why: String) {
        guard let assertion else { return }
        power.release(assertion)
        self.assertion = nil
        holdingSince = nil
        details = ""
        store.log("released", ["why": why])
    }

    private func setLidClosed(_ wanted: Bool) {
        if !wanted { lidClosedProblem = nil }
        let time = now()
        // while it is wanted, ask again every resendInterval: the helper forgets a connection that
        // dropped, and a helper restarted by launchd starts with the setting reverted.
        let due = lastAsked.map { time.timeIntervalSince($0) >= Self.resendInterval } ?? true
        guard wanted != lidClosedActive || (wanted && due) else { return }
        guard let helper else {
            if wanted { lidClosedProblem = "lid-closed operation needs the helper, which ships in the signed sirven app" }
            return
        }
        do {
            try helper.setSleepDisabled(wanted)
            if wanted != lidClosedActive { store.log(wanted ? "lid-closed-on" : "lid-closed-off") }
            lidClosedActive = wanted
            lastAsked = time
            lidClosedProblem = nil
        } catch {
            lidClosedProblem = "\(error)"
            // when the helper refuses, the state is false, and the next pass asks again.
            lidClosedActive = false
            lastAsked = nil
            store.log("lid-closed-failed", ["error": "\(error)"])
        }
    }

    /// release everything and remove the holder record. called when the queue has drained for the
    /// grace period, and on a termination signal.
    public func shutdown(why: String) {
        releaseAssertion(why: why)
        setLidClosed(false)
        store.clearHolder()
        store.log("holder-stopped", ["why": why])
    }
}
