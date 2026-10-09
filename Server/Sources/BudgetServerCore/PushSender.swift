import BudgetKit
import Foundation

/// The one way the server pushes to a phone, shared by every kind of notification (the morning summary, pace alerts).
/// It reads the APNs key from the settings and keeps one provider token for all of them: APNs refuses a provider that
/// signs new tokens more often than about every 20 minutes, so two senders each signing their own would collide.
public actor PushSender {
    private let settings: ServerSettings
    private let transport: any HTTPTransport
    private var cachedToken: (credentials: APNsClient.Credentials, token: String, issuedAt: Date)?

    public init(settings: ServerSettings, transport: any HTTPTransport) {
        self.settings = settings
        self.transport = transport
    }

    /// The APNs key, key id, team and topic, when all are set.
    func credentials() async -> APNsClient.Credentials? {
        guard let key = await settings.value("apnsKey"), let keyID = await settings.value("apnsKeyID"),
              let team = await settings.value("apnsTeamID"), let topic = await settings.value("apnsTopic") else { return nil }
        return APNsClient.Credentials(key: key, keyID: keyID, teamID: team, topic: topic)
    }

    static let noKey = "The server has no APNs key yet. Add it on the dashboard, under Notifications."

    /// Sends `alert` to one phone. A token from the other environment (a TestFlight build after a development one) is
    /// refused as bad, so that's tried once on the other host. Returns what APNs said and the environment it went
    /// through, when it went.
    func send(_ alert: APNsClient.Alert, to token: String, environment: DeviceRegistration.Environment,
              now: Date) async -> (outcome: APNsClient.Outcome, environment: DeviceRegistration.Environment?) {
        guard let credentials = await credentials() else { return (.failed(Self.noKey), nil) }
        let client: APNsClient
        let providerToken: String
        do {
            client = try APNsClient(credentials: credentials, transport: transport)
            providerToken = try signedToken(for: client, now: now)
        } catch {
            return (.failed((error as? BudgetAPIError)?.localizedDescription ?? String(describing: error)), nil)
        }
        let outcome = await client.send(alert, to: token, environment: environment, providerToken: providerToken)
        if case .badToken = outcome {
            let other: DeviceRegistration.Environment = environment == .production ? .sandbox : .production
            if await client.send(alert, to: token, environment: other, providerToken: providerToken) == .sent { return (.sent, other) }
        }
        return (outcome, outcome == .sent ? environment : nil)
    }

    /// The provider token, kept for 45 minutes (APNs takes one for an hour and refuses new ones more often than every 20).
    private func signedToken(for client: APNsClient, now: Date) throws -> String {
        if let cached = cachedToken, cached.credentials == client.credentials, now.timeIntervalSince(cached.issuedAt) < 45 * 60 { return cached.token }
        let token = try client.token(issuedAt: now)
        cachedToken = (client.credentials, token, now)
        return token
    }
}
