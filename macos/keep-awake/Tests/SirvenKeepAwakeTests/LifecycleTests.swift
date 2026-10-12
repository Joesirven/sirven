import Foundation
import XCTest
@testable import SirvenKeepAwake

// the assertion lifecycle against fakes: no real assertion is held and no setting is changed.

final class FakePower: PowerAssertionBackend {
    var next: UInt32 = 1
    var active: [UInt32: String] = [:]
    var created = 0
    var fail = false

    func create(name: String, details: String) throws -> UInt32 {
        if fail { throw KeepAwakeError.assertionFailed(-1) }
        defer { next += 1 }
        active[next] = details
        created += 1
        return next
    }
    func update(_ assertion: UInt32, details: String) { active[assertion] = details }
    func release(_ assertion: UInt32) { active[assertion] = nil }
}

final class FakeProcesses: ProcessLiveness {
    var started: [Int32: Double] = [:]
    func startTime(of process: Int32) -> Double? { started[process] }
}

final class FakeHelper: LidClosedHelper {
    var state: HelperState = .enabled
    var sleepDisabled = false
    var calls: [Bool] = []
    var registered = 0
    var fail = false
    func register() throws -> HelperState { registered += 1; return state }
    func setSleepDisabled(_ disabled: Bool) throws {
        calls.append(disabled)
        if fail { throw KeepAwakeError.helper("refused") }
        sleepDisabled = disabled
    }
}

final class LifecycleTests: XCTestCase {
    var directory: URL!
    var store: KeepAwakeStore!
    var power: FakePower!
    var processes: FakeProcesses!
    var helper: FakeHelper!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var client: KeepAwakeClient!
    var holder: KeepAwakeHolder!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keep-awake-\(UUID().uuidString)")
        store = KeepAwakeStore(directory: directory)
        power = FakePower()
        processes = FakeProcesses()
        processes.started = [100: 1.0, 200: 2.0]
        helper = FakeHelper()
        client = KeepAwakeClient(store: store, liveness: processes, now: { [unowned self] in self.clock })
        holder = KeepAwakeHolder(store: store, power: power, liveness: processes, helper: helper,
                                 now: { [unowned self] in self.clock }, process: 4242)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func events() -> [String] {
        let text = (try? String(contentsOf: store.eventsFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String]
        }.compactMap { $0["event"] }
    }

    func testNoWorkNoAssertion() {
        let state = holder.reconcile()
        XCTAssertFalse(state.holding)
        XCTAssertTrue(power.active.isEmpty)
        XCTAssertEqual(power.created, 0)
    }

    func testBeginAssertsAndNamesTheWork() throws {
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        let state = holder.reconcile()
        XCTAssertTrue(state.holding)
        XCTAssertEqual(state.heldFor, ["inbox"])
        XCTAssertEqual(state.assertionName, KeepAwakeIdentity.assertionName)
        XCTAssertEqual(state.holdingSince, clock)
        XCTAssertEqual(Array(power.active.values), ["inbox: summarize the inbox"])
        XCTAssertEqual(store.readHolder(), state)
    }

    func testOverlappingWorkSharesOneAssertionAndTheLastEndReleases() throws {
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        holder.reconcile()
        clock += 10
        try client.begin(task: "barber", reason: "book a haircut", owner: 200)
        holder.reconcile()
        XCTAssertEqual(power.created, 1)
        XCTAssertEqual(power.active.count, 1)
        XCTAssertEqual(power.active.values.first, "inbox: summarize the inbox; barber: book a haircut")

        client.end(task: "inbox")
        var state = holder.reconcile()
        XCTAssertTrue(state.holding)
        XCTAssertEqual(state.heldFor, ["barber"])
        XCTAssertEqual(power.active.values.first, "barber: book a haircut")

        client.end(task: "barber")
        state = holder.reconcile()
        XCTAssertFalse(state.holding, "the queue drained, so the hold is released")
        XCTAssertTrue(power.active.isEmpty)
        XCTAssertEqual(events().filter { $0 == "released" }.count, 1)
    }

    func testOneClickReleaseLetsTheMacSleepAndKeepsTheWorkListed() throws {
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        holder.reconcile()
        XCTAssertEqual(client.releaseAll(), ["inbox"])
        let state = holder.reconcile()
        XCTAssertFalse(state.holding)
        XCTAssertTrue(power.active.isEmpty)
        XCTAssertEqual(store.workItems().map(\.task), ["inbox"])
        XCTAssertNotNil(store.workItems().first?.releasedAt)

        // new work after a release holds again; the released work does not.
        try client.begin(task: "barber", reason: "book a haircut", owner: 200)
        XCTAssertEqual(holder.reconcile().heldFor, ["barber"])
        // beginning released work again means the agent is working on it again.
        try client.begin(task: "inbox", reason: "summarize the inbox, part two", owner: 100)
        XCTAssertEqual(holder.reconcile().heldFor.sorted(), ["barber", "inbox"])
    }

    func testOffBlocksTheAssertionAndOnResumesIt() throws {
        client.setEnabled(false)
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        XCTAssertFalse(holder.reconcile().holding)
        XCTAssertEqual(power.created, 0)
        client.setEnabled(true)
        XCTAssertTrue(holder.reconcile().holding)
        client.setEnabled(false)
        XCTAssertFalse(holder.reconcile().holding)
        XCTAssertTrue(power.active.isEmpty)
    }

    func testWorkWhoseOwnerExitedIsReapedAndReleased() throws {
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        XCTAssertTrue(holder.reconcile().holding)
        processes.started[100] = nil
        XCTAssertFalse(holder.reconcile().holding)
        XCTAssertTrue(store.workItems().isEmpty)
        XCTAssertTrue(events().contains("reaped"))
    }

    func testAReusedProcessNumberDoesNotKeepWorkAlive() throws {
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        XCTAssertTrue(holder.reconcile().holding)
        processes.started[100] = 999.0 // same number, a different process
        XCTAssertFalse(holder.reconcile().holding)
        XCTAssertTrue(store.workItems().isEmpty)
    }

    func testTheLeaseRunsOutAndBeginningAgainRenewsIt() throws {
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100, lease: 60)
        XCTAssertTrue(holder.reconcile().holding)
        clock += 50
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100, lease: 60)
        clock += 50
        XCTAssertTrue(holder.reconcile().holding, "renewed 50 seconds ago with a 60 second lease")
        clock += 11
        XCTAssertFalse(holder.reconcile().holding)
        XCTAssertTrue(power.active.isEmpty)
    }

    func testNeverAnAssertionWithoutWorkToPointTo() throws {
        // a random walk over every action: after each pass, an assertion exists exactly when
        // keep-awake is on and unreleased work is live, and its details name that work.
        var generator = SystemRandomNumberGenerator()
        let owners: [Int32] = [100, 200]
        for step in 0..<400 {
            let task = ["a", "b", "c"].randomElement(using: &generator)!
            switch Int.random(in: 0..<7, using: &generator) {
            case 0, 1: try client.begin(task: task, reason: "step \(step)", owner: owners.randomElement()!, lease: 30)
            case 2: client.end(task: task)
            case 3: client.releaseAll()
            case 4: client.setEnabled(Bool.random(using: &generator))
            case 5: processes.started[owners.randomElement()!] = Bool.random() ? nil : 1.0
            default: clock += Double.random(in: 0...20, using: &generator)
            }
            processes.started[100] = processes.started[100].map { _ in 1.0 }
            processes.started[200] = processes.started[200].map { _ in 2.0 }
            let state = holder.reconcile()
            let settings = store.readSettings()
            let held = store.workItems().filter { $0.releasedAt == nil }
            XCTAssertEqual(state.holding, settings.enabled && !held.isEmpty, "step \(step)")
            XCTAssertEqual(power.active.count, state.holding ? 1 : 0, "step \(step)")
            if state.holding {
                XCTAssertEqual(Set(state.heldFor), Set(held.map(\.task)), "step \(step)")
                XCTAssertEqual(power.active.values.first, KeepAwakeHolder.describe(held), "step \(step)")
            }
            if Bool.random(using: &generator) { processes.started = [100: 1.0, 200: 2.0] }
        }
    }

    func testShutdownReleasesEverything() throws {
        client.setLidClosed(true)
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        holder.reconcile()
        holder.shutdown(why: "test")
        XCTAssertTrue(power.active.isEmpty)
        XCTAssertFalse(helper.sleepDisabled)
        XCTAssertNil(store.readHolder())
    }

    func testAFailedAssertionIsNotReportedAsHolding() throws {
        power.fail = true
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        XCTAssertFalse(holder.reconcile().holding)
        XCTAssertTrue(events().contains("assert-failed"))
    }

    // MARK: lid-closed

    func testLidClosedOnlyWhileHoldingAndOnlyWhenTheUserTurnedItOn() throws {
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        holder.reconcile()
        XCTAssertEqual(helper.calls, [], "the setting is off by default, so the helper is never asked")

        client.setLidClosed(true)
        XCTAssertTrue(holder.reconcile().lidClosedActive)
        XCTAssertTrue(helper.sleepDisabled)

        client.end(task: "inbox")
        let state = holder.reconcile()
        XCTAssertFalse(state.lidClosedActive, "the queue drained, so lid-closed is put back")
        XCTAssertFalse(helper.sleepDisabled)
        XCTAssertEqual(helper.calls, [true, false])
        XCTAssertEqual(helper.registered, 0, "the holder never registers the helper; only the user's setting does")
    }

    func testTurningLidClosedOffPutsItBackWhileWorkContinues() throws {
        client.setLidClosed(true)
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        XCTAssertTrue(holder.reconcile().lidClosedActive)
        client.setLidClosed(false)
        let state = holder.reconcile()
        XCTAssertTrue(state.holding)
        XCTAssertFalse(state.lidClosedActive)
        XCTAssertFalse(helper.sleepDisabled)
    }

    func testAHelperProblemIsShownNotHidden() throws {
        helper.fail = true
        client.setLidClosed(true)
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        let state = holder.reconcile()
        XCTAssertTrue(state.holding, "the assertion still holds; only lid-closed failed")
        XCTAssertFalse(state.lidClosedActive)
        XCTAssertNotNil(state.lidClosedProblem)
    }

    func testWithoutAHelperLidClosedSaysWhy() throws {
        let bare = KeepAwakeHolder(store: store, power: power, liveness: processes, helper: nil,
                                   now: { [unowned self] in self.clock }, process: 4242)
        client.setLidClosed(true)
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        let state = bare.reconcile()
        XCTAssertFalse(state.lidClosedActive)
        XCTAssertEqual(state.lidClosedProblem?.contains("signed sirven app"), true)
    }

    // MARK: client and store

    func testTaskNamesAndReasonsAreChecked() {
        for bad in ["", ".hidden", "a/b", "a b", String(repeating: "x", count: 81), "../escape", "caf\u{e9}"] {
            XCTAssertThrowsError(try client.begin(task: bad, reason: "r", owner: 100), bad)
        }
        XCTAssertThrowsError(try client.begin(task: "ok-name", reason: "   ", owner: 100))
        XCTAssertNoThrow(try client.begin(task: "agent.task_7-b", reason: "r", owner: 100))
        XCTAssertFalse(client.end(task: "../settings"))
    }

    func testStatusIgnoresAHolderRecordWhenNoHolderIsRunning() throws {
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        holder.reconcile() // writes holder.json, but this test holds no holder lock
        let status = client.status()
        XCTAssertFalse(status.holderRunning)
        XCTAssertFalse(status.holding)
        XCTAssertEqual(status.work.map(\.task), ["inbox"])
        XCTAssertEqual(status.credit, "Inspired by Sleepless by itskoosh (MIT).")
        XCTAssertEqual(status.releaseCommand, "sirven awake release")
    }

    func testStatusReadsTheRunningHolder() throws {
        guard let lock = store.acquireHolderLock() else { return XCTFail("lock") }
        defer { close(lock) }
        XCTAssertNil(store.acquireHolderLock(), "only one holder at a time")
        try client.begin(task: "inbox", reason: "summarize the inbox", owner: 100)
        holder.reconcile()
        let status = client.status()
        XCTAssertTrue(status.holderRunning)
        XCTAssertTrue(status.holding)
        XCTAssertEqual(status.holderProcess, 4242)
        XCTAssertEqual(status.work.first?.holding, true)
    }
}
