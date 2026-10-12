// sirven-keep-awake-helper: the privileged helper, run by launchd as root after the user allows
// it once in System Settings. it does one thing: turn the system's sleep-disabled setting on while
// a connected sirven holder asks for lid-closed operation, and back off the moment no one does.
//
// it puts the setting back when the last asking connection drops (a crashed holder included), and
// at its own start if a marker shows an earlier run left it on. it never touches the setting when
// the user set it themselves: the marker records that sirven turned it on.
import Foundation
import SirvenKeepAwake

let markerDirectory = URL(fileURLWithPath: "/Library/Application Support/sirven/keep-awake-helper", isDirectory: true)
let marker = markerDirectory.appendingPathComponent("sleep-disabled-by-sirven")

/// the supported command for this setting. fixed arguments only; nothing from the caller reaches it.
func setSystemSleepDisabled(_ disabled: Bool) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return "pmset could not run: \(error.localizedDescription)"
    }
    guard process.terminationStatus == 0 else { return "pmset exited with status \(process.terminationStatus)" }
    if disabled {
        try? FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    } else {
        try? FileManager.default.removeItem(at: marker)
    }
    return nil
}

final class Helper: NSObject, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "\(KeepAwakeIdentity.helperLabel).state")
    private var asking = Set<ObjectIdentifier>()
    private var applied = false

    /// one per connection, so the helper knows which caller asked and can forget it when it drops.
    final class Session: NSObject, KeepAwakeHelperProtocol {
        weak var helper: Helper?
        init(helper: Helper) { self.helper = helper }
        func setSleepDisabled(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
            guard let helper else { return reply(false, "the helper is shutting down") }
            let problem = helper.update(ObjectIdentifier(self), asking: disabled)
            reply(problem == nil, problem)
        }
    }

    func update(_ session: ObjectIdentifier, asking wants: Bool) -> String? {
        queue.sync {
            if wants { asking.insert(session) } else { asking.remove(session) }
            let wanted = !asking.isEmpty
            guard wanted != applied else { return nil }
            if let problem = setSystemSleepDisabled(wanted) {
                if wanted { asking.remove(session) }
                return problem
            }
            applied = wanted
            NSLog("sirven keep-awake helper: sleep-disabled is now \(wanted ? "on" : "off")")
            return nil
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // only the signed sirven app may talk to this helper.
        connection.setCodeSigningRequirement(KeepAwakeIdentity.clientRequirement)
        let session = Session(helper: self)
        connection.exportedInterface = NSXPCInterface(with: KeepAwakeHelperProtocol.self)
        connection.exportedObject = session
        let identity = ObjectIdentifier(session)
        connection.invalidationHandler = { [weak self] in _ = self?.update(identity, asking: false) }
        connection.interruptionHandler = { [weak self] in _ = self?.update(identity, asking: false) }
        connection.resume()
        return true
    }
}

// an earlier run that ended without reverting (a crash, a power loss) left the marker behind.
if FileManager.default.fileExists(atPath: marker.path) {
    if let problem = setSystemSleepDisabled(false) { NSLog("sirven keep-awake helper: could not revert at start: \(problem)") }
}

let helper = Helper()
let listener = NSXPCListener(machServiceName: KeepAwakeIdentity.helperLabel)
listener.delegate = helper
listener.resume()
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber) { _ in
        if FileManager.default.fileExists(atPath: marker.path) { _ = setSystemSleepDisabled(false) }
        exit(0)
    }
}
RunLoop.main.run()
