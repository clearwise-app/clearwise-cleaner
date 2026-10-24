import Foundation
import CryptoKit

/// The signed license from POST /api/license/activate (server/src/license.ts):
/// "CW1.<payload>.<signature>", base64url, Ed25519 over "CW1.<payload>".
struct LicensePayload: Codable, Equatable {
    let v: Int
    let sub: String
    let email: String
    let dev: String
    let plan: String
    let status: String
    let iat: TimeInterval
    let exp: TimeInterval
    let paidUntil: TimeInterval?

    var issuedAt: Date { Date(timeIntervalSince1970: iat) }
    var expiresAt: Date { Date(timeIntervalSince1970: exp) }
    var paidUntilDate: Date? { paidUntil.map(Date.init(timeIntervalSince1970:)) }
}

enum LicenseVerifier {
    /// The payload when the signature is ours, the token belongs to this Mac and hasn't expired.
    static func verify(_ token: String, publicKey: String = LicenseConfig.publicKey,
                       deviceID: String = DeviceIdentity.id, now: Date = Date()) -> LicensePayload? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "CW1",
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let body = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              key.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)),
              let payload = try? JSONDecoder().decode(LicensePayload.self, from: body)
        else { return nil }
        guard payload.v == 1, payload.dev == deviceID, payload.expiresAt > now else { return nil }
        return payload
    }
}

extension Data {
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
