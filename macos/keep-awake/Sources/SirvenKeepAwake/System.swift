import Foundation
import IOKit.pwr_mgt

// the two places keep-awake touches the system: power assertions through IOKit, and process
// lookups through the kernel. both sit behind protocols so the lifecycle can be tested without
// holding the Mac awake.

public protocol PowerAssertionBackend: AnyObject {
    func create(name: String, details: String) throws -> UInt32
    func update(_ assertion: UInt32, details: String)
    func release(_ assertion: UInt32)
}

/// a PreventUserIdleSystemSleep assertion: the Mac stays awake, the display may still sleep.
/// the system releases it by itself if this process exits for any reason.
public final class SystemPowerAssertions: PowerAssertionBackend {
    public init() {}

    public func create(name: String, details: String) throws -> UInt32 {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleSystemSleep as CFString, name as CFString, details as CFString,
            nil, nil, 0, nil, &assertion)
        guard result == kIOReturnSuccess else { throw KeepAwakeError.assertionFailed(result) }
        return assertion
    }

    public func update(_ assertion: UInt32, details: String) {
        IOPMAssertionSetProperty(assertion, kIOPMAssertionDetailsKey as CFString, details as CFString)
    }

    public func release(_ assertion: UInt32) {
        IOPMAssertionRelease(assertion)
    }
}

/// one power assertion as the system reports it, independent of what sirven believes it holds.
public struct SystemAssertion: Codable, Equatable {
    public var process: Int32
    public var type: String
    public var name: String
    public var details: String?
}

public enum SystemAssertionReport {
    /// every assertion the system lists for one process.
    public static func assertions(of process: Int32) -> [SystemAssertion] {
        var copied: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess, let copied else { return [] }
        let byProcess = copied.takeRetainedValue() as NSDictionary
        let entries = byProcess[NSNumber(value: process)] as? [[String: Any]] ?? []
        return entries.map {
            SystemAssertion(process: process,
                            type: $0[kIOPMAssertionTypeKey] as? String ?? "",
                            name: $0[kIOPMAssertionNameKey] as? String ?? "",
                            details: $0[kIOPMAssertionDetailsKey] as? String)
        }
    }
}

public protocol ProcessLiveness {
    /// the process's start time in seconds since 1970, or nil when no such process is running.
    func startTime(of process: Int32) -> Double?
}

public struct KernelProcessLiveness: ProcessLiveness {
    public init() {}

    public func startTime(of process: Int32) -> Double? {
        guard process > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process]
        guard sysctl(&query, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // a process that has exited but not been collected by its parent is not doing work.
        if info.kp_proc.p_stat == SZOMB { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }
}
