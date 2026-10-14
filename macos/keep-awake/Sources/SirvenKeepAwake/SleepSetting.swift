import Foundation

// the system's sleep-disabled setting, the one thing the privileged helper changes. it sits behind
// a protocol so the helper's rules can be tested without root and without touching the setting.

public protocol SleepSettingBackend: AnyObject {
    /// the system's own report of the setting, or nil when the report cannot be read.
    func isDisabled() -> Bool?
    /// set the setting. returns a problem to report, or nil when pmset succeeded.
    func set(_ disabled: Bool) -> String?
}

/// the real setting, through pmset. the reading needs no privileges; the change needs root, which
/// only the helper has. the arguments are fixed: nothing from a caller reaches pmset.
public final class PmsetSleepSetting: SleepSettingBackend {
    public init() {}

    public func isDisabled() -> Bool? {
        guard let report = Self.pmset(["-g"]), report.status == 0 else { return nil }
        return report.output.split(separator: "\n").contains {
            let words = $0.split(whereSeparator: \.isWhitespace)
            return words.count >= 2 && words[0] == "SleepDisabled" && words[1] == "1"
        }
    }

    public func set(_ disabled: Bool) -> String? {
        guard let result = Self.pmset(["-a", "disablesleep", disabled ? "1" : "0"]) else {
            return "pmset could not run"
        }
        return result.status == 0 ? nil : "pmset exited with status \(result.status)"
    }

    /// nil when pmset could not be started at all.
    static func pmset(_ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}

/// makes the setting match what sirven wants, and only ever puts back what sirven turned on. the
/// marker file records that sirven turned the setting on. the marker is written before pmset runs,
/// so a crash in between still reverts at the next start.
public final class SleepDisableGuard {
    public static let defaultMarker = URL(
        fileURLWithPath: "/Library/Application Support/sirven/keep-awake-helper/sleep-disabled-by-sirven")

    private let setting: SleepSettingBackend
    public let marker: URL

    public init(setting: SleepSettingBackend, marker: URL = SleepDisableGuard.defaultMarker) {
        self.setting = setting
        self.marker = marker
    }

    /// true while the marker says sirven turned the setting on and has not put it back.
    public var sirvenTurnedItOn: Bool { FileManager.default.fileExists(atPath: marker.path) }

    /// wanted true: turn the setting on unless it is already on. a setting that is on with no marker
    /// is the user's own, and stays untouched. wanted false: put it back, but only when sirven turned
    /// it on. returns true when pmset ran.
    @discardableResult
    public func enforce(_ wanted: Bool) throws -> Bool {
        if wanted {
            // the system's answer, not the marker, decides: a setting already on needs nothing.
            if setting.isDisabled() == true { return false }
            try writeMarker()
            if let problem = setting.set(true) {
                removeMarker()
                throw KeepAwakeError.helper(problem)
            }
            return true
        }
        guard sirvenTurnedItOn else { return false }
        // the marker stays when pmset fails, so the next start or the next release tries again.
        if let problem = setting.set(false) { throw KeepAwakeError.helper(problem) }
        removeMarker()
        return true
    }

    private func writeMarker() throws {
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: marker.path, contents: Data()) else {
            throw KeepAwakeError.helper("could not write \(marker.path)")
        }
    }

    private func removeMarker() {
        try? FileManager.default.removeItem(at: marker)
    }
}
