import Foundation

/// everything the status surface shows, in one JSON shape. the menu bar app reads this and binds
/// its release button to `KeepAwakeClient.releaseAll()` (or runs `sirven awake release`).
public struct KeepAwakeStatus: Codable {
    public struct Work: Codable {
        public var task: String
        public var reason: String
        public var since: Date
        public var ownerProcess: Int32
        public var expires: Date
        public var holding: Bool
        public var releasedAt: Date?
    }

    public var enabled: Bool
    public var lidClosed: Bool
    public var helper: HelperState?
    /// a holder process is running right now.
    public var holderRunning: Bool
    /// the holder says it holds an assertion.
    public var holding: Bool
    public var holderProcess: Int32?
    public var holdingSince: Date?
    public var lidClosedActive: Bool
    public var lidClosedProblem: String?
    /// what the system itself lists for the holder process: the check that the claim is true.
    public var systemAssertions: [SystemAssertion]
    public var work: [Work]
    public var releaseCommand: String
    public var credit: String
}

public final class KeepAwakeClient {
    public let store: KeepAwakeStore
    private let liveness: ProcessLiveness
    private let now: () -> Date

    public static let defaultLease: TimeInterval = 12 * 60 * 60

    public init(store: KeepAwakeStore = KeepAwakeStore(), liveness: ProcessLiveness = KernelProcessLiveness(),
                now: @escaping () -> Date = Date.init) {
        self.store = store
        self.liveness = liveness
        self.now = now
    }

    /// record work in flight. beginning a task that already exists renews its lease and reason,
    /// and clears an earlier release, since the agent has said it is working again.
    @discardableResult
    public func begin(task: String, reason: String, owner: Int32, lease: TimeInterval = defaultLease) throws -> WorkItem {
        guard KeepAwakeStore.validTaskName(task) else { throw KeepAwakeError.badTaskName(task) }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw KeepAwakeError.badReason }
        let time = now()
        let existing = store.workItem(task)
        let item = WorkItem(task: task, reason: reason, since: existing?.since ?? time, ownerProcess: owner,
                            ownerStartedAt: liveness.startTime(of: owner), expires: time.addingTimeInterval(lease))
        store.write(item)
        store.log(existing == nil ? "began" : "renewed", ["task": task, "reason": reason, "owner": String(owner)])
        return item
    }

    /// the work is done. returns false when there was no such task.
    @discardableResult
    public func end(task: String) -> Bool {
        let removed = store.remove(task: task)
        if removed { store.log("ended", ["task": task]) }
        return removed
    }

    /// the one-click release: the Mac may sleep now. the work stays listed so the user can see
    /// what is still running; new work begun after this holds the Mac awake again.
    @discardableResult
    public func releaseAll() -> [String] {
        let time = now()
        var released: [String] = []
        for var item in store.workItems() where item.releasedAt == nil {
            item.releasedAt = time
            store.write(item)
            released.append(item.task)
        }
        store.log("user-released", ["tasks": released.joined(separator: ",")])
        return released
    }

    public func setEnabled(_ enabled: Bool) {
        var settings = store.readSettings()
        settings.enabled = enabled
        store.writeSettings(settings)
        store.log(enabled ? "turned-on" : "turned-off")
    }

    public func setLidClosed(_ lidClosed: Bool) {
        var settings = store.readSettings()
        settings.lidClosed = lidClosed
        store.writeSettings(settings)
        store.log(lidClosed ? "lid-closed-setting-on" : "lid-closed-setting-off")
    }

    public func status(helper: LidClosedHelper? = nil) -> KeepAwakeStatus {
        let settings = store.readSettings()
        let running = store.holderIsRunning()
        // a holder record left by a process that is gone says nothing about now.
        let holder = running ? store.readHolder() : nil
        let held = Set(holder?.heldFor ?? [])
        let work = store.workItems().map {
            KeepAwakeStatus.Work(task: $0.task, reason: $0.reason, since: $0.since, ownerProcess: $0.ownerProcess,
                                 expires: $0.expires, holding: held.contains($0.task), releasedAt: $0.releasedAt)
        }
        let system = holder.map { state in
            SystemAssertionReport.assertions(of: state.process).filter { $0.name == KeepAwakeIdentity.assertionName }
        } ?? []
        return KeepAwakeStatus(enabled: settings.enabled, lidClosed: settings.lidClosed, helper: helper?.state,
                               holderRunning: running, holding: holder?.holding ?? false,
                               holderProcess: holder?.process, holdingSince: holder?.holdingSince,
                               lidClosedActive: holder?.lidClosedActive ?? false,
                               lidClosedProblem: holder?.lidClosedProblem, systemAssertions: system, work: work,
                               releaseCommand: KeepAwakeIdentity.releaseCommand, credit: KeepAwakeIdentity.credit)
    }
}
