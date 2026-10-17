import BudgetKit
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// The phone's Universal Link files, on the API surface only, with no token (they aren't under `/v1`):
/// - `GET /.well-known/apple-app-site-association`: says the app (`BUDGET_IOS_APP_ID`, `<TEAMID>.<bundle id>`) opens
///   `/plaid/oauth-return`. Static JSON, never a redirect; it must stay up, or OAuth sessions in flight fail.
/// - `GET /plaid/oauth-return`: where an OAuth bank sends the phone back (`PLAID_MOBILE_REDIRECT_URI`'s default). With
///   the app installed iOS opens the app instead; otherwise this page says to go back to it. Its query (Plaid's
///   `oauth_state_id`) is never read or logged.
func addAppLinkRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    router.get("/.well-known/apple-app-site-association") { _, _ in
        guard let appID = service.config.iosAppID?.trimmingCharacters(in: .whitespacesAndNewlines), !appID.isEmpty else {
            return HTTP.error(.notFound, "BUDGET_IOS_APP_ID isn't set, so there are no app links.")
        }
        return try HTTP.json(AppSiteAssociation(appID: appID))
    }
    router.get("/plaid/oauth-return") { _, _ in
        var headers: HTTPFields = [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"]
        headers[HTTPField.Name("Referrer-Policy")!] = "no-referrer"
        headers[.contentSecurityPolicy] = "default-src 'none'; style-src 'unsafe-inline'"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: oauthReturnPage)))
    }
}

/// apple-app-site-association: only the OAuth return path opens the app.
struct AppSiteAssociation: Encodable {
    struct AppLinks: Encodable { var details: [Detail] }
    struct Detail: Encodable { var appIDs: [String]; var components: [[String: String]] }
    var applinks: AppLinks

    init(appID: String) {
        applinks = AppLinks(details: [Detail(appIDs: [appID], components: [["/": "/plaid/oauth-return*"]])])
    }
}

private let oauthReturnPage = """
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Return to Budget</title>
<style>body{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:48px 24px;text-align:center;color:#1c1c1e;background:#fff}
@media (prefers-color-scheme: dark){body{color:#f2f2f7;background:#000}}h1{font-size:22px}</style></head>
<body><h1>Return to the Budget app</h1><p>Your bank is done. Go back to Budget to finish signing in.</p></body></html>
"""
