import Foundation
import Security

/// Who signed a program, from its code signature. Basic validation only (the signature and its
/// certificate chain, not every resource of a bundle), so a check takes milliseconds.
enum CodeSignature {
    private static let appleRequirement = "anchor apple"
    private static let appStoreRequirement = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]"
    private static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13]"

    static func signer(ofPath path: String) -> Signer {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return .unknown }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return .unknown }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return .unknown }
        // No identifier: the file is not signed at all.
        guard dict[kSecCodeInfoIdentifier as String] != nil else { return .unsigned }
        let codeFlags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if codeFlags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return .adHoc }

        let basic = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSDoNotValidateExecutable)
        if SecStaticCodeCheckValidity(code, basic, nil) != errSecSuccess { return .invalid }
        if satisfies(code, appleRequirement, basic) { return .apple }
        if satisfies(code, appStoreRequirement, basic) { return .appStore }

        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let name = leafName(dict)
        if satisfies(code, developerIDRequirement, basic) { return .developerID(name: name, team: team) }
        return .other(name: name, team: team)
    }

    private static func satisfies(_ code: SecStaticCode, _ text: String, _ flags: SecCSFlags) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// "Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC".
    private static func leafName(_ dict: [String: Any]) -> String? {
        guard let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return nil }
        return developerName(fromCertificate: summary)
    }

    static func developerName(fromCertificate summary: String) -> String {
        var name = summary
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        return name
    }
}
