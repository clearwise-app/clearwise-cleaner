import Foundation
import Darwin

/// A one-off look at memory and uptime (read once per check; nothing is monitored).
public struct SystemVitals: Sendable, Equatable, Codable {
    /// The same three levels as the «Давление памяти» graph in Activity Monitor.
    public enum MemoryPressure: String, Sendable, Equatable, Codable {
        case normal, warning, critical, unknown

        /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
        init(level: Int?) {
            switch level {
            case 1: self = .normal
            case 2: self = .warning
            case 4: self = .critical
            default: self = .unknown
            }
        }
    }

    public var physicalMemory: Int64
    public var memoryPressure: MemoryPressure
    public var swapUsed: Int64?
    public var bootTime: Date?

    public init(physicalMemory: Int64, memoryPressure: MemoryPressure, swapUsed: Int64? = nil, bootTime: Date? = nil) {
        self.physicalMemory = physicalMemory
        self.memoryPressure = memoryPressure
        self.swapUsed = swapUsed
        self.bootTime = bootTime
    }
}

extension SystemVitals {
    static func read() -> SystemVitals {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : nil

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? Int64(swap.xsu_used) : nil

        var boot = timeval()
        size = MemoryLayout<timeval>.size
        let bootTime = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 && boot.tv_sec > 0
            ? Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)) : nil

        return SystemVitals(physicalMemory: Int64(ProcessInfo.processInfo.physicalMemory),
                            memoryPressure: MemoryPressure(level: pressure), swapUsed: swapUsed, bootTime: bootTime)
    }

    /// True on Apple silicon, also when this process itself runs under Rosetta.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}
