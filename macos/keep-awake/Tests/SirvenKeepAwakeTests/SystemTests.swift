import Foundation
import XCTest
@testable import SirvenKeepAwake

// the real system, briefly: one assertion with a unique name, checked against what the system
// lists for this process, then released. other processes' assertions are never counted.

final class SystemTests: XCTestCase {
    func testARealAssertionIsListedByTheSystemAndReleased() throws {
        let power = SystemPowerAssertions()
        let name = "sirven keep-awake test \(UUID().uuidString)"
        let assertion = try power.create(name: name, details: "test: checking the system lists it")
        var mine = SystemAssertionReport.assertions(of: getpid()).filter { $0.name == name }
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine.first?.type, "PreventUserIdleSystemSleep")
        XCTAssertEqual(mine.first?.details, "test: checking the system lists it")

        power.update(assertion, details: "test: updated")
        mine = SystemAssertionReport.assertions(of: getpid()).filter { $0.name == name }
        XCTAssertEqual(mine.first?.details, "test: updated")

        power.release(assertion)
        XCTAssertTrue(SystemAssertionReport.assertions(of: getpid()).filter { $0.name == name }.isEmpty)
    }

    func testProcessLivenessSeesThisProcessAndNotAnExitedOne() throws {
        let liveness = KernelProcessLiveness()
        XCTAssertNotNil(liveness.startTime(of: getpid()))
        XCTAssertEqual(liveness.startTime(of: getpid()), liveness.startTime(of: getpid()))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        XCTAssertNil(liveness.startTime(of: child.processIdentifier))
        XCTAssertNil(liveness.startTime(of: 0))
    }
}
