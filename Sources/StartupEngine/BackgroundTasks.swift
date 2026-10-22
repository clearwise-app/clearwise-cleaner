import Foundation

/// One record of the Background Task Management database (what System Settings → Login Items shows),
/// as printed by `sfltool dumpbtm`.
struct BTMRecord: Equatable {
    struct Kind: OptionSet, Equatable {
        let rawValue: Int
        static let userItem = Kind(rawValue: 0x1)       // legacy «Open at Login» list
        static let app = Kind(rawValue: 0x2)            // parent record of an app's items
        static let loginItem = Kind(rawValue: 0x4)
        static let agent = Kind(rawValue: 0x8)
        static let daemon = Kind(rawValue: 0x10)
        static let developer = Kind(rawValue: 0x20)     // grouping record, not something that runs
        static let legacy = Kind(rawValue: 0x10000)     // a plist in /Library or ~/Library LaunchAgents/Daemons
    }

    var uid: Int
    var name: String?
    var developerName: String?
    var teamID: String?
    var kind: Kind = []
    var typeName = ""
    var enabled = false
    var identifier = ""
    var url: String?
    var executablePath: String?
    var bundleID: String?
    var associatedBundleIDs: [String] = []
    var parentIdentifier: String?

    /// Something that starts by itself and is not a plain plist job (those are read from their folders).
    var isStandaloneStartupItem: Bool {
        !kind.contains(.legacy) && !kind.isDisjoint(with: [.userItem, .loginItem, .agent, .daemon])
    }
}

/// Parses `sfltool dumpbtm`. The format is undocumented, so the parser only trusts what it recognises:
/// a record without an identifier or a type is dropped, and output with no «Records for UID» header
/// at all counts as unreadable (the screen then says login items could not be read).
enum BTMDump {
    enum Result: Equatable {
        case records([BTMRecord])
        case unreadable
    }

    static func parse(_ text: String) -> Result {
        var records: [BTMRecord] = []
        var sawHeader = false
        var uid: Int?
        var current: BTMRecord?

        func flush() {
            if let r = current, !r.identifier.isEmpty, !r.kind.isEmpty || !r.typeName.isEmpty { records.append(r) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") {
                flush()
                sawHeader = true
                let rest = line.dropFirst("Records for UID ".count)
                uid = Int(rest.prefix { $0 == "-" || $0.isNumber })
                continue
            }
            if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                flush()
                current = uid.map { BTMRecord(uid: $0) }
                continue
            }
            guard current != nil, let colon = line.range(of: ": ") else { continue }
            let key = String(line[..<colon.lowerBound])
            let value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            let text = value == "(null)" || value.isEmpty ? nil : value
            switch key {
            case "Name": current?.name = text
            case "Developer Name": current?.developerName = text
            case "Team Identifier": current?.teamID = text
            case "Type":
                current?.typeName = value.components(separatedBy: " (").first ?? value
                current?.kind = kindValue(value)
            case "Disposition": current?.enabled = isEnabled(value)
            case "Identifier": current?.identifier = value
            case "URL": current?.url = text
            case "Executable Path": current?.executablePath = text
            case "Bundle Identifier": current?.bundleID = text
            case "Parent Identifier": current?.parentIdentifier = text
            case "Assoc. Bundle IDs": current?.associatedBundleIDs = list(value)
            default: break
            }
        }
        flush()
        return sawHeader ? .records(records) : .unreadable
    }

    /// `curated legacy daemon (0x90010)` → bits from the hex value; without one, from the words.
    static func kindValue(_ value: String) -> BTMRecord.Kind {
        if let hex = hexInParens(value) { return BTMRecord.Kind(rawValue: hex) }
        let words = Set(value.lowercased().split(separator: " ").map(String.init))
        var kind: BTMRecord.Kind = []
        if words.contains("legacy") { kind.insert(.legacy) }
        if words.contains("agent") { kind.insert(.agent) }
        if words.contains("daemon") { kind.insert(.daemon) }
        if words.contains("app") { kind.insert(.app) }
        if words.contains("developer") { kind.insert(.developer) }
        if value.lowercased().contains("login item") { kind.insert(.loginItem) }
        if value.lowercased().contains("user item") { kind.insert(.userItem) }
        return kind
    }

    /// `[enabled, allowed, notified] (0xb)`: the words are explicit («disabled» vs «enabled»); bit 0x1 otherwise.
    static func isEnabled(_ value: String) -> Bool {
        let words = value.lowercased().components(separatedBy: CharacterSet(charactersIn: "[], ")).filter { !$0.isEmpty }
        if words.contains("disabled") { return false }
        if words.contains("enabled") { return true }
        return (hexInParens(value) ?? 0) & 0x1 != 0
    }

    private static func hexInParens(_ value: String) -> Int? {
        guard let open = value.range(of: "(", options: .backwards), value.hasSuffix(")") else { return nil }
        let inner = value[open.upperBound..<value.index(before: value.endIndex)]
        if inner.hasPrefix("0x") { return Int(inner.dropFirst(2), radix: 16) }
        return Int(inner)
    }

    /// `[ com.foo, com.bar ]`
    private static func list(_ value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
