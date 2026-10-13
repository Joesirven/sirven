import Foundation
import XCTest
@testable import SirvenKeepAwake

// the privileged helper's rules, against a fake setting: no root, no pmset, nothing changed.

final class FakeSleepSetting: SleepSettingBackend {
    var disabled: Bool? = false
    var calls: [Bool] = []
    var failure: String?
    /// for each call, whether the marker file existed at the moment pmset would have run.
    var markerExistedAtCall: [Bool] = []
    var marker: URL?

    func isDisabled() -> Bool? { disabled }

    func set(_ value: Bool) -> String? {
        calls.append(value)
        if let marker { markerExistedAtCall.append(FileManager.default.fileExists(atPath: marker.path)) }
        if let failure { return failure }
        disabled = value
        return nil
    }
}

final class LogBox {
    var messages: [String] = []
}

final class HelperRulesTests: XCTestCase {
    var directory: URL!
    var marker: URL!
    var setting: FakeSleepSetting!
    var guardian: SleepDisableGuard!
    var core: KeepAwakeHelperCore!
    var log: LogBox!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("helper-rules-\(UUID().uuidString)")
        marker = directory.appendingPathComponent("sleep-disabled-by-sirven")
        setting = FakeSleepSetting()
        setting.marker = marker
        guardian = SleepDisableGuard(setting: setting, marker: marker)
        log = LogBox()
        let box = log!
        // the interval is long, so the timer never fires during a test: recheck() is called directly.
        core = KeepAwakeHelperCore(guardian: guardian, interval: 3600, log: { box.messages.append($0) })
    }

    override func tearDown() {
        core.revertAll()
        try? FileManager.default.removeItem(at: directory)
    }

    func markerExists() -> Bool { FileManager.default.fileExists(atPath: marker.path) }

    // case (a) from the review: sirven holds, something else clears the setting, and the next check asserts it again.
    func testAClearedSettingIsAssertedAgainDuringAHold() throws {
        XCTAssertNil(core.setAsking(ObjectIdentifier(self), true))
        XCTAssertEqual(setting.disabled, true)
        XCTAssertTrue(markerExists())

        setting.disabled = false           // `sudo pmset -a disablesleep 0`, or another tool
        core.recheck()
        XCTAssertEqual(setting.disabled, true, "the hold asserts the setting again")
        XCTAssertTrue(log.messages.contains("sleep-disabled was cleared during a hold; asserted again"))
    }

    // case (b): the user had the setting on before any hold. sirven leaves it on at release.
    func testTheUsersOwnSettingIsLeftOnAfterARelease() throws {
        setting.disabled = true
        XCTAssertNil(core.setAsking(ObjectIdentifier(self), true))
        XCTAssertFalse(markerExists(), "a setting that was already on is not sirven's, so no marker")
        XCTAssertNil(core.setAsking(ObjectIdentifier(self), false))
        XCTAssertEqual(setting.disabled, true)
        XCTAssertEqual(setting.calls, [], "neither the hold nor its release asks pmset to change it")
    }

    // case (c): hold, clear, check, release ends with the setting off and no marker.
    func testHoldClearCheckReleaseEndsWithTheSettingOffAndNoMarker() throws {
        let connection = ObjectIdentifier(self)
        XCTAssertNil(core.setAsking(connection, true))
        setting.disabled = false
        core.recheck()
        XCTAssertNil(core.setAsking(connection, false))
        XCTAssertEqual(setting.disabled, false)
        XCTAssertFalse(markerExists())
    }

    func testTheMarkerIsWrittenBeforePmsetRuns() throws {
        XCTAssertNil(core.setAsking(ObjectIdentifier(self), true))
        XCTAssertEqual(setting.markerExistedAtCall, [true], "a crash between the two steps must still leave a marker")
    }

    func testAFailedPmsetRemovesTheMarkerAndReportsIt() throws {
        setting.failure = "pmset exited with status 1"
        let problem = core.setAsking(ObjectIdentifier(self), true)
        XCTAssertEqual(problem, "pmset exited with status 1")
        XCTAssertFalse(markerExists())
        XCTAssertEqual(core.askingCount, 0, "a request that failed holds nothing")
    }

    func testAFailedRevertKeepsTheMarkerSoALaterRevertTriesAgain() throws {
        let connection = ObjectIdentifier(self)
        XCTAssertNil(core.setAsking(connection, true))
        setting.failure = "pmset exited with status 1"
        XCTAssertNotNil(core.setAsking(connection, false))
        XCTAssertTrue(markerExists())
        setting.failure = nil
        XCTAssertNil(core.revertAll())
        XCTAssertEqual(setting.disabled, false)
        XCTAssertFalse(markerExists())
    }

    func testTheSettingStaysOnWhileAnyConnectionAsks() throws {
        let first = ObjectIdentifier(self)
        let second = ObjectIdentifier(log)
        XCTAssertNil(core.setAsking(first, true))
        XCTAssertNil(core.setAsking(second, true))
        XCTAssertEqual(core.askingCount, 2)
        XCTAssertNil(core.setAsking(first, false))
        XCTAssertEqual(setting.disabled, true, "one connection still asks")
        XCTAssertNil(core.setAsking(second, false))
        XCTAssertEqual(setting.disabled, false)
    }

    func testAStartupRevertPutsBackWhatAnEarlierRunLeftOn() throws {
        // an earlier run was killed mid-hold: the marker and the setting are both left behind.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        setting.disabled = true
        XCTAssertNil(core.revertAll())
        XCTAssertEqual(setting.disabled, false)
        XCTAssertFalse(markerExists())
    }

    func testTheSystemAnswerDecidesNotTheMarker() throws {
        // a marker with the setting already off, from a run that never got as far as pmset: asserting is still needed.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        setting.disabled = false
        XCTAssertNil(core.setAsking(ObjectIdentifier(self), true))
        XCTAssertEqual(setting.disabled, true)
    }

    func testTheSettingReadIsUnknownWhenPmsetCannotBeAsked() {
        setting.disabled = nil
        XCTAssertNil(setting.isDisabled())
    }
}

final class HelperAccessTests: XCTestCase {
    private let team = "ABCDE12345"

    func testTheRequirementNamesTheAppAndTheTeam() {
        let requirement = KeepAwakeHelperAccess.requirement(teamIdentifier: team)
        XCTAssertEqual(requirement, "identifier \"xyz.sirven.app\" and anchor apple generic"
                       + " and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    func testWithoutATeamIdentifierNoRequirementExists() {
        // the helper turns every connection away when this is nil; there is no fallback without the team.
        XCTAssertNil(KeepAwakeHelperAccess.requirement(teamIdentifier: nil))
    }

    func testAMalformedTeamIdentifierIsRefused() {
        XCTAssertNil(KeepAwakeHelperAccess.requirement(teamIdentifier: ""))
        XCTAssertNil(KeepAwakeHelperAccess.requirement(teamIdentifier: "abcde12345"))
        XCTAssertNil(KeepAwakeHelperAccess.requirement(teamIdentifier: "ABCDE1234"))
        XCTAssertNil(KeepAwakeHelperAccess.requirement(teamIdentifier: "ABCDE12345\" or true"))
    }
}
