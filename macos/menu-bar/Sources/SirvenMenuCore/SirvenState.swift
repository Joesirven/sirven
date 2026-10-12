import Foundation

public enum Tier: String, Codable, CaseIterable {
    case solo, neighborly, coop = "co-op"

    public var title: String {
        switch self {
        case .solo: return "Solo"
        case .neighborly: return "Neighborly"
        case .coop: return "Co-op"
        }
    }
}

public enum AgentActivity: String, Codable {
    case notConnected = "not-connected"
    case idle
    case working
    case waitingForYou = "waiting-for-you"
}

public struct SirvenState: Equatable, Codable {
    public struct Agent: Equatable, Codable {
        public var activity: AgentActivity
        /// plain words for what the agent is on, when it is working or waiting.
        public var task: String?

        public init(activity: AgentActivity, task: String? = nil) {
            self.activity = activity
            self.task = task
        }
    }

    public struct KeepAwake: Equatable, Codable {
        public var held: Bool
        /// which agent task holds the Mac awake.
        public var reason: String?
        public var since: Date?

        public init(held: Bool, reason: String? = nil, since: Date? = nil) {
            self.held = held
            self.reason = reason
            self.since = since
        }
    }

    public var tier: Tier
    public var agent: Agent
    public var keepAwake: KeepAwake

    public init(tier: Tier, agent: Agent, keepAwake: KeepAwake) {
        self.tier = tier
        self.agent = agent
        self.keepAwake = keepAwake
    }

    /// What a fresh install shows before the runtime has said anything: Solo, no agent, awake off.
    public static let fresh = SirvenState(tier: .solo, agent: Agent(activity: .notConnected), keepAwake: KeepAwake(held: false))
}

/// Where the menu reads tier, agent, and keep-awake state from. The runtime (docs/runtime-interface.md,
/// still to come) and the keep-awake feature replace the file reader below with their own
/// providers; the menu only ever sees `SirvenState`.
public protocol SirvenStateProvider {
    func current() -> SirvenState
}

/// Reads a JSON state file, the documented stand-in until the runtime interface lands. A missing
/// or unreadable file reads as `SirvenState.fresh`, never as an error the user has to handle.
public struct StateFileProvider: SirvenStateProvider {
    public static let overrideVariable = "SIRVEN_MENU_STATE"

    public let path: String

    public init(path: String) {
        self.path = path
    }

    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[overrideVariable], !override.isEmpty { return override }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("sirven/menu-state.json").path
    }

    public func current() -> SirvenState {
        guard let data = FileManager.default.contents(atPath: path) else { return .fresh }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SirvenState.self, from: data)) ?? .fresh
    }
}
