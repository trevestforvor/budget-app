import BudgetKit
import Foundation
import Hummingbird
import Logging

/// Test-only aids for the Plaid Sandbox end-to-end plan (SPEC §7.3, §7.4 b). Each exists only on an in-memory server
/// that allows the demo (`BUDGET_ALLOW_DEMO=1`, no `POSTGRES_HOST`), so none can ever be on a server holding a real
/// ledger:
/// - `BUDGET_TEST_WEBHOOK_JWK_FILE`: webhooks verified against a local JWK set (also Plaid sandbox only), signed with
///   `Server/Scripts/sign-test-webhook.swift`;
/// - `POST /dash/debug/plaid/check/:linkID`: the daily Item check, run now.
enum TestHooks {
    static func enabled(_ config: ServerConfig) -> Bool { config.isThrowaway }

    /// The JWK set's P-256 keys by `kid`, when the file is set and allowed here; nil (with a warning when it was set but
    /// isn't allowed or can't be read) otherwise.
    static func webhookKeys(_ config: ServerConfig, logger: Logger) -> [String: PlaidSource.WebhookKey]? {
        guard let path = config.testWebhookJWKFile?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        guard enabled(config), config.plaid?.environment == .sandbox else {
            logger.warning("BUDGET_TEST_WEBHOOK_JWK_FILE is ignored: only an in-memory demo server in the Plaid sandbox uses it")
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path),
              let set = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = set["keys"] as? [[String: Any]] else {
            logger.warning("BUDGET_TEST_WEBHOOK_JWK_FILE is ignored: it isn't a readable JWK set")
            return nil
        }
        var keys: [String: PlaidSource.WebhookKey] = [:]
        for jwk in list where jwk["kty"] as? String == "EC" && jwk["crv"] as? String == "P-256" {
            guard let kid = jwk["kid"] as? String, let x = jwk["x"] as? String, let y = jwk["y"] as? String else { continue }
            keys[kid] = PlaidSource.WebhookKey(keyID: kid, x: x, y: y)
        }
        guard !keys.isEmpty else {
            logger.warning("BUDGET_TEST_WEBHOOK_JWK_FILE is ignored: it holds no P-256 keys")
            return nil
        }
        logger.warning("test server: Plaid webhooks are verified against \(keys.count) local test key\(keys.count == 1 ? "" : "s"), not Plaid's")
        return keys
    }

    /// The debug route, on the dashboard surface of a test server only.
    static func addRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
        guard enabled(service.config) else { return }
        router.post("/dash/debug/plaid/check/:linkID") { _, context in
            let linkID = try context.parameters.require("linkID")
            let outcome = await service.plaidMaintenance.checkItem(linkID, syncIfHealed: true)
            return try HTTP.json(["outcome": "\(outcome)"])
        }
    }
}
