import XCTest
@testable import HealthEngine

// MARK: - Fixtures (shapes copied from real `ioreg` / `system_profiler` / `diskutil` / `tmutil` output)

private func plist(_ xmlBody: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">\(xmlBody)</plist>
    """.utf8)
}

private func dict(_ xmlBody: String) -> [String: Any] {
    (try! PropertyListSerialization.propertyList(from: plist(xmlBody), format: nil)) as! [String: Any]
}

/// `ioreg -rc AppleSmartBattery -a` on an Apple silicon MacBook (trimmed).
private let appleSiliconRegistry = dict("""
<dict>
    <key>AppleRawCurrentCapacity</key><integer>1614</integer>
    <key>AppleRawMaxCapacity</key><integer>4615</integer>
    <key>BatteryInstalled</key><true/>
    <key>CurrentCapacity</key><integer>36</integer>
    <key>CycleCount</key><integer>4</integer>
    <key>DesignCapacity</key><integer>4629</integer>
    <key>DesignCycleCount9C</key><integer>1000</integer>
    <key>ExternalConnected</key><false/>
    <key>IsCharging</key><false/>
    <key>MaxCapacity</key><integer>100</integer>
    <key>NominalChargeCapacity</key><integer>4742</integer>
    <key>Temperature</key><integer>3072</integer>
</dict>
""")

/// `system_profiler SPPowerDataType -xml`: the battery item plus the `_properties` column description that
/// reuses the key `sppower_battery_health_info`.
private func profiler(maximumCapacity: String?, health: String = "Good", cycles: Int = 4) -> Data {
    let capacity = maximumCapacity.map { "<key>sppower_battery_health_maximum_capacity</key><string>\($0)</string>" } ?? ""
    return plist("""
    <array><dict>
        <key>_dataType</key><string>SPPowerDataType</string>
        <key>_properties</key><dict>
            <key>sppower_battery_health_info</key><dict><key>_isColumn</key><string>NO</string><key>_order</key><string>3</string></dict>
        </dict>
        <key>_items</key><array>
            <dict>
                <key>_name</key><string>spbattery_information</string>
                <key>sppower_battery_charge_info</key><dict><key>sppower_battery_state_of_charge</key><integer>36</integer></dict>
                <key>sppower_battery_health_info</key><dict>
                    <key>sppower_battery_cycle_count</key><integer>\(cycles)</integer>
                    <key>sppower_battery_health</key><string>\(health)</string>
                    \(capacity)
                </dict>
            </dict>
            <dict><key>_name</key><string>sppower_ac_charger_information</string></dict>
        </array>
    </dict></array>
    """)
}

final class BatteryTests: XCTestCase {
    func testAppleSiliconUsesApplesMaximumCapacityAndRawMilliampHours() throws {
        let b = try XCTUnwrap(BatteryHealth.parse(registry: appleSiliconRegistry, profiler: profiler(maximumCapacity: "100%")))
        XCTAssertEqual(b.cycleCount, 4)
        XCTAssertEqual(b.designCycleCount, 1000)
        XCTAssertEqual(b.maximumCapacityPercent, 100)
        XCTAssertEqual(b.condition, .normal)
        // AppleRawMaxCapacity, not MaxCapacity (a 0…100 charge scale on Apple silicon).
        XCTAssertEqual(b.fullChargeCapacity, 4615)
        XCTAssertEqual(b.designCapacity, 4629)
        XCTAssertEqual(b.chargePercent, 36)
        XCTAssertEqual(try XCTUnwrap(b.temperatureCelsius), 30.72, accuracy: 0.001)
        XCTAssertFalse(b.isCharging)
    }

    func testMaximumCapacityIsNeverRecomputedFromRawNumbers() throws {
        // Apple says 87 % although 4615 / 4629 ≈ 99,7 %: Apple's figure wins.
        let b = try XCTUnwrap(BatteryHealth.parse(registry: appleSiliconRegistry, profiler: profiler(maximumCapacity: "87%")))
        XCTAssertEqual(b.maximumCapacityPercent, 87)
        // Without the profiler there is no percentage at all rather than an invented one.
        let none = try XCTUnwrap(BatteryHealth.parse(registry: appleSiliconRegistry, profiler: nil))
        XCTAssertNil(none.maximumCapacityPercent)
        XCTAssertNil(none.condition)
        XCTAssertEqual(none.cycleCount, 4)
    }

    func testPercentInAnyLocaleFormat() {
        XCTAssertEqual(BatteryHealth.percent("%100"), 100)   // Turkish-style, as seen on a real Mac
        XCTAssertEqual(BatteryHealth.percent("87 %"), 87)
        XCTAssertEqual(BatteryHealth.percent("87\u{00A0}%"), 87)
        XCTAssertEqual(BatteryHealth.percent("٨٧٪"), 87)       // Arabic-Indic digits
        XCTAssertNil(BatteryHealth.percent("—"))
        XCTAssertNil(BatteryHealth.percent("12345%"))
    }

    func testConditionMapping() throws {
        let service = try XCTUnwrap(BatteryHealth.parse(registry: appleSiliconRegistry,
                                                        profiler: profiler(maximumCapacity: "79%", health: "Service Recommended")))
        XCTAssertEqual(service.condition, .serviceRecommended)
        XCTAssertEqual(BatteryHealth.condition("Fair"), .serviceRecommended)
        XCTAssertEqual(BatteryHealth.condition("Good"), .normal)
    }

    func testIntelRegistryKeepsMilliampHoursInMaxCapacity() throws {
        let intel = dict("""
        <dict>
            <key>CurrentCapacity</key><integer>2950</integer>
            <key>CycleCount</key><integer>612</integer>
            <key>DesignCapacity</key><integer>6669</integer>
            <key>ExternalConnected</key><true/>
            <key>IsCharging</key><true/>
            <key>MaxCapacity</key><integer>5900</integer>
            <key>Temperature</key><integer>2981</integer>
        </dict>
        """)
        let b = try XCTUnwrap(BatteryHealth.parse(registry: intel, profiler: nil))
        XCTAssertEqual(b.fullChargeCapacity, 5900)
        XCTAssertEqual(b.chargePercent, 50)
        XCTAssertTrue(b.isCharging)
        XCTAssertTrue(b.isPluggedIn)
        XCTAssertNil(b.designCycleCount)
    }

    func testNoBattery() {
        XCTAssertNil(BatteryHealth.parse(registry: ["BatteryInstalled": false, "CycleCount": 0], profiler: nil))
        XCTAssertNil(BatteryHealth.parse(registry: [:], profiler: nil))
    }
}

// MARK: - Drive

/// `diskutil info -plist /` on an Apple silicon Mac (trimmed).
private let volumeInfo = dict("""
<dict>
    <key>APFSContainerFree</key><integer>312865980416</integer>
    <key>APFSContainerSize</key><integer>494332366848</integer>
    <key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk0s2</string></dict></array>
    <key>MediaName</key><string></string>
    <key>SMARTDeviceSpecificKeysMayVaryNotGuaranteed</key><dict>
        <key>AVAILABLE_SPARE</key><integer>100</integer>
        <key>AVAILABLE_SPARE_THRESHOLD</key><integer>99</integer>
        <key>DATA_UNITS_READ_0</key><integer>3290345</integer>
        <key>DATA_UNITS_READ_1</key><integer>0</integer>
        <key>DATA_UNITS_WRITTEN_0</key><integer>1315317</integer>
        <key>DATA_UNITS_WRITTEN_1</key><integer>0</integer>
        <key>MEDIA_ERRORS_0</key><integer>0</integer>
        <key>MEDIA_ERRORS_1</key><integer>0</integer>
        <key>PERCENTAGE_USED</key><integer>3</integer>
        <key>POWER_ON_HOURS_0</key><integer>1210</integer>
        <key>POWER_ON_HOURS_1</key><integer>0</integer>
        <key>TEMPERATURE</key><integer>317</integer>
        <key>UNSAFE_SHUTDOWNS_0</key><integer>3</integer>
        <key>UNSAFE_SHUTDOWNS_1</key><integer>0</integer>
    </dict>
    <key>SMARTStatus</key><string>Verified</string>
    <key>SolidState</key><true/>
</dict>
""")

final class DriveTests: XCTestCase {
    func testParsesSMARTContainerAndNVMeCounters() throws {
        let whole = dict("<dict><key>MediaName</key><string>APPLE SSD AP0512Z</string></dict>")
        let d = DriveHealth.parse(volume: volumeInfo, wholeDisk: whole)
        XCTAssertEqual(d.smart, .verified)
        XCTAssertEqual(d.model, "APPLE SSD AP0512Z")
        XCTAssertEqual(d.containerTotal, 494_332_366_848)
        XCTAssertEqual(d.containerFree, 312_865_980_416)
        let n = try XCTUnwrap(d.nvme)
        XCTAssertEqual(n.percentageUsed, 3)
        XCTAssertEqual(n.bytesWritten, 1_315_317 * 512_000)   // NVMe data unit = 1000 × 512 bytes
        XCTAssertEqual(n.bytesRead, 3_290_345 * 512_000)
        XCTAssertEqual(n.availableSpare, 100)
        XCTAssertEqual(n.availableSpareThreshold, 99)
        XCTAssertFalse(n.spareBelowThreshold)
        XCTAssertEqual(n.powerOnHours, 1210)
        XCTAssertEqual(n.mediaErrors, 0)
        XCTAssertEqual(n.unsafeShutdowns, 3)
        XCTAssertEqual(n.temperatureCelsius, 44)               // 317 K
    }

    func testPhysicalStoreWholeDisk() {
        XCTAssertEqual(DriveHealth.physicalStore(volumeInfo), "disk0")
        XCTAssertNil(DriveHealth.physicalStore([:]))
    }

    func testWithoutNVMeKeysThereIsNoWearData() {
        var info = volumeInfo
        info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] = nil
        info["SMARTStatus"] = "Not Supported"
        let d = DriveHealth.parse(volume: info, wholeDisk: nil)
        XCTAssertNil(d.nvme)
        XCTAssertEqual(d.smart, .notSupported)
        XCTAssertNil(d.model)
    }

    func testFailingAndSpareAlarm() throws {
        var info = volumeInfo
        info["SMARTStatus"] = "Failing"
        var keys = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as! [String: Any]
        keys["AVAILABLE_SPARE"] = 10
        keys["AVAILABLE_SPARE_THRESHOLD"] = 10
        keys["DATA_UNITS_WRITTEN_1"] = 1     // beyond 64 bits: clamped, never wraps
        info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] = keys
        let d = DriveHealth.parse(volume: info, wholeDisk: nil)
        XCTAssertEqual(d.smart, .failing)
        XCTAssertTrue(try XCTUnwrap(d.nvme).spareBelowThreshold)
        XCTAssertEqual(d.nvme?.bytesWritten, .max)
    }
}

// MARK: - Snapshots

final class SnapshotTests: XCTestCase {
    func testParsesTmutilListing() throws {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-21-221502.local
        com.apple.TimeMachine.2026-10-22-091233.local
        com.apple.os.update-4E2B1C

        """
        let list = SpaceReport.parseSnapshots(output)
        XCTAssertEqual(list.map(\.name), ["com.apple.TimeMachine.2026-10-22-091233.local",
                                          "com.apple.TimeMachine.2026-10-21-221502.local",
                                          "com.apple.os.update-4E2B1C"])
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try XCTUnwrap(list[0].date))
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 10, 22, 9, 12, 33])
        XCTAssertNil(list[2].date)
    }

    func testEmptyListing() {
        XCTAssertEqual(SpaceReport.parseSnapshots("Snapshots for disk /:\n"), [])
        XCTAssertEqual(SpaceReport.parseSnapshots(""), [])
    }

    func testPurgeableIsNeverNegative() {
        XCTAssertEqual(SpaceReport(total: 100, freeNow: 30, availableWithPurgeable: 42).purgeable, 12)
        XCTAssertEqual(SpaceReport(total: 100, freeNow: 30, availableWithPurgeable: 29).purgeable, 0)
    }
}

// MARK: - Mach-O

private enum Header {
    static func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func le(_ v: UInt32) -> [UInt8] { be(v).reversed() }

    static let arm64: UInt32 = 0x0100_000C
    static let x86_64: UInt32 = 0x0100_0007

    /// Little-endian 64-bit thin header (what clang emits for both Intel and Apple silicon).
    static func thin(_ cpu: UInt32) -> Data { Data(le(0xFEED_FACF) + le(cpu) + le(0) + le(2) + [UInt8](repeating: 0, count: 16)) }

    /// Fat (universal) header: big-endian, 20-byte `fat_arch` or 32-byte `fat_arch_64` entries.
    static func fat(_ cpus: [UInt32], wide: Bool = false) -> Data {
        var bytes = be(wide ? 0xCAFE_BABF : 0xCAFE_BABE) + be(UInt32(cpus.count))
        for (i, cpu) in cpus.enumerated() {
            bytes += be(cpu) + be(0)
            if wide {
                bytes += be(0) + be(UInt32(0x4000 * (i + 1))) + be(0) + be(0x1000) + be(14) + be(0)
            } else {
                bytes += be(UInt32(0x4000 * (i + 1))) + be(0x1000) + be(14)
            }
        }
        return Data(bytes)
    }
}

final class MachOTests: XCTestCase {
    func testThinAndFatHeaders() {
        XCTAssertEqual(MachO.architectures(header: Header.thin(Header.arm64)), [.arm64])
        XCTAssertEqual(MachO.architectures(header: Header.thin(Header.x86_64)), [.x86_64])
        XCTAssertEqual(MachO.architectures(header: Header.fat([Header.x86_64, Header.arm64])), [.x86_64, .arm64])
        XCTAssertEqual(MachO.architectures(header: Header.fat([Header.x86_64, Header.arm64], wide: true)), [.x86_64, .arm64])
        XCTAssertEqual(MachO.architectures(header: Header.fat([7, 18])), [.i386, .powerPC])
    }

    func testNotMachO() {
        XCTAssertNil(MachO.architectures(header: Data("#!/bin/sh\nexec java -jar app.jar\n".utf8)))
        // A Java class file: same magic, then minor/major version (0, 52) — "52 slices" is rejected.
        XCTAssertNil(MachO.architectures(header: Data(Header.be(0xCAFE_BABE) + [0, 0, 0, 52])))
        XCTAssertNil(MachO.architectures(header: Data([0xCA, 0xFE])))
        // Truncated fat header: claims two slices, holds one.
        XCTAssertNil(MachO.architectures(header: Header.fat([Header.x86_64, Header.arm64]).prefix(8 + 20)))
    }

    func testAppKinds() {
        let intel = AppArchitecture(url: URL(fileURLWithPath: "/A.app"), name: "A", architectures: [.x86_64])
        let universal = AppArchitecture(url: URL(fileURLWithPath: "/B.app"), name: "B", architectures: [.x86_64, .arm64])
        let native = AppArchitecture(url: URL(fileURLWithPath: "/C.app"), name: "C", architectures: [.arm64])
        XCTAssertTrue(intel.isIntelOnly)
        XCTAssertFalse(universal.isIntelOnly)
        XCTAssertTrue(universal.isUniversal)
        XCTAssertFalse(native.isUniversal)
        let report = ArchitectureReport(apps: [intel, universal, native])
        XCTAssertEqual(report.intelOnly.map(\.name), ["A"])
        XCTAssertEqual(report.universalCount, 1)
        XCTAssertEqual(report.appleSiliconOnlyCount, 1)
    }
}

final class ArchitectureScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HealthEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(_ name: String, executable: Data?, plistExecutable: String? = nil) throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = plistExecutable ?? name
        let info: [String: Any] = ["CFBundleExecutable": exe, "CFBundleName": name]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if let executable { try executable.write(to: macOS.appendingPathComponent(exe)) }
        return app
    }

    func testScansMainExecutables() throws {
        let old = try makeApp("OldTool", executable: Header.thin(Header.x86_64) + Data(count: 64))
        let both = try makeApp("Both", executable: Header.fat([Header.x86_64, Header.arm64]))
        let new = try makeApp("New", executable: Header.thin(Header.arm64))
        let script = try makeApp("Script", executable: Data("#!/bin/sh\n".utf8))
        let missing = try makeApp("Missing", executable: nil)
        let escape = try makeApp("Escape", executable: nil, plistExecutable: "../../../etc/passwd")

        let report = ArchitectureReport.scan([old, both, new, script, missing, escape].map {
            (url: $0, name: $0.deletingPathExtension().lastPathComponent, version: nil)
        })
        XCTAssertEqual(report.apps.map(\.name), ["OldTool", "Both", "New"])
        XCTAssertEqual(report.intelOnly.map(\.name), ["OldTool"])
        XCTAssertEqual(report.universalCount, 1)
    }
}

// MARK: - Vitals

final class VitalsTests: XCTestCase {
    func testPressureLevels() {
        XCTAssertEqual(SystemVitals.MemoryPressure(level: 1), .normal)
        XCTAssertEqual(SystemVitals.MemoryPressure(level: 2), .warning)
        XCTAssertEqual(SystemVitals.MemoryPressure(level: 4), .critical)
        XCTAssertEqual(SystemVitals.MemoryPressure(level: nil), .unknown)
    }

    func testConcernsOnlyFromFlaggedFacts() {
        var report = MacHealthReport(
            battery: BatteryHealth(cycleCount: 900, maximumCapacityPercent: 81, condition: .normal),
            drive: DriveHealth(smart: .verified, nvme: NVMeHealth(percentageUsed: 40, availableSpare: 100, availableSpareThreshold: 10)),
            architectures: ArchitectureReport(apps: [AppArchitecture(url: URL(fileURLWithPath: "/N.app"), name: "N", architectures: [.arm64])]),
            vitals: SystemVitals(physicalMemory: 8, memoryPressure: .warning))
        XCTAssertEqual(report.concerns, [])   // 81 %, 900 cycles, 40 % wear, a busy moment: all normal

        report.battery?.condition = .serviceRecommended
        report.drive?.smart = .failing
        report.vitals?.memoryPressure = .critical
        report.architectures?.apps.append(AppArchitecture(url: URL(fileURLWithPath: "/I.app"), name: "I", architectures: [.x86_64]))
        XCTAssertEqual(report.concerns, [.driveFailing, .batteryService, .memoryPressureHigh, .intelOnlyApps(1)])
    }

    /// Smoke test on the real machine: the check finishes and never throws away what it could read.
    func testLiveCheckCompletes() async {
        let report = await MacHealthCheck.run()
        XCTAssertNotNil(report.vitals)
        XCTAssertGreaterThan(report.vitals?.physicalMemory ?? 0, 0)
        XCTAssertNotNil(report.space)
        XCTAssertNotNil(report.drive)
    }
}
