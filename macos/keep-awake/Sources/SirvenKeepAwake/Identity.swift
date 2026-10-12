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

    /// the code signing requirement the helper places on anyone who connects to it. the release
    /// build adds the team identifier from the Apple signing certificate for apps sold outside the App Store.
    public static let clientRequirement = "identifier \"\(appBundleIdentifier)\" and anchor apple generic"

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
