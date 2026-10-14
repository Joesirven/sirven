import Foundation
import MachO

// names, identifiers, and the credit line, kept in one place so the menu bar app and the signed
// app bundle can change them without hunting through the code.

public enum KeepAwakeIdentity {
    /// the credit line, shown in the README, in `sirven awake about`, and in the menu bar app's about surface.
    public static let credit = "Inspired by Sleepless by itskoosh (MIT)."
    public static let creditURL = "https://github.com/itskoosh/Sleepless"

    /// the name every sirven power assertion carries, so `pmset -g assertions` shows who is holding it.
    public static let assertionName = "sirven keep-awake: your agent has work in flight"

    /// the app bundle identifier the helper trusts, and the helper's launchd label and service name.
    /// the signed app (built by the download and signing work) must use these, or change them here.
    public static let appBundleIdentifier = "xyz.sirven.app"
    public static let helperLabel = "xyz.sirven.keep-awake-helper"
    public static let helperPlistName = "xyz.sirven.keep-awake-helper.plist"

    /// what the user runs (or clicks) to release the hold at once.
    public static let releaseCommand = "sirven awake release"

    public static let about = """
    sirven keep-awake keeps this Mac awake while your agent has work in flight, and only then.
    It holds a power assertion that names the work, releases it when the work is done, and
    never holds one without work to point to. Lid-closed operation is a separate setting, off
    until you turn it on.

    \(credit) \(creditURL)
    sirven's keep-awake is its own implementation.
    """
}

/// who may talk to the helper. the helper is root, so it must know which team signed the app.
/// the team identifier is written into the helper's own executable at build time (scripts/build-app.sh
/// embeds it as the SirvenTeamIdentifier key of an Info.plist section), never into the source.
public enum KeepAwakeHelperAccess {
    /// the requirement a connecting program must meet: the sirven app identifier, signed by Apple,
    /// and by the team. nil when the team identifier is missing or malformed, which means the helper
    /// accepts no connection at all. there is no fallback to a requirement without the team.
    public static func requirement(teamIdentifier: String?) -> String? {
        guard let team = teamIdentifier, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            return nil
        }
        return "identifier \"\(KeepAwakeIdentity.appBundleIdentifier)\" and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// the team identifier embedded in this executable at build time, or nil when none was built in.
    /// it is read from the executable's own __TEXT,__info_plist section, not from Bundle.main: the helper
    /// runs from Sirven.app/Contents/MacOS, where Bundle.main is the app, whose Info.plist has no such key.
    public static var embeddedTeamIdentifier: String? {
        var size: UInt = 0
        guard let section = getsectiondata(executableHeader(), "__TEXT", "__info_plist", &size) else { return nil }
        let data = Data(bytes: section, count: Int(size))
        let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        return info?["SirvenTeamIdentifier"] as? String
    }

    /// the Mach-O header of the running executable. dyld exports this accessor, which the MachO module does not declare.
    @_silgen_name("_NSGetMachExecuteHeader")
    private static func nsGetMachExecuteHeader() -> UnsafeMutableRawPointer

    private static func executableHeader() -> UnsafePointer<mach_header_64> {
        UnsafePointer(nsGetMachExecuteHeader().assumingMemoryBound(to: mach_header_64.self))
    }
}
