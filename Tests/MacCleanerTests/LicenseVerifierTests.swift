import XCTest
@testable import MacCleaner

/// The token below was signed by the server (server/src/license.ts) with a throwaway key pair:
/// this proves CryptoKit accepts the server's Ed25519 signatures and payload format.
final class LicenseVerifierTests: XCTestCase {
    private let publicKey = "0XDPOxKU5cpYEllw5RoyAfqxdsYkS5alILN4mT5Yd7Q="
    private let token = "CW1.eyJ2IjoxLCJzdWIiOiJhY2MtMSIsImVtYWlsIjoiZGltYUBleGFtcGxlLmNvbSIsImRldiI6InRlc3QtZGV2aWNlLTAwMDAwMDAwMDAwMDAwMDAwMDEiLCJwbGFuIjoieWVhcmx5Iiwic3RhdHVzIjoiYWN0aXZlIiwiaWF0IjoxNzkwMDAwMDAwLCJleHAiOjE4MDAwMDAwMDAsInBhaWRVbnRpbCI6MTgyMDAwMDAwMH0.qA0vXqZpqXDhKMoM_vFhq1V_Bs1RGM2JPOQZ58PF9NsaU7joCUZhUN1p7i3lyzHKcZ27d4BXy1JkkxSqH0DiBQ"
    private let device = "test-device-0000000000000000001"
    private let beforeExpiry = Date(timeIntervalSince1970: 1_795_000_000)

    func testServerTokenVerifies() throws {
        let payload = try XCTUnwrap(LicenseVerifier.verify(token, publicKey: publicKey, deviceID: device, now: beforeExpiry))
        XCTAssertEqual(payload.email, "dima@example.com")
        XCTAssertEqual(payload.plan, "yearly")
        XCTAssertEqual(payload.paidUntilDate, Date(timeIntervalSince1970: 1_820_000_000))
    }

    func testRejectsOtherMacExpiredAndTampered() {
        XCTAssertNil(LicenseVerifier.verify(token, publicKey: publicKey, deviceID: "another-mac-000000000000000000", now: beforeExpiry))
        XCTAssertNil(LicenseVerifier.verify(token, publicKey: publicKey, deviceID: device, now: Date(timeIntervalSince1970: 1_800_000_001)))
        var parts = token.split(separator: ".").map(String.init)
        parts[1] = Data(#"{"v":1,"sub":"acc-1","email":"x","dev":"test-device-0000000000000000001","plan":"yearly","status":"active","iat":0,"exp":4000000000,"paidUntil":null}"#.utf8).base64URLString
        XCTAssertNil(LicenseVerifier.verify(parts.joined(separator: "."), publicKey: publicKey, deviceID: device, now: beforeExpiry))
        XCTAssertNil(LicenseVerifier.verify(token, publicKey: "REPLACE_WITH_LICENSE_PUBLIC_KEY", deviceID: device, now: beforeExpiry))
    }

    func testAccessStateRules() {
        XCTAssertTrue(AccessState.trial(daysLeft: 3).canClean)
        XCTAssertTrue(AccessState.subscribed(plan: "monthly", until: nil).canClean)
        XCTAssertFalse(AccessState.expired.canClean)
    }
}
