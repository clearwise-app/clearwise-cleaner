import Foundation
import IOKit
import CryptoKit

/// A stable, anonymous id of this Mac for the device limit: SHA-256 of the hardware UUID, so the server
/// never sees the UUID itself. Survives reinstalls and macOS updates.
enum DeviceIdentity {
    static let id: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        // No UUID (never seen on real hardware): fall back to a random id kept in the Keychain.
        let seed = uuid ?? Keychain.string(for: "device-seed") ?? {
            let s = UUID().uuidString
            Keychain.set(s, for: "device-seed")
            return s
        }()
        let digest = SHA256.hash(data: Data("clearwise-device:\(seed)".utf8))
        return String(Data(digest).base64URLString.prefix(32))
    }()

    /// Shown on the account page next to the device ("MacBook Pro Дмитрия").
    static var name: String { Host.current().localizedName ?? "Mac" }
}
