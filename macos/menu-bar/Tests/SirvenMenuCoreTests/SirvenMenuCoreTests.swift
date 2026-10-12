import XCTest
@testable import SirvenMenuCore

private func fixture(_ name: String) -> String {
    Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!.path
}

private func fixtureText(_ name: String) -> String {
    try! String(contentsOfFile: fixture(name), encoding: .utf8)
}

/// a runner that answers from memory and remembers what it was asked.
private final class ScriptedRunner: CommandRunner {
    var calls: [[String]] = []
    var answer: (([String]) -> CommandResult)

    init(_ answer: @escaping ([String]) -> CommandResult) { self.answer = answer }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls.append(arguments)
        return answer(arguments)
    }
}

final class TailscaleParsingTests: XCTestCase {
    func testConnectedStatusReadsIdentityAndExitNodes() throws {
        let snapshot = try TailscaleSnapshot.parse(fixtureText("status-connected.json"))
        XCTAssertEqual(snapshot.connection, .connected)
        XCTAssertEqual(snapshot.identity, TailscaleIdentity(
            hostName: "laptop",
            dnsName: "laptop.example-tailnet.ts.net",
            addresses: ["100.64.0.1", "fd7a:115c:a1e0::1"],
            tailnet: "person@example.com",
            login: "person@example.com"
        ))
        // only peers that offer to be an exit node, sorted by name, the phone left out.
        XCTAssertEqual(snapshot.exitNodes.map(\.name), ["cabin-router", "home-server"])
        XCTAssertEqual(snapshot.activeExitNode?.address, "100.64.0.2")
        XCTAssertEqual(snapshot.exitNodes.first?.online, false)
    }

    func testBackendStatesMapToConnection() throws {
        let cases: [(String, TailscaleConnection)] = [
            ("Running", .connected),
            ("Stopped", .disconnected),
            ("NeedsLogin", .needsLogin),
            ("NeedsMachineAuth", .needsLogin),
            ("Starting", .starting),
            ("NoState", .starting),
            ("Mystery", .unavailable("Tailscale reports state Mystery")),
        ]
        for (raw, expected) in cases {
            let snapshot = try TailscaleSnapshot.parse("{\"BackendState\": \"\(raw)\"}")
            XCTAssertEqual(snapshot.connection, expected, raw)
        }
    }

    func testStoppedStatusWithNullPeersStillParses() throws {
        let snapshot = try TailscaleSnapshot.parse(fixtureText("status-stopped.json"))
        XCTAssertEqual(snapshot.connection, .disconnected)
        XCTAssertEqual(snapshot.identity?.hostName, "laptop")
        XCTAssertEqual(snapshot.exitNodes, [])
    }
}

final class TailscaleClientTests: XCTestCase {
    func testResolveOrder() {
        XCTAssertEqual(TailscaleClient.resolveExecutable(environment: ["SIRVEN_TAILSCALE": "/fake"], isExecutable: { _ in false }), "/fake")
        XCTAssertEqual(TailscaleClient.resolveExecutable(environment: [:], isExecutable: { _ in true }), TailscaleClient.bundledExecutable)
        XCTAssertEqual(TailscaleClient.resolveExecutable(environment: [:], isExecutable: { $0 == "/usr/local/bin/tailscale" }), "/usr/local/bin/tailscale")
        XCTAssertNil(TailscaleClient.resolveExecutable(environment: [:], isExecutable: { _ in false }))
    }

    func testNotInstalled() {
        let client = TailscaleClient(executable: nil)
        XCTAssertEqual(client.snapshot().connection, .notInstalled)
        XCTAssertEqual(client.connect(), .failed("Tailscale is not installed"))
    }

    func testChangeArguments() {
        let runner = ScriptedRunner { _ in CommandResult(status: 0, stdout: "", stderr: "") }
        let client = TailscaleClient(executable: "/fake", runner: runner)
        XCTAssertEqual(client.connect(), .done)
        XCTAssertEqual(client.disconnect(), .done)
        XCTAssertEqual(client.useExitNode("100.64.0.2"), .done)
        XCTAssertEqual(client.useExitNode(nil), .done)
        XCTAssertEqual(runner.calls, [["up"], ["down"], ["set", "--exit-node=100.64.0.2"], ["set", "--exit-node="]])
    }

    func testFailureSurfacesTailscaleWordsNotTheVersionWarning() {
        let runner = ScriptedRunner { _ in
            CommandResult(status: 1, stdout: "", stderr: "Warning: client version \"1\" != tailscaled server version \"2\"\n\nexit node not found\n")
        }
        let client = TailscaleClient(executable: "/fake", runner: runner)
        XCTAssertEqual(client.useExitNode("100.64.0.9"), .failed("exit node not found"))
    }

    func testStatusWithoutJSONReportsStandardError() {
        let runner = ScriptedRunner { _ in CommandResult(status: 1, stdout: "", stderr: "failed to connect to local Tailscale service\n") }
        let client = TailscaleClient(executable: "/fake", runner: runner)
        XCTAssertEqual(client.snapshot().connection, .unavailable("failed to connect to local Tailscale service"))
    }

    func testTimeouts() {
        let runner = ScriptedRunner { _ in CommandResult(status: -1, stdout: "", stderr: "", timedOut: true) }
        let client = TailscaleClient(executable: "/fake", runner: runner)
        XCTAssertEqual(client.snapshot().connection, .unavailable("Tailscale did not answer in time"))
        XCTAssertEqual(client.disconnect(), .failed("Tailscale did not answer in time"))
    }
}

/// the real ProcessRunner against a fake Tailscale command: separate streams, logged arguments,
/// failures, and the timeout. no real tailnet is touched.
final class FakeTailscaleCommandTests: XCTestCase {
    var log: String!

    override func setUp() {
        log = NSTemporaryDirectory() + "sirven-fake-tailscale-\(UUID().uuidString).log"
        setenv("FAKE_TAILSCALE_LOG", log, 1)
        setenv("FAKE_TAILSCALE_STATUS", fixture("status-connected.json"), 1)
        unsetenv("FAKE_TAILSCALE_FAIL")
        unsetenv("FAKE_TAILSCALE_STALL")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: log)
        unsetenv("FAKE_TAILSCALE_FAIL")
        unsetenv("FAKE_TAILSCALE_STALL")
    }

    private var client: TailscaleClient {
        TailscaleClient(executable: fixture("fake-tailscale.sh"), timeout: 2)
    }

    private var logged: [String] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testStatusParsesDespiteWarningOnStandardError() {
        XCTAssertEqual(client.snapshot().connection, .connected)
        XCTAssertEqual(logged, ["status --json"])
    }

    func testChangesReachTheCommand() {
        XCTAssertEqual(client.useExitNode("100.64.0.2"), .done)
        XCTAssertEqual(client.useExitNode(nil), .done)
        XCTAssertEqual(client.disconnect(), .done)
        XCTAssertEqual(client.connect(), .done)
        XCTAssertEqual(logged, ["set --exit-node=100.64.0.2", "set --exit-node=", "down", "up"])
    }

    func testRefusalIsReportedInTailscalesWords() {
        setenv("FAKE_TAILSCALE_FAIL", "is not a valid exit node", 1)
        XCTAssertEqual(client.useExitNode("100.64.0.99"), .failed("is not a valid exit node"))
    }

    func testStalledCommandTimesOut() {
        setenv("FAKE_TAILSCALE_STALL", "1", 1)
        let started = Date()
        XCTAssertEqual(TailscaleClient(executable: fixture("fake-tailscale.sh"), timeout: 0.5).disconnect(), .failed("Tailscale did not answer in time"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}

final class StateFileTests: XCTestCase {
    func testMissingFileReadsAsFresh() {
        XCTAssertEqual(StateFileProvider(path: "/nonexistent/menu-state.json").current(), .fresh)
    }

    func testFileIsRead() throws {
        let path = NSTemporaryDirectory() + "sirven-menu-state-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try """
        {"tier": "solo", "agent": {"activity": "working", "task": "comparing flights"},
         "keepAwake": {"held": true, "reason": "comparing flights", "since": "2026-10-11T14:00:00Z"}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let state = StateFileProvider(path: path).current()
        XCTAssertEqual(state.agent, .init(activity: .working, task: "comparing flights"))
        XCTAssertEqual(state.keepAwake.held, true)
        XCTAssertEqual(state.keepAwake.since, Date(timeIntervalSince1970: 1_791_727_200))
    }

    func testDefaultPathHonorsOverride() {
        XCTAssertEqual(StateFileProvider.defaultPath(environment: ["SIRVEN_MENU_STATE": "/x.json"]), "/x.json")
        XCTAssertTrue(StateFileProvider.defaultPath(environment: [:]).hasSuffix("Application Support/sirven/menu-state.json"))
    }
}

final class MenuModelTests: XCTestCase {
    private func render(_ state: SirvenState = .fresh, _ snapshot: TailscaleSnapshot, lastError: String? = nil) -> String {
        MenuModel.render(MenuModel.build(state: state, tailscale: snapshot, lastError: lastError, formatTime: { _ in "2:00 PM" }))
    }

    func testConnectedMenu() throws {
        let snapshot = try TailscaleSnapshot.parse(fixtureText("status-connected.json"))
        let state = SirvenState(
            tier: .solo,
            agent: .init(activity: .working, task: "comparing flights"),
            keepAwake: .init(held: true, reason: "comparing flights", since: Date())
        )
        XCTAssertEqual(render(state, snapshot), """
        # Sirven
          Tier: Solo >
            \u{2713} Solo
              (Neighborly, not yet available)
              (Co-op, not yet available)
              Nothing shared. Your agent asks before every real-world action.
              ---
              Tier settings\u{2026}
          Agent: working on comparing flights
          Keep awake: on for comparing flights, since 2:00 PM
          ---
          Tailscale: connected
          This device: laptop >
              Copy laptop.example-tailnet.ts.net
              Copy 100.64.0.1
              Copy fd7a:115c:a1e0::1
              ---
              Tailnet: person@example.com
              Signed in as person@example.com
          Exit node: home-server >
              No exit node
              ---
              (cabin-router, offline)
            \u{2713} home-server
          Disconnect
          ---
          Keep awake settings\u{2026}
          Hide Tailscale\u{2019}s menu bar item\u{2026}
          Open Tailscale
          ---
          Quit Sirven
        """)
    }

    func testDisconnectedOffersConnectAndNoExitNodePicker() throws {
        let text = render(.fresh, try TailscaleSnapshot.parse(fixtureText("status-stopped.json")))
        XCTAssertTrue(text.contains("Tailscale: disconnected"))
        XCTAssertTrue(text.contains("\n  Connect\n"))
        XCTAssertFalse(text.contains("Exit node"))
        XCTAssertTrue(text.contains("Agent: not connected"))
        XCTAssertTrue(text.contains("Keep awake: off"))
    }

    func testNotInstalledDisablesOpenTailscale() {
        let text = render(.fresh, TailscaleSnapshot(connection: .notInstalled))
        XCTAssertTrue(text.contains("Tailscale: not installed"))
        XCTAssertTrue(text.contains("(Open Tailscale)"))
    }

    func testNeedsLoginHandsOffToTailscale() {
        let entries = MenuModel.build(state: .fresh, tailscale: TailscaleSnapshot(connection: .needsLogin))
        XCTAssertTrue(entries.contains(.item(MenuItem("Log in with Tailscale\u{2026}", action: .openTailscale))))
    }

    func testNoExitNodesOffered() {
        let snapshot = TailscaleSnapshot(connection: .connected, exitNodes: [])
        XCTAssertTrue(render(.fresh, snapshot).contains("Exit node: none >"))
        XCTAssertTrue(render(.fresh, snapshot).contains("No device in your tailnet offers to be an exit node"))
    }

    func testLastErrorIsShown() {
        let text = render(.fresh, TailscaleSnapshot(connection: .connected), lastError: "exit node not found")
        XCTAssertTrue(text.contains("That did not work: exit node not found"))
    }

    func testOnlySoloIsChoosable() {
        guard case .item(let tier) = MenuModel.tierEntry(.solo) else { return XCTFail("tier is a submenu") }
        let choosable = tier.children.compactMap { entry -> String? in
            if case .item(let item) = entry, item.enabled, item.action == nil { return item.title }
            return nil
        }
        XCTAssertEqual(choosable, ["Solo"])
    }
}
