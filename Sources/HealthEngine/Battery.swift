import Foundation
import IOKit

/// The built-in battery. Nil on Macs without one.
public struct BatteryHealth: Sendable, Equatable, Codable {
    public enum Condition: String, Sendable, Equatable, Codable {
        /// «Нормальное» in System Settings.
        case normal
        /// «Рекомендуется обслуживание».
        case serviceRecommended
    }

    public var cycleCount: Int
    /// Cycles the battery is rated for (1000 on current MacBooks).
    public var designCycleCount: Int?
    /// «Максимальная ёмкость» exactly as System Settings → Battery shows it (Apple's own figure, not recomputed).
    public var maximumCapacityPercent: Int?
    public var condition: Condition?
    /// What the gauge reports as a full charge today, mAh.
    public var fullChargeCapacity: Int?
    /// Capacity of a new battery, mAh.
    public var designCapacity: Int?
    /// Current charge, 0…100.
    public var chargePercent: Int?
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var temperatureCelsius: Double?

    public init(cycleCount: Int, designCycleCount: Int? = nil, maximumCapacityPercent: Int? = nil,
                condition: Condition? = nil, fullChargeCapacity: Int? = nil, designCapacity: Int? = nil,
                chargePercent: Int? = nil, isCharging: Bool = false, isPluggedIn: Bool = false,
                temperatureCelsius: Double? = nil) {
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.maximumCapacityPercent = maximumCapacityPercent
        self.condition = condition
        self.fullChargeCapacity = fullChargeCapacity
        self.designCapacity = designCapacity
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.temperatureCelsius = temperatureCelsius
    }
}

extension BatteryHealth {
    /// Reads the `AppleSmartBattery` registry entry and `system_profiler SPPowerDataType`. No root needed.
    static func read() -> BatteryHealth? {
        guard let registry = registryProperties() else { return nil }
        let profiler = Command.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-xml", "-detailLevel", "mini"])
        return parse(registry: registry, profiler: profiler)
    }

    static func registryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    /// - Parameters:
    ///   - registry: properties of the `AppleSmartBattery` IORegistry entry.
    ///   - profiler: `system_profiler SPPowerDataType -xml` output. It is the only unprivileged source of
    ///     Apple's «Максимальная ёмкость»: on Apple silicon `MaxCapacity` in the registry is a charge scale
    ///     (always 100), and Apple's figure matches neither raw mAh ratio exactly, so it is never recomputed.
    static func parse(registry: [String: Any], profiler: Data?) -> BatteryHealth? {
        if (registry["BatteryInstalled"] as? Bool) == false { return nil }
        let info = profiler.flatMap(profilerHealthInfo)
        guard let cycles = int(registry["CycleCount"]) ?? int(info?["sppower_battery_cycle_count"]) else { return nil }

        // Apple silicon: MaxCapacity/CurrentCapacity are percentages and the mAh live in AppleRaw*.
        // Intel: MaxCapacity/CurrentCapacity are mAh.
        let maxCapacity = int(registry["MaxCapacity"])
        let currentCapacity = int(registry["CurrentCapacity"])
        let percentScale = maxCapacity == 100
        let fullCharge = int(registry["AppleRawMaxCapacity"]) ?? (percentScale ? nil : maxCapacity)
        var charge: Int?
        if let current = currentCapacity, let max = maxCapacity, max > 0 {
            charge = percentScale ? current : Int((Double(current) / Double(max) * 100).rounded())
        }
        let temperature = int(registry["Temperature"]).flatMap { $0 > 0 ? Double($0) / 100 : nil }

        return BatteryHealth(
            cycleCount: cycles,
            designCycleCount: int(registry["DesignCycleCount9C"]),
            maximumCapacityPercent: (info?["sppower_battery_health_maximum_capacity"] as? String).flatMap(percent),
            condition: (info?["sppower_battery_health"] as? String).map(condition),
            fullChargeCapacity: fullCharge,
            designCapacity: int(registry["DesignCapacity"]),
            chargePercent: charge.map { min(100, max(0, $0)) },
            isCharging: registry["IsCharging"] as? Bool ?? false,
            isPluggedIn: registry["ExternalConnected"] as? Bool ?? false,
            temperatureCelsius: temperature
        )
    }

    /// `sppower_battery_health_info` wherever it sits in the profiler's tree. The output also has a column
    /// description under the same key (`_properties`), told apart by having no values.
    static func profilerHealthInfo(_ data: Data) -> [String: Any]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        func find(_ node: Any) -> [String: Any]? {
            if let dict = node as? [String: Any] {
                if let info = dict["sppower_battery_health_info"] as? [String: Any],
                   info["sppower_battery_health"] != nil || info["sppower_battery_cycle_count"] != nil { return info }
                for value in dict.values { if let hit = find(value) { return hit } }
            } else if let array = node as? [Any] {
                for value in array { if let hit = find(value) { return hit } }
            }
            return nil
        }
        return find(root)
    }

    /// The profiler formats the percentage for the user's locale ("87%", "%87", "87 %", "٨٧٪"): keep the digits.
    static func percent(_ text: String) -> Int? {
        let digits = text.compactMap(\.wholeNumberValue)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        return digits.reduce(0) { $0 * 10 + $1 }
    }

    /// "Good" is shown as «Нормальное»; older values ("Fair", "Poor", "Check Battery"…) all mean service.
    static func condition(_ raw: String) -> Condition {
        let r = raw.lowercased()
        return r == "good" || r == "normal" ? .normal : .serviceRecommended
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
}
