import Foundation
import UIKit

/// The two calls of the native connect flow (see supabase/functions/connect-native).
struct VersoAPI {
    let baseURL: URL

    struct StartResponse: Decodable {
        let captureNonce: String
        let clientSecret: String
        let provider: String
        let loginUrl: String
        let cookieDomain: String
        let cookieName: String
        let sessionUrl: String
        let expiresInSeconds: Int
    }

    enum CaptureOutcome {
        case connected(connectionId: String)
        case waiting
    }

    private struct ErrorBody: Decodable { let error: String }

    @MainActor
    func start(token: String) async throws -> StartResponse {
        let body: [String: Any] = [
            "action": "start",
            "token": token,
            "device": [
                "platform": "ios",
                "osVersion": UIDevice.current.systemVersion,
                "sdkVersion": VersoConnect.version,
                "model": Self.modelIdentifier,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            ],
        ]
        let (data, status) = try await post(body)
        guard status == 200 else { throw Self.rejection(status, data) }
        return try JSONDecoder().decode(StartResponse.self, from: data)
    }

    @MainActor
    func capture(
        nonce: String,
        secret: String,
        sessionToken: String,
        accessToken: String?,
        providerAccountId: String?,
        providerAccountEmail: String?
    ) async throws -> CaptureOutcome {
        var body: [String: Any] = [
            "action": "capture",
            "captureNonce": nonce,
            "clientSecret": secret,
            "sessionToken": sessionToken,
        ]
        if let accessToken { body["accessToken"] = accessToken }
        if let providerAccountId { body["providerAccountId"] = providerAccountId }
        if let providerAccountEmail { body["providerAccountEmail"] = providerAccountEmail }
        let (data, status) = try await post(body)
        guard status == 200 else { throw Self.rejection(status, data) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if json["status"] as? String == "connected", let id = json["connectionId"] as? String {
            return .connected(connectionId: id)
        }
        return .waiting
    }

    // MARK: - Transport

    private func post(_ body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/connect-native"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("VersoConnect-iOS/\(VersoConnect.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch {
            throw VersoConnectError.network(error)
        }
    }

    private static func rejection(_ status: Int, _ data: Data) -> VersoConnectError {
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Verso answered HTTP \(status)"
        return .rejected(status: status, message: message)
    }

    private static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(String(UnicodeScalar(UInt8(value))))
        }
    }
}
