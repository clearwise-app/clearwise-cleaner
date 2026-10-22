import Foundation
import CleanerKit
import UninstallEngine

/// Which installed apps run natively on Apple silicon.
public struct AppArchitecture: Sendable, Equatable, Codable, Identifiable {
    public var url: URL
    public var name: String
    public var version: String?
    public var architectures: Set<CPUArchitecture>
    public var id: URL { url }

    public init(url: URL, name: String, version: String? = nil, architectures: Set<CPUArchitecture>) {
        self.url = url
        self.name = name
        self.version = version
        self.architectures = architectures
    }

    /// Runs on Apple silicon only through Rosetta 2.
    public var isIntelOnly: Bool { !architectures.contains(.arm64) && architectures.contains(where: \.isIntel) }
    public var isUniversal: Bool { architectures.contains(.arm64) && architectures.contains(where: \.isIntel) }
}

public struct ArchitectureReport: Sendable, Equatable, Codable {
    /// Every app whose main executable could be read, by name.
    public var apps: [AppArchitecture]

    public init(apps: [AppArchitecture]) { self.apps = apps }

    public var intelOnly: [AppArchitecture] { apps.filter(\.isIntelOnly) }
    public var universalCount: Int { apps.filter(\.isUniversal).count }
    public var appleSiliconOnlyCount: Int { apps.filter { $0.architectures == [.arm64] }.count }
}

extension ArchitectureReport {
    /// Third-party apps only: apps that are part of macOS are always native.
    static func read() -> ArchitectureReport {
        let apps = AppInventory.quickList().filter { !$0.isSystemApp }
        return scan(apps.map { ($0.url, $0.name, $0.version) })
    }

    static func scan(_ apps: [(url: URL, name: String, version: String?)]) -> ArchitectureReport {
        let found = apps.compactMap { app -> AppArchitecture? in
            guard let exe = mainExecutable(of: app.url), let archs = MachO.architectures(atPath: exe.path),
                  !archs.isEmpty else { return nil }
            return AppArchitecture(url: app.url, name: app.name, version: app.version, architectures: archs)
        }
        return ArchitectureReport(apps: found)
    }

    /// `Contents/MacOS/<CFBundleExecutable>`. iPhone and iPad apps (`Wrapper/`) are skipped: they are arm64 only.
    static func mainExecutable(of app: URL) -> URL? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let name = dict["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
        return app.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
    }
}
