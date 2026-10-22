import Foundation

/// The startup disk: SMART verdict, APFS container usage and, when macOS exposes them, NVMe wear counters.
public struct DriveHealth: Sendable, Equatable, Codable {
    public enum SMARTStatus: String, Sendable, Equatable, Codable {
        case verified, failing, notSupported, unknown
    }

    /// "APPLE SSD AP0512Z".
    public var model: String?
    public var smart: SMARTStatus
    public var isSolidState: Bool
    public var containerTotal: Int64?
    public var containerFree: Int64?
    public var nvme: NVMeHealth?

    public init(model: String? = nil, smart: SMARTStatus, isSolidState: Bool = true,
                containerTotal: Int64? = nil, containerFree: Int64? = nil, nvme: NVMeHealth? = nil) {
        self.model = model
        self.smart = smart
        self.isSolidState = isSolidState
        self.containerTotal = containerTotal
        self.containerFree = containerFree
        self.nvme = nvme
    }
}

/// The NVMe "SMART / Health Information" log, as `diskutil info` passes it through
/// (`SMARTDeviceSpecificKeysMayVaryNotGuaranteed`). Every field is optional: Apple does not promise any of them.
public struct NVMeHealth: Sendable, Equatable, Codable {
    /// Share of the rated write endurance used up, 0…255 (it can exceed 100).
    public var percentageUsed: Int?
    public var bytesWritten: Int64?
    public var bytesRead: Int64?
    /// Remaining spare blocks, %, and the level below which the drive reports a problem.
    public var availableSpare: Int?
    public var availableSpareThreshold: Int?
    public var powerOnHours: Int?
    public var mediaErrors: Int?
    public var unsafeShutdowns: Int?
    public var temperatureCelsius: Int?

    public init(percentageUsed: Int? = nil, bytesWritten: Int64? = nil, bytesRead: Int64? = nil,
                availableSpare: Int? = nil, availableSpareThreshold: Int? = nil, powerOnHours: Int? = nil,
                mediaErrors: Int? = nil, unsafeShutdowns: Int? = nil, temperatureCelsius: Int? = nil) {
        self.percentageUsed = percentageUsed
        self.bytesWritten = bytesWritten
        self.bytesRead = bytesRead
        self.availableSpare = availableSpare
        self.availableSpareThreshold = availableSpareThreshold
        self.powerOnHours = powerOnHours
        self.mediaErrors = mediaErrors
        self.unsafeShutdowns = unsafeShutdowns
        self.temperatureCelsius = temperatureCelsius
    }

    /// The spare pool fell to the drive's own alarm level.
    public var spareBelowThreshold: Bool {
        guard let spare = availableSpare, let threshold = availableSpareThreshold, threshold > 0 else { return false }
        return spare <= threshold
    }
}

extension DriveHealth {
    static func read(volume: String = "/") -> DriveHealth? {
        guard let info = Command.run("/usr/sbin/diskutil", ["info", "-plist", volume]).flatMap(plist) else { return nil }
        // The volume itself has no model name; its APFS physical store's whole disk does ("disk0s2" → "disk0").
        var whole: [String: Any]?
        if let store = physicalStore(info) {
            whole = Command.run("/usr/sbin/diskutil", ["info", "-plist", store]).flatMap(plist)
        }
        return parse(volume: info, wholeDisk: whole)
    }

    static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func physicalStore(_ info: [String: Any]) -> String? {
        guard let stores = info["APFSPhysicalStores"] as? [[String: Any]],
              let store = stores.first?["APFSPhysicalStore"] as? String,
              let range = store.range(of: #"^disk\d+"#, options: .regularExpression) else { return nil }
        return String(store[range])
    }

    /// - Parameters:
    ///   - volume: `diskutil info -plist /`.
    ///   - wholeDisk: `diskutil info -plist disk0` (the model name), optional.
    static func parse(volume: [String: Any], wholeDisk: [String: Any]?) -> DriveHealth {
        let smartRaw = (volume["SMARTStatus"] as? String) ?? (wholeDisk?["SMARTStatus"] as? String)
        let smart: SMARTStatus = switch smartRaw?.lowercased() {
        case "verified": .verified
        case "failing": .failing
        case "not supported": .notSupported
        default: .unknown
        }
        let model = [wholeDisk?["MediaName"], volume["MediaName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let keys = (volume["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any])
            ?? (wholeDisk?["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any])
        return DriveHealth(
            model: model,
            smart: smart,
            isSolidState: (volume["SolidState"] as? Bool) ?? true,
            containerTotal: int64(volume["APFSContainerSize"]),
            containerFree: int64(volume["APFSContainerFree"]),
            nvme: keys.flatMap(nvme)
        )
    }

    /// NVMe counts data in units of 1000 × 512 bytes; 128-bit counters arrive as `_0` (low) and `_1` (high).
    static func nvme(_ keys: [String: Any]) -> NVMeHealth? {
        func value(_ key: String) -> Int64? {
            if let v = int64(keys[key]) { return v }
            guard let low = uint64(keys[key + "_0"]) else { return nil }
            if let high = uint64(keys[key + "_1"]), high > 0 { return .max }
            return low > UInt64(Int64.max) ? .max : Int64(low)
        }
        func bytes(_ key: String) -> Int64? {
            // A counter that reads back negative is nonsense, not a crash: no value.
            value(key).flatMap { $0 < 0 ? nil : ($0 > Int64.max / 512_000 ? .max : $0 * 512_000) }
        }
        let health = NVMeHealth(
            percentageUsed: value("PERCENTAGE_USED").map { Int($0) },
            bytesWritten: bytes("DATA_UNITS_WRITTEN"),
            bytesRead: bytes("DATA_UNITS_READ"),
            availableSpare: value("AVAILABLE_SPARE").map { Int($0) },
            availableSpareThreshold: value("AVAILABLE_SPARE_THRESHOLD").map { Int($0) },
            powerOnHours: value("POWER_ON_HOURS").map { Int(clamping: $0) },
            mediaErrors: value("MEDIA_ERRORS").map { Int(clamping: $0) },
            unsafeShutdowns: value("UNSAFE_SHUTDOWNS").map { Int(clamping: $0) },
            // Kelvin, as the NVMe spec defines it.
            temperatureCelsius: value("TEMPERATURE").flatMap { $0 > 0 ? Int($0) - 273 : nil }
        )
        return health == NVMeHealth() ? nil : health
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let n as Int: return Int64(n)
        default: return nil
        }
    }

    static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let n as NSNumber: return n.uint64Value
        case let n as Int: return n >= 0 ? UInt64(n) : nil
        default: return nil
        }
    }
}
