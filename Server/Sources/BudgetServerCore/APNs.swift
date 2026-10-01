import BudgetKit
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Apple Push Notification service over HTTP/2 with token auth: a .p8 key signs a short JWT (ES256) that APNs accepts
/// for up to an hour. The transport is AsyncHTTPClient (`AHCTransport`), which speaks HTTP/2 to APNs.
public struct APNsClient: Sendable {
    public struct Credentials: Sendable, Equatable {
        /// The .p8 file's text. Newlines may be missing (pasted into a one-line field); the base64 inside is what counts.
        public var key: String
        public var keyID: String
        public var teamID: String
        /// The app's bundle id.
        public var topic: String

        public init(key: String, keyID: String, teamID: String, topic: String) {
            self.key = key
            self.keyID = keyID
            self.teamID = teamID
            self.topic = topic
        }
    }

    public struct Alert: Sendable, Equatable {
        public var title: String
        public var body: String
        /// Replaces an earlier notification with the same id instead of stacking a second one.
        public var collapseID: String
        /// Groups the summaries together in Notification Center.
        public var threadID: String
        /// Extra keys beside `aps` for the app to read when it's tapped.
        public var userInfo: [String: String]
        /// Past this APNs stops trying a phone that's off.
        public var expiration: Date
    }

    public enum Outcome: Sendable, Equatable {
        case sent
        /// The token is dead (the app was deleted, or it belongs to the other environment): stop sending to it.
        case badToken(String)
        case failed(String)
    }

    let credentials: Credentials
    let transport: any HTTPTransport
    private let signingKey: P256.Signing.PrivateKey

    public init(credentials: Credentials, transport: any HTTPTransport) throws {
        self.credentials = credentials
        self.transport = transport
        signingKey = try Self.privateKey(credentials.key)
    }

    /// The key from a .p8's text: PEM with or without its line breaks, or the bare base64 inside it.
    static func privateKey(_ text: String) throws -> P256.Signing.PrivateKey {
        let base64 = text.replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: base64) else { throw BudgetAPIError.rejected("The APNs key isn't the text of a .p8 file.") }
        do { return try P256.Signing.PrivateKey(derRepresentation: der) } catch {
            throw BudgetAPIError.rejected("The APNs key isn't a P-256 key from a .p8 file.")
        }
    }

    /// A provider token: `header.claims.signature`, base64url, signed with ES256.
    public func token(issuedAt: Date) throws -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = base64URL(Data(#"{"alg":"ES256","kid":"\#(credentials.keyID)"}"#.utf8))
        let claims = base64URL(Data(#"{"iss":"\#(credentials.teamID)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#.utf8))
        let signature = try signingKey.signature(for: Data("\(header).\(claims)".utf8))
        return "\(header).\(claims).\(base64URL(signature.rawRepresentation))"
    }

    static func host(_ environment: DeviceRegistration.Environment) -> String {
        environment == .production ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com"
    }

    /// - Parameter providerToken: from `token(issuedAt:)`, reused for up to an hour: APNs refuses a provider that
    ///   signs a new one more often than every 20 minutes.
    public func send(_ alert: Alert, to deviceToken: String, environment: DeviceRegistration.Environment, providerToken: String) async -> Outcome {
        do {
            var request = URLRequest(url: URL(string: "\(Self.host(environment))/3/device/\(deviceToken)")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("bearer \(providerToken)", forHTTPHeaderField: "authorization")
            request.setValue(credentials.topic, forHTTPHeaderField: "apns-topic")
            request.setValue("alert", forHTTPHeaderField: "apns-push-type")
            request.setValue("10", forHTTPHeaderField: "apns-priority")
            request.setValue(String(Int(alert.expiration.timeIntervalSince1970)), forHTTPHeaderField: "apns-expiration")
            request.setValue(alert.collapseID, forHTTPHeaderField: "apns-collapse-id")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try Self.payload(alert)
            let (data, response) = try await transport.send(request)
            if response.statusCode == 200 { return .sent }
            let reason = (try? JSONDecoder().decode([String: String].self, from: data))?["reason"] ?? "HTTP \(response.statusCode)"
            // 410: the token is no longer active; BadDeviceToken: not a token for this environment (or at all).
            if response.statusCode == 410 || reason == "BadDeviceToken" || reason == "Unregistered" || reason == "DeviceTokenNotForTopic" {
                return .badToken(reason)
            }
            return .failed("APNs refused it: \(reason)")
        } catch {
            return .failed("Couldn't reach APNs: \(error)")
        }
    }

    static func payload(_ alert: Alert) throws -> Data {
        var object: [String: Any] = [
            "aps": ["alert": ["title": alert.title, "body": alert.body], "thread-id": alert.threadID, "relevance-score": 0.6] as [String: Any],
        ]
        for (key, value) in alert.userInfo { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
