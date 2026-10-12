import Foundation
import XCTest
@testable import SirvenOnboarding

// the wizard's rules, checked against the real copy file in copy/onboarding-wizard.json.
@MainActor
final class OnboardingTests: XCTestCase {
  static let copyURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("copy/onboarding-wizard.json")

  func makeModel(answers: [Permission: PermissionState] = [:], endpoint: String? = "http://127.0.0.1:7878") throws -> (OnboardingModel, FakePermissionBroker) {
    let broker = FakePermissionBroker(answers: answers)
    let model = OnboardingModel(copy: try OnboardingCopy.load(from: Self.copyURL), broker: broker, endpoint: endpoint,
                                now: { Date(timeIntervalSince1970: 0) })
    return (model, broker)
  }

  // Jose's bar: two or three steps plus a confirmation.
  func testStepCountHonorsTwoOrThreeStepsPlusConfirmation() {
    XCTAssertTrue((2...3).contains(OnboardingStep.steps.count))
    XCTAssertEqual(OnboardingStep.allCases.last, .confirmation)
    XCTAssertEqual(OnboardingStep.allCases.count, OnboardingStep.steps.count + 1)
  }

  func testWalksForwardAndBackThroughEveryStep() throws {
    let (model, _) = try makeModel()
    XCTAssertEqual(model.step, .welcome)
    XCTAssertFalse(model.canGoBack)
    model.next(); XCTAssertEqual(model.step, .tier)
    model.back(); XCTAssertEqual(model.step, .welcome)
    model.next(); model.next(); model.next()
    XCTAssertEqual(model.step, .confirmation)
    XCTAssertFalse(model.canGoBack, "the confirmation states what is true; it is not a step to undo")
    model.next(); XCTAssertEqual(model.step, .confirmation)
  }

  func testSoloIsTheDefault() throws {
    let (model, _) = try makeModel()
    XCTAssertEqual(model.tier, .solo)
    XCTAssertEqual(model.result().tier, .solo)
  }

  // ship gate: no peer routing of authenticated traffic until attestation and the
  // site-allowlist review workflow work end to end. Neighborly and Co-op both route peer
  // traffic, so the shipped copy must keep them closed.
  func testPeerRoutingTiersStayClosedUntilTheShipGatesClear() throws {
    let (model, _) = try makeModel()
    XCTAssertFalse(model.isAvailable(.neighborly))
    XCTAssertFalse(model.isAvailable(.coop))
    XCTAssertFalse(model.choose(.neighborly))
    XCTAssertFalse(model.choose(.coop))
    XCTAssertEqual(model.tier, .solo)
  }

  func testNothingIsRequestedUntilTheUserAsks() throws {
    let (model, broker) = try makeModel()
    model.next(); model.next(); model.next()
    XCTAssertEqual(broker.requested, [])
    XCTAssertEqual(model.result().notifications, .notAsked)
  }

  func testConfirmationStatesTheRealPermissionState() async throws {
    let (model, broker) = try makeModel(answers: [.notifications: .allowed, .openAtLogin: .declined])
    await model.request(.notifications)
    await model.request(.openAtLogin)
    XCTAssertEqual(broker.requested, [.notifications, .openAtLogin])
    let facts = model.facts
    let copy = model.copy.confirmation.facts
    XCTAssertTrue(facts.contains(copy.notificationsOn))
    XCTAssertTrue(facts.contains(copy.openAtLoginOff))
    XCTAssertTrue(facts.contains("Point your agent at http://127.0.0.1:7878."))
    XCTAssertEqual(model.result().openAtLogin, .declined)
  }

  func testConfirmationIsHonestWithoutARuntimeEndpoint() throws {
    let (model, _) = try makeModel(endpoint: nil)
    XCTAssertTrue(model.facts.contains(model.copy.confirmation.facts.endpointPending))
  }

  func testEveryPermissionAndTierHasCopy() throws {
    let copy = try OnboardingCopy.load(from: Self.copyURL)
    XCTAssertEqual(Set(copy.permissions.items.map(\.id)), Set(Permission.allCases))
    XCTAssertEqual(copy.tier.options.map(\.id), Tier.allCases)
    XCTAssertFalse(copy.confirmation.menuBarItems.isEmpty)
  }

  func testStoreRoundTripsTheResult() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = OnboardingStore(directory: directory)
    XCTAssertNil(store.load())
    XCTAssertNil(store.runtimeEndpoint())
    let (model, _) = try makeModel()
    try store.save(model.result())
    XCTAssertEqual(store.load(), model.result())
    try Data(#"{"agentEndpoint": "http://127.0.0.1:9000"}"#.utf8).write(to: store.runtimeURL)
    XCTAssertEqual(store.runtimeEndpoint(), "http://127.0.0.1:9000")
    try store.reset()
    XCTAssertNil(store.load())
  }
}
