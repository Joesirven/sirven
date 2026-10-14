import Foundation

// the privileged helper's rules, apart from XPC and root. the executable
// (Sources/sirven-keep-awake-helper) wires this to the connection and the termination signals; the tests
// drive it directly with a fake setting.

/// which connections ask for lid-closed operation. the system's setting stays on while any of them
/// asks, goes back to the system's own when none does, and is checked again every interval while a
/// hold is active, so a setting cleared by something else comes back. a connection that drops is
/// the same as one that stopped asking.
public final class KeepAwakeHelperCore {
    /// how often the setting is checked again during a hold.
    public static let defaultInterval: TimeInterval = 15

    private let queue = DispatchQueue(label: "\(KeepAwakeIdentity.helperLabel).state")
    private let guardian: SleepDisableGuard
    private let interval: TimeInterval
    private let log: (String) -> Void
    private var asking = Set<ObjectIdentifier>()
    private var timer: DispatchSourceTimer?

    public init(guardian: SleepDisableGuard, interval: TimeInterval = KeepAwakeHelperCore.defaultInterval,
                log: @escaping (String) -> Void = { message in NSLog("sirven keep-awake helper: %@", message) }) {
        self.guardian = guardian
        self.interval = interval
        self.log = log
    }

    /// a connection asks (wants true) or stops asking (false). returns a problem to report, or nil.
    @discardableResult
    public func setAsking(_ connection: ObjectIdentifier, _ wants: Bool) -> String? {
        queue.sync {
            if wants { asking.insert(connection) } else { asking.remove(connection) }
            if asking.isEmpty {
                stopTimer()
                return apply(false)
            }
            let problem = apply(true)
            if problem == nil {
                startTimer()
            } else if wants {
                // the request failed, so this connection holds nothing.
                asking.remove(connection)
            }
            return problem
        }
    }

    /// put the system's own setting back and forget every connection. used at the helper's start
    /// (an earlier run may have been killed mid-hold) and on a termination signal.
    @discardableResult
    public func revertAll() -> String? {
        queue.sync {
            asking.removeAll()
            stopTimer()
            return apply(false)
        }
    }

    /// check the setting once, now. the timer calls this during a hold; tests call it directly.
    public func recheck() {
        queue.sync { recheckLocked() }
    }

    /// the number of connections that currently ask.
    public var askingCount: Int { queue.sync { asking.count } }

    private func apply(_ wanted: Bool) -> String? {
        do {
            if try guardian.enforce(wanted) {
                log(wanted ? "sleep-disabled is now on for sirven" : "sleep-disabled is back to the system's own setting")
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// runs on the queue (from the timer, or from recheck), so it must not take the queue again.
    private func recheckLocked() {
        guard !asking.isEmpty else {
            stopTimer()
            return
        }
        do {
            if try guardian.enforce(true) { log("sleep-disabled was cleared during a hold; asserted again") }
        } catch {
            log("could not assert sleep-disabled again: \(error)")
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let made = DispatchSource.makeTimerSource(queue: queue)
        made.schedule(deadline: .now() + interval, repeating: interval)
        made.setEventHandler { [weak self] in self?.recheckLocked() }
        made.resume()
        timer = made
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
