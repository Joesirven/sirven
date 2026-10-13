// sirven-keep-awake-helper: the privileged helper, run by launchd as root after the user allows
// it once in System Settings. it does one thing: turn the system's sleep-disabled setting on while
// a connected sirven holder asks for lid-closed operation, and back off the moment no one does.
// the rules live in the library (KeepAwakeHelperCore); this file only wires them to the connection and the signals.
import Foundation
import SirvenKeepAwake

let core = KeepAwakeHelperCore(guardian: SleepDisableGuard(setting: PmsetSleepSetting()))

// an earlier run that ended without reverting (a crash, a power loss) left the marker behind.
if let problem = core.revertAll() { NSLog("sirven keep-awake helper: could not revert at start: \(problem)") }

/// one per connection, so the helper knows which caller asked and can forget it when it drops.
final class Session: NSObject, KeepAwakeHelperProtocol {
    private let core: KeepAwakeHelperCore
    init(core: KeepAwakeHelperCore) { self.core = core }

    func setSleepDisabled(_ disabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let problem = core.setAsking(ObjectIdentifier(self), disabled)
        reply(problem == nil, problem)
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    private let core: KeepAwakeHelperCore
    // nil when no team identifier was built in: then every connection is refused.
    private let requirement = KeepAwakeHelperAccess.requirement(teamIdentifier: KeepAwakeHelperAccess.embeddedTeamIdentifier)

    init(core: KeepAwakeHelperCore) { self.core = core }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else {
            NSLog("sirven keep-awake helper: refusing a connection, because no team identifier was built in")
            return false
        }
        // only the signed sirven app may talk to this helper.
        connection.setCodeSigningRequirement(requirement)
        let session = Session(core: core)
        let identity = ObjectIdentifier(session)
        connection.exportedInterface = NSXPCInterface(with: KeepAwakeHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [core] in _ = core.setAsking(identity, false) }
        connection.interruptionHandler = { [core] in _ = core.setAsking(identity, false) }
        connection.resume()
        return true
    }
}

let listenerDelegate = Listener(core: core)
let listener = NSXPCListener(machServiceName: KeepAwakeIdentity.helperLabel)
listener.delegate = listenerDelegate
listener.resume()

// the termination signals are taken as dispatch sources on the main queue, so the revert runs
// in ordinary code rather than inside a signal handler.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        if let problem = core.revertAll() { NSLog("sirven keep-awake helper: could not revert on stop: \(problem)") }
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

RunLoop.main.run()
