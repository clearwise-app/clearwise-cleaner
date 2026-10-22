import Foundation

/// The fields of a launchd job plist this screen needs. Pure: parsing never touches launchd.
struct LaunchdPlist: Equatable {
    var label: String?
    var program: String?
    /// SMAppService plists inside an app: the program's path relative to the app bundle.
    var bundleProgram: String?
    var arguments: [String] = []
    var runAtLoad = false
    var keepAlive = false
    var interval: Int?
    var disabled = false
    var associatedBundleIDs: [String] = []

    /// Nil when the file cannot be read or is not a dictionary plist.
    static func read(_ url: URL) -> LaunchdPlist? {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return LaunchdPlist(dict)
    }

    init(label: String? = nil, program: String? = nil) {
        self.label = label
        self.program = program
    }

    init(_ dict: [String: Any]) {
        label = (dict["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        arguments = dict["ProgramArguments"] as? [String] ?? []
        if let p = dict["Program"] as? String, !p.isEmpty { program = p } else { program = arguments.first }
        bundleProgram = (dict["BundleProgram"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        runAtLoad = dict["RunAtLoad"] as? Bool ?? false
        // KeepAlive is a bool or a dictionary of conditions; either way launchd may restart the job.
        if let b = dict["KeepAlive"] as? Bool { keepAlive = b } else { keepAlive = dict["KeepAlive"] is [String: Any] }
        interval = (dict["StartInterval"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        disabled = dict["Disabled"] as? Bool ?? false
        if let ids = dict["AssociatedBundleIdentifiers"] as? [String] { associatedBundleIDs = ids }
        else if let id = dict["AssociatedBundleIdentifiers"] as? String { associatedBundleIDs = [id] }
    }
}

/// Parsers for `launchctl print` output. Its format is not an API, so everything here is lenient:
/// an unrecognised line is skipped, never guessed.
enum LaunchctlOutput {
    /// `launchctl print <domain>` → label → pid (nil when loaded but not running).
    /// Reads the `services = { … }` block: lines like `   73581      -  com.foo.agent`.
    static func services(_ text: String) -> [String: Int?] {
        var result: [String: Int?] = [:]
        var inside = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inside {
                if line == "services = {" { inside = true }
                continue
            }
            if line == "}" { break }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3 else { continue }
            let pid = Int(parts[0])
            guard pid != nil || parts[0] == "-" else { continue }
            result[String(parts[2])] = pid.flatMap { $0 > 0 ? $0 : nil }
        }
        return result
    }

    /// `launchctl print-disabled <domain>` → label → disabled. Accepts both `=> disabled/enabled`
    /// (macOS 12+) and the older `=> true/false`.
    static func disabled(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let arrow = line.range(of: "\" => ") else { continue }
            let label = String(line[line.index(after: line.startIndex)..<arrow.lowerBound])
            switch line[arrow.upperBound...].trimmingCharacters(in: .whitespaces) {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }
}
