import Foundation

/// Everything «Здоровье Mac» shows. Each part is nil when this Mac has no such thing or macOS would not tell.
public struct MacHealthReport: Sendable, Equatable, Codable {
    public var battery: BatteryHealth?
    public var drive: DriveHealth?
    public var space: SpaceReport?
    /// Nil on Intel Macs: there every app is native.
    public var architectures: ArchitectureReport?
    public var vitals: SystemVitals?
    public var measuredAt: Date

    public init(battery: BatteryHealth? = nil, drive: DriveHealth? = nil, space: SpaceReport? = nil,
                architectures: ArchitectureReport? = nil, vitals: SystemVitals? = nil, measuredAt: Date = Date()) {
        self.battery = battery
        self.drive = drive
        self.space = space
        self.architectures = architectures
        self.vitals = vitals
        self.measuredAt = measuredAt
    }
}

extension MacHealthReport {
    /// Things worth the user's attention, most serious first. Only facts the hardware or macOS itself flags
    /// (or Apple's own Rosetta timeline): nothing here is a guess or a "score".
    public enum Concern: Hashable, Sendable {
        case driveFailing, driveSpareLow, batteryService, driveWornOut, memoryPressureHigh, intelOnlyApps(Int)
    }

    public var concerns: [Concern] {
        var list: [Concern] = []
        if drive?.smart == .failing { list.append(.driveFailing) }
        if drive?.nvme?.spareBelowThreshold == true { list.append(.driveSpareLow) }
        if battery?.condition == .serviceRecommended { list.append(.batteryService) }
        if let used = drive?.nvme?.percentageUsed, used >= 100 { list.append(.driveWornOut) }
        if vitals?.memoryPressure == .critical { list.append(.memoryPressureHigh) }
        if let n = architectures?.intelOnly.count, n > 0 { list.append(.intelOnlyApps(n)) }
        return list
    }
}

/// Read-only check: nothing is changed, nothing needs root, nothing keeps running afterwards.
/// About a second on a typical Mac (three short `diskutil`/`tmutil`/`system_profiler` calls and one
/// 4 KB header read per app).
public enum MacHealthCheck {
    public static func run() async -> MacHealthReport {
        async let battery = background { BatteryHealth.read() }
        async let drive = background { DriveHealth.read() }
        async let space = background { SpaceReport.read() }
        async let architectures = background { SystemVitals.isAppleSilicon ? ArchitectureReport.read() : nil }
        async let vitals = background { SystemVitals.read() }
        return await MacHealthReport(battery: battery, drive: drive, space: space,
                                     architectures: architectures, vitals: vitals, measuredAt: Date())
    }

    private static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}
