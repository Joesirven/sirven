import Foundation

/// Every word the menu bar app shows, in one place. The consent text for hiding Tailscale's
/// menu bar item is mirrored in copy/menu-bar-tailscale.md for Jose's review; change both together.
public enum MenuCopy {
    /// The product name is a working name that lives in project.json; build-app.sh writes it into
    /// the bundle, and the app reads it back from there. Outside a bundle (tests, `--print-menu`
    /// from a bare build) it falls back to the working name.
    public static let appName: String = {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
              !name.isEmpty else { return "Sirven" }
        return name
    }()

    public static let tierLabel = "Tier:"
    public static let tierSettings = "Tier settings\u{2026}"
    public static let notYetAvailable = "not yet available"
    public static func tierSummary(_ tier: Tier) -> String {
        switch tier {
        case .solo: return "Nothing shared. Your agent asks before every real-world action."
        case .neighborly: return "You carry neighbors' agent traffic to allowlisted sites, up to 5 gigabytes a month."
        case .coop: return "Higher caps and more autonomy, within the budget you set."
        }
    }

    public static let agentLabel = "Agent:"
    public static let agentNotConnected = "not connected"
    public static let agentIdle = "idle"
    public static let agentWorking = "working"
    public static let agentWorkingOn = "working on"
    public static let agentWaiting = "waiting for you"

    public static let keepAwakeLabel = "Keep awake:"
    public static let keepAwakeSettings = "Keep awake settings\u{2026}"
    public static let on = "on"
    public static let off = "off"
    public static let forTask = "for"
    public static let since = "since"

    public static let tailscaleLabel = "Tailscale:"
    public static let tailscaleConnected = "connected"
    public static let tailscaleDisconnected = "disconnected"
    public static let tailscaleStarting = "starting"
    public static let tailscaleNeedsLogin = "needs you to log in"
    public static let tailscaleNotInstalled = "not installed"
    public static let logInWithTailscale = "Log in with Tailscale\u{2026}"
    public static let connect = "Connect"
    public static let disconnect = "Disconnect"
    public static let thisDevice = "This device:"
    public static let copy = "Copy"
    public static let tailnetLabel = "Tailnet:"
    public static let signedInAs = "Signed in as"
    public static let exitNodeLabel = "Exit node:"
    public static let none = "none"
    public static let noExitNode = "No exit node"
    public static let noExitNodesOffered = "No device in your tailnet offers to be an exit node"
    public static let offline = "offline"
    public static let lastChangeFailed = "That did not work:"

    public static let hideTailscaleItem = "Hide Tailscale\u{2019}s menu bar item\u{2026}"
    public static let openTailscale = "Open Tailscale"
    public static var quit: String { "Quit \(appName)" }

    // the consent moment for hiding Tailscale's own menu bar item. sirven cannot hide another
    // app's item, and Tailscale has no setting for it, so the person flips the macOS switch.
    public static let hideTitle = "Make Sirven your one menu bar item for Tailscale?"
    public static let hideBody = """
    Sirven already shows Tailscale's connection, this device, and your exit node. If you like, \
    you can hide Tailscale's own menu bar item so there is one place to look.

    Sirven can't hide it for you. macOS leaves that choice to you: in System Settings, \
    Menu Bar, turn Tailscale off under "Allow in the Menu Bar".

    Tailscale keeps running either way. For things Sirven doesn't show, like logging in, \
    switching accounts, or sending files, choose Open Tailscale in Sirven's menu. To bring \
    Tailscale's item back, turn it on in the same place.
    """
    public static let hideConfirm = "Open Menu Bar Settings"
    public static let hideDecline = "Not Now"
    public static let hideOlderMacOS = """
    This Mac's version of macOS has no switch for other apps' menu bar items. Tailscale's item \
    stays, and Sirven shows the same controls alongside it.
    """

    public static let comingTitle = "Not in this build yet"
    public static let tierComing = "Solo is the only tier in this build. Neighborly and Co-op arrive once the protections they depend on are in place."
    public static let keepAwakeComing = "Keep awake settings arrive in a coming build. The state shown in the menu is what Sirven knows today."
    public static let done = "Done"
}
