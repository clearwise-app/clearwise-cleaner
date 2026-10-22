import Foundation

/// Free space of the startup volume, split the way Finder hides it: really free right now vs what macOS
/// can free by itself (local Time Machine snapshots, evictable iCloud files, purgeable caches).
public struct SpaceReport: Sendable, Equatable, Codable {
    public var total: Int64
    /// `volumeAvailableCapacity`: free blocks right now.
    public var freeNow: Int64
    /// `volumeAvailableCapacityForImportantUsage`: what Finder and «Об этом Mac» call available.
    public var availableWithPurgeable: Int64
    /// Local snapshots on the startup volume, newest first.
    public var snapshots: [LocalSnapshot]

    public init(total: Int64, freeNow: Int64, availableWithPurgeable: Int64, snapshots: [LocalSnapshot] = []) {
        self.total = total
        self.freeNow = freeNow
        self.availableWithPurgeable = availableWithPurgeable
        self.snapshots = snapshots
    }

    /// Space macOS will free on demand. Never negative (the two numbers are sampled a moment apart).
    public var purgeable: Int64 { max(0, availableWithPurgeable - freeNow) }
}

public struct LocalSnapshot: Sendable, Equatable, Codable, Identifiable {
    /// "com.apple.TimeMachine.2026-10-22-101530.local".
    public var name: String
    public var date: Date?
    public var id: String { name }

    public init(name: String, date: Date?) {
        self.name = name
        self.date = date
    }
}

extension SpaceReport {
    static func read(volume: URL = URL(fileURLWithPath: "/")) -> SpaceReport? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? volume.resourceValues(forKeys: keys), let total = v.volumeTotalCapacity,
              let free = v.volumeAvailableCapacity else { return nil }
        // `tmutil listlocalsnapshots` only lists; it needs no privileges and changes nothing.
        let list = Command.run("/usr/bin/tmutil", ["listlocalsnapshots", volume.path])
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return SpaceReport(total: Int64(total), freeNow: Int64(free),
                           availableWithPurgeable: v.volumeAvailableCapacityForImportantUsage ?? Int64(free),
                           snapshots: parseSnapshots(list))
    }

    /// `tmutil listlocalsnapshots /` prints a header ("Snapshots for disk /:") and one snapshot name per line.
    static func parseSnapshots(_ output: String) -> [LocalSnapshot] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let snapshots = output.split(whereSeparator: \.isNewline).compactMap { raw -> LocalSnapshot? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasSuffix(":"), !line.contains(" ") else { return nil }
            let date = line.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression)
                .flatMap { formatter.date(from: String(line[$0])) }
            return LocalSnapshot(name: line, date: date)
        }
        return snapshots.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
