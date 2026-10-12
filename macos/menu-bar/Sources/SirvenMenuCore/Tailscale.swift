import Foundation

/// The slice of `tailscale status --json` sirven reads. Only these fields are decoded; the rest
/// of the output (keys, addresses of every peer, health text) is never kept.
struct TailscaleStatusJSON: Decodable {
    struct Node: Decodable {
        var HostName: String?
        var DNSName: String?
        var TailscaleIPs: [String]?
        var UserID: Int64?
        var Online: Bool?
        var ExitNode: Bool?
        var ExitNodeOption: Bool?
    }
    struct Tailnet: Decodable {
        var Name: String?
    }
    struct Login: Decodable {
        var LoginName: String?
        var DisplayName: String?
    }

    var BackendState: String?
    var Self_: Node?
    var Peer: [String: Node]?
    var CurrentTailnet: Tailnet?
    var User: [String: Login]?

    enum CodingKeys: String, CodingKey {
        case BackendState, Peer, CurrentTailnet, User
        case Self_ = "Self"
    }
}

/// Tailscale's connection state, from `BackendState`.
public enum TailscaleConnection: Equatable {
    case connected
    case disconnected
    case needsLogin
    case starting
    case notInstalled
    case unavailable(String)
}

public struct TailscaleExitNode: Equatable {
    public var name: String
    /// the address `tailscale set --exit-node=` is given: the node's first tailnet address.
    public var address: String
    public var online: Bool
    public var active: Bool

    public init(name: String, address: String, online: Bool, active: Bool) {
        self.name = name
        self.address = address
        self.online = online
        self.active = active
    }
}

public struct TailscaleIdentity: Equatable {
    public var hostName: String
    public var dnsName: String
    public var addresses: [String]
    public var tailnet: String?
    public var login: String?

    public init(hostName: String, dnsName: String, addresses: [String], tailnet: String?, login: String?) {
        self.hostName = hostName
        self.dnsName = dnsName
        self.addresses = addresses
        self.tailnet = tailnet
        self.login = login
    }
}

public struct TailscaleSnapshot: Equatable {
    public var connection: TailscaleConnection
    public var identity: TailscaleIdentity?
    public var exitNodes: [TailscaleExitNode]

    public init(connection: TailscaleConnection, identity: TailscaleIdentity? = nil, exitNodes: [TailscaleExitNode] = []) {
        self.connection = connection
        self.identity = identity
        self.exitNodes = exitNodes
    }

    public var activeExitNode: TailscaleExitNode? { exitNodes.first { $0.active } }

    /// Parses `tailscale status --json` standard output.
    public static func parse(_ json: String) throws -> TailscaleSnapshot {
        let status = try JSONDecoder().decode(TailscaleStatusJSON.self, from: Data(json.utf8))
        let connection: TailscaleConnection
        switch status.BackendState ?? "" {
        case "Running": connection = .connected
        case "Stopped": connection = .disconnected
        case "NeedsLogin", "NeedsMachineAuth": connection = .needsLogin
        case "Starting", "NoState": connection = .starting
        case let other: connection = .unavailable("Tailscale reports state \(other.isEmpty ? "unknown" : other)")
        }

        var identity: TailscaleIdentity?
        if let me = status.Self_, let host = me.HostName {
            var login: String?
            if let userID = me.UserID, let user = status.User?[String(userID)] {
                login = user.LoginName ?? user.DisplayName
            }
            identity = TailscaleIdentity(
                hostName: host,
                dnsName: trimDot(me.DNSName ?? ""),
                addresses: me.TailscaleIPs ?? [],
                tailnet: status.CurrentTailnet?.Name,
                login: login
            )
        }

        let exitNodes: [TailscaleExitNode] = (status.Peer ?? [:]).values
            .filter { $0.ExitNodeOption == true }
            .compactMap { peer in
                guard let address = peer.TailscaleIPs?.first else { return nil }
                let dns = trimDot(peer.DNSName ?? "")
                let short = dns.split(separator: ".").first.map(String.init)
                return TailscaleExitNode(
                    name: short ?? peer.HostName ?? address,
                    address: address,
                    online: peer.Online ?? false,
                    active: peer.ExitNode ?? false
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return TailscaleSnapshot(connection: connection, identity: identity, exitNodes: exitNodes)
    }

    private static func trimDot(_ name: String) -> String {
        name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}

/// Reads and changes Tailscale through its own command-line tool, the supported local interface.
/// sirven never edits Tailscale's preferences, policies, or installation.
public struct TailscaleClient {
    /// The copy inside the app bundle comes first: it ships with the running Tailscale, while
    /// a package-manager copy on the path can lag behind it.
    public static let bundledExecutable = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    public static let pathCandidates = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
    public static let overrideVariable = "SIRVEN_TAILSCALE"

    public let executable: String?
    let runner: CommandRunner
    let timeout: TimeInterval

    public init(executable: String?, runner: CommandRunner = ProcessRunner(), timeout: TimeInterval = 8) {
        self.executable = executable
        self.runner = runner
        self.timeout = timeout
    }

    /// `SIRVEN_TAILSCALE` first (tests point it at a fake), then the app bundle, then the path.
    public static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override = environment[overrideVariable], !override.isEmpty {
            return override
        }
        return ([bundledExecutable] + pathCandidates).first(where: isExecutable)
    }

    public func snapshot() -> TailscaleSnapshot {
        guard let executable else { return TailscaleSnapshot(connection: .notInstalled) }
        let result = runner.run(executable, ["status", "--json"], timeout: timeout)
        if result.timedOut {
            return TailscaleSnapshot(connection: .unavailable("Tailscale did not answer in time"))
        }
        // status exits non-zero when stopped or logged out but still prints the JSON, so the
        // JSON decides, and the exit status only matters when there is none.
        if let parsed = try? TailscaleSnapshot.parse(result.stdout) {
            return parsed
        }
        return TailscaleSnapshot(connection: .unavailable(Self.firstLine(result.stderr) ?? "Tailscale is not answering"))
    }

    public func connect() -> TailscaleChangeResult { change(["up"]) }
    public func disconnect() -> TailscaleChangeResult { change(["down"]) }

    /// `nil` stops using an exit node.
    public func useExitNode(_ address: String?) -> TailscaleChangeResult {
        change(["set", "--exit-node=\(address ?? "")"])
    }

    func change(_ arguments: [String]) -> TailscaleChangeResult {
        guard let executable else { return .failed("Tailscale is not installed") }
        let result = runner.run(executable, arguments, timeout: timeout)
        if result.timedOut { return .failed("Tailscale did not answer in time") }
        if result.status == 0 { return .done }
        return .failed(Self.firstLine(result.stderr) ?? Self.firstLine(result.stdout) ?? "Tailscale refused the change")
    }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.lowercased().hasPrefix("warning: client version") }
    }
}

public enum TailscaleChangeResult: Equatable {
    case done
    case failed(String)
}
