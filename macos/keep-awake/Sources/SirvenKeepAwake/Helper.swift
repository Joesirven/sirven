import Foundation
import ServiceManagement

// the privileged helper is needed for one thing only: keeping the Mac awake with the lid closed,
// which a power assertion cannot do. it is registered with the Service Management framework the
// first time the user turns lid-closed operation on, never at install time or first launch.

/// what the helper does, spoken over XPC. the helper runs as root, so the surface stays this small.
@objc public protocol KeepAwakeHelperProtocol {
    /// true: keep the Mac awake with the lid closed. false: put the system's own behavior back.
    /// the helper also puts it back by itself when the caller's connection drops.
    func setSleepDisabled(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

public enum HelperState: String, Codable {
    /// never registered: nothing has needed it yet.
    case notRegistered
    /// registered, waiting for the user to allow it in System Settings.
    case requiresApproval
    /// allowed and ready.
    case enabled
    /// this copy of sirven is not running from the signed app bundle, which carries the helper.
    case notFound
}

public protocol LidClosedHelper: AnyObject {
    var state: HelperState { get }
    /// ask the system to register the helper. the system, not sirven, asks the user.
    func register() throws -> HelperState
    func setSleepDisabled(_ disabled: Bool) throws
    /// remove the helper's registration. the helper reverts the setting before it goes.
    func unregister() throws
}

public final class ServiceManagementHelper: LidClosedHelper {
    private let service = SMAppService.daemon(plistName: KeepAwakeIdentity.helperPlistName)
    private var connection: NSXPCConnection?

    public init() {}

    /// true when this process runs from an app bundle that carries the helper's launchd plist.
    public static var bundleCarriesHelper: Bool {
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(KeepAwakeIdentity.helperPlistName)")
        return FileManager.default.fileExists(atPath: plist.path)
    }

    public var state: HelperState {
        guard Self.bundleCarriesHelper else { return .notFound }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // before the first registration the framework reports a bundled daemon as not found.
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    public func register() throws -> HelperState {
        do {
            try service.register()
        } catch {
            // a fresh registration reports "needs approval" as an error; the status says the rest.
            if state == .requiresApproval || state == .enabled { return state }
            throw KeepAwakeError.helper("the system did not register the helper: \(error.localizedDescription)")
        }
        return state
    }

    public func unregister() throws {
        guard state == .enabled || state == .requiresApproval else { return }
        connection?.invalidate()
        connection = nil
        do {
            try service.unregister()
        } catch {
            throw KeepAwakeError.helper("the system did not remove the helper: \(error.localizedDescription)")
        }
    }

    /// open the System Settings pane where the user allows the helper.
    public static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
        guard state == .enabled else {
            throw KeepAwakeError.helper("the helper is not allowed yet (\(state.rawValue)); turn lid-closed on again to approve it")
        }
        let connection = self.connection ?? {
            let made = NSXPCConnection(machServiceName: KeepAwakeIdentity.helperLabel, options: .privileged)
            made.remoteObjectInterface = NSXPCInterface(with: KeepAwakeHelperProtocol.self)
            made.invalidationHandler = { [weak self] in self?.connection = nil }
            made.resume()
            self.connection = made
            return made
        }()
        let done = DispatchSemaphore(value: 0)
        var failure: String?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            failure = "the helper did not answer: \(error.localizedDescription)"
            done.signal()
        } as? KeepAwakeHelperProtocol
        proxy?.setSleepDisabled(disabled) { succeeded, message in
            if !succeeded { failure = message ?? "the helper refused" }
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut { failure = "the helper did not answer within 5 seconds" }
        if let failure { throw KeepAwakeError.helper(failure) }
        // when the lid-closed hold ends, drop the connection; the helper reverts on a dropped
        // connection too, so a crash here still puts the system's behavior back.
        if !disabled {
            connection.invalidate()
            self.connection = nil
        }
    }
}
