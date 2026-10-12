import Foundation

/// the user's two switches. keep-awake is on by default (it only ever acts while work is in
/// flight); lid-closed operation is off until the user turns it on.
public struct KeepAwakeSettings: Codable, Equatable {
    public var enabled: Bool = true
    public var lidClosed: Bool = false
    public init(enabled: Bool = true, lidClosed: Bool = false) {
        self.enabled = enabled
        self.lidClosed = lidClosed
    }
}

/// one piece of agent work in flight. it lives as long as its owner process and its lease,
/// whichever ends first, so a crashed agent can never leave the Mac held awake.
public struct WorkItem: Codable, Equatable {
    public var task: String
    public var reason: String
    public var since: Date
    public var ownerProcess: Int32
    /// the owner's start time from the kernel, so a reused process number is not mistaken for the owner.
    public var ownerStartedAt: Double?
    public var expires: Date
    /// set by the one-click release: the work goes on, but no longer holds the Mac awake.
    public var releasedAt: Date?

    public init(task: String, reason: String, since: Date, ownerProcess: Int32,
                ownerStartedAt: Double?, expires: Date, releasedAt: Date? = nil) {
        self.task = task
        self.reason = reason
        self.since = since
        self.ownerProcess = ownerProcess
        self.ownerStartedAt = ownerStartedAt
        self.expires = expires
        self.releasedAt = releasedAt
    }
}

/// what the holder process last did, written after every pass so the status surface can read it.
public struct HolderState: Codable, Equatable {
    public var process: Int32
    public var holding: Bool
    public var holdingSince: Date?
    public var assertionName: String?
    public var heldFor: [String]
    public var lidClosedActive: Bool
    public var lidClosedProblem: String?
    public var updated: Date
}

public enum KeepAwakeError: Error, CustomStringConvertible {
    case badTaskName(String)
    case badReason
    case assertionFailed(Int32)
    case helper(String)

    public var description: String {
        switch self {
        case .badTaskName(let name):
            return "task name '\(name)' must be 1 to 80 letters, digits, dots, dashes, or underscores, and not start with a dot"
        case .badReason:
            return "a reason is needed: say what the agent is doing, in a few words"
        case .assertionFailed(let code):
            return "the system refused the power assertion (IOKit return code \(code))"
        case .helper(let message):
            return message
        }
    }
}

/// the files that hold keep-awake state, one folder per user:
///   settings.json      the two switches
///   work/<task>.json   one file per piece of work in flight
///   holder.json        what the holder process last did
///   holder.lock        held by the running holder, so there is only ever one
///   events.jsonl       every assert, release, and reap, with the reason
public final class KeepAwakeStore {
    public let directory: URL
    public var workDirectory: URL { directory.appendingPathComponent("work") }
    public var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    public var holderFile: URL { directory.appendingPathComponent("holder.json") }
    public var lockFile: URL { directory.appendingPathComponent("holder.lock") }
    public var eventsFile: URL { directory.appendingPathComponent("events.jsonl") }
    public var logFile: URL { directory.appendingPathComponent("holder.log") }

    public static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["SIRVEN_KEEP_AWAKE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("sirven/keep-awake", isDirectory: true)
    }

    public init(directory: URL = KeepAwakeStore.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func validTaskName(_ name: String) -> Bool {
        guard (1...80).contains(name.count), !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    /// write to a temporary file and rename it into place, so a reader never sees half a file.
    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? Self.encoder.encode(value) else { return }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        do {
            try data.write(to: temporary)
            if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    public func readSettings() -> KeepAwakeSettings { read(KeepAwakeSettings.self, from: settingsFile) ?? KeepAwakeSettings() }
    public func writeSettings(_ settings: KeepAwakeSettings) { write(settings, to: settingsFile) }

    public func workItems() -> [WorkItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { read(WorkItem.self, from: workDirectory.appendingPathComponent($0)) }
            .sorted { ($0.since, $0.task) < ($1.since, $1.task) }
    }

    public func workItem(_ task: String) -> WorkItem? {
        guard Self.validTaskName(task) else { return nil }
        return read(WorkItem.self, from: workDirectory.appendingPathComponent("\(task).json"))
    }

    public func write(_ item: WorkItem) { write(item, to: workDirectory.appendingPathComponent("\(item.task).json")) }

    @discardableResult
    public func remove(task: String) -> Bool {
        guard Self.validTaskName(task) else { return false }
        return (try? FileManager.default.removeItem(at: workDirectory.appendingPathComponent("\(task).json"))) != nil
    }

    public func readHolder() -> HolderState? { read(HolderState.self, from: holderFile) }
    public func writeHolder(_ state: HolderState) { write(state, to: holderFile) }
    public func clearHolder() { try? FileManager.default.removeItem(at: holderFile) }

    /// append one JSON line to events.jsonl. a single write call with O_APPEND, so lines from
    /// different processes do not interleave.
    public func log(_ event: String, _ fields: [String: String] = [:]) {
        var record = fields
        record["event"] = event
        record["time"] = ISO8601DateFormatter().string(from: Date())
        record["process"] = String(getpid())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        let descriptor = open(eventsFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// true when a holder process has the lock. flock locks belong to an open file, so a second
    /// open here conflicts with the holder's.
    public func holderIsRunning() -> Bool {
        let descriptor = open(lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return true
    }

    /// take the holder lock for the life of this process. returns nil when another holder has it.
    public func acquireHolderLock() -> Int32? {
        let descriptor = open(lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return nil }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
        close(descriptor)
        return nil
    }
}
