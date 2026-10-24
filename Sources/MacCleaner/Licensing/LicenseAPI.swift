import Foundation

/// Client for the subscription server (server/src/routes). Every call is a small JSON request.
struct LicenseAPI {
    var base = LicenseConfig.apiBase
    var session: URLSession = .shared

    struct Device: Decodable, Identifiable, Equatable {
        let deviceId: String
        let deviceName: String
        let lastSeenAt: String
        var id: String { deviceId }
    }

    enum ActivateResult {
        case license(token: String)
        case noSubscription
        case deviceLimit([Device])
    }

    enum Failure: Error, Equatable {
        case invalidCode, unauthorized, rateLimited, offline, server(Int)
    }

    func requestCode(email: String, locale: String) async throws {
        _ = try await send("api/auth/request-code", body: ["email": email, "locale": locale])
    }

    /// Returns the app session token.
    func verifyCode(email: String, code: String) async throws -> String {
        let (data, status) = try await send("api/auth/verify-code", allow: [400],
                                            body: ["email": email, "code": code, "client": "app"])
        if status == 400 { throw Failure.invalidCode }
        struct Response: Decodable { let token: String }
        return try JSONDecoder().decode(Response.self, from: data).token
    }

    func activate(sessionToken: String) async throws -> ActivateResult {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let (data, status) = try await send("api/license/activate", token: sessionToken, allow: [402, 409],
                                            body: ["deviceId": DeviceIdentity.id, "deviceName": DeviceIdentity.name, "appVersion": version])
        switch status {
        case 402: return .noSubscription
        case 409:
            struct Limit: Decodable { let devices: [Device] }
            return .deviceLimit(try JSONDecoder().decode(Limit.self, from: data).devices)
        default:
            struct Response: Decodable { let token: String }
            return .license(token: try JSONDecoder().decode(Response.self, from: data).token)
        }
    }

    func deactivate(sessionToken: String, deviceID: String = DeviceIdentity.id) async throws {
        _ = try await send("api/license/devices/\(deviceID)", method: "DELETE", token: sessionToken, allow: [404])
    }

    func logout(sessionToken: String) async throws {
        _ = try await send("api/auth/logout", token: sessionToken)
    }

    private func send(_ path: String, method: String = "POST", token: String? = nil, allow: Set<Int> = [],
                      body: [String: String]? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 20)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) || allow.contains(status) { return (data, status) }
        switch status {
        case 401: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        default: throw Failure.server(status)
        }
    }
}
