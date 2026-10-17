import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession/URLRequest on Linux
#endif

/// HTTP client for the Budget API (Vapor/Hummingbird on the Olares). Contract: docs/API.md.
public struct RemoteBudgetAPI: BudgetAPI, MorningSummaryAPI, PaceAlertsAPI {
    public let baseURL: URL
    private let session: URLSession
    private let token: String?

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public func overview() async throws -> Overview { try await get("v1/overview") }

    public func budget(month: String?) async throws -> BudgetMonth {
        try await get("v1/budget", query: month.map { [URLQueryItem(name: "month", value: $0)] } ?? [])
    }

    public func categoryHistory(id: String, months: Int) async throws -> CategoryHistory {
        try await get("v1/categories", id: id, then: "history", query: [URLQueryItem(name: "months", value: String(months))])
    }

    public func categories() async throws -> [BudgetCategory] { try await get("v1/categories") }
    public func rules() async throws -> [RuleSummary] { try await get("v1/rules") }
    public func rememberedMerchants() async throws -> [RememberedMerchant] { try await get("v1/memory") }
    public func spending(_ range: SpendingRange) async throws -> SpendingSummary {
        try await get("v1/spending", query: [URLQueryItem(name: "range", value: range.rawValue)])
    }

    public func transactions(_ filter: TransactionFilter) async throws -> [LedgerTransaction] {
        try await get("v1/transactions", query: filter.queryItems)
    }

    public func transaction(id: String) async throws -> LedgerTransaction { try await get("v1/transactions", id: id) }

    public func transactionSummary(_ filter: TransactionFilter) async throws -> TransactionSummary {
        try await get("v1/transactions/summary", query: filter.queryItems)
    }

    public func reviewQueue() async throws -> [ReviewItem] { try await get("v1/review") }

    public func confirmCategory(transactionID: String, categoryID: String) async throws -> ActionResult {
        struct Body: Encodable { let categoryID: String }
        let data = try await load(try request("POST", "v1/review", id: transactionID, body: Body(categoryID: categoryID)))
        // Servers from before the undo answer 204 with no body.
        guard !data.isEmpty else { return ActionResult(message: "Filed.", affectedTransactions: 1) }
        return try decode(data)
    }

    /// Ask runs the assistant on the server — several model calls with tools between — so it gets minutes, not seconds.
    /// It declares what this app can take back (`AskCapabilities`); a server before 0.5.0 ignores the field.
    public func ask(_ question: String, conversationID: String?) async throws -> AskReply {
        struct Body: Encodable { let question: String; let conversationID: String?; let capabilities: [String] }
        return try await send("POST", "v1/ask", body: Body(question: question, conversationID: conversationID, capabilities: AskCapabilities.all.names),
                              timeout: Self.askTimeout)
    }

    /// How long a request waits for the server; Ask waits `askTimeout`.
    static let timeout: TimeInterval = 20
    static let askTimeout: TimeInterval = 180

    public func projection(horizonMonths: Int, goal: GoalQuery?) async throws -> Projection {
        struct Body: Encodable { let horizonMonths: Int; let goal: GoalQuery? }
        return try await send("POST", "v1/projection", body: Body(horizonMonths: horizonMonths, goal: goal))
    }

    public func serverStatus() async throws -> ServerStatus { try await get("v1/status") }

    /// The person asked, so the server may spend a live balance call (a server before 0.6.0 ignores the body).
    public func syncNow() async throws -> [LinkSyncResult] {
        try await send("POST", "v1/sync", body: SyncRequest(requestedByPerson: true))
    }

    public func savingsPlan() async throws -> SavingsPlan { try await get("v1/savings") }
    public func checkup() async throws -> Checkup { try await get("v1/checkup") }
    public func subscriptions() async throws -> SubscriptionSummary { try await get("v1/subscriptions") }
    public func recurringReview() async throws -> RecurringReview { try await get("v1/recurring/review") }
    public func monthlyRecap(month: String?) async throws -> MonthlyRecap {
        try await get("v1/recap/month", query: month.map { [URLQueryItem(name: "month", value: $0)] } ?? [])
    }
    public func upcoming(days: Int) async throws -> Upcoming { try await get("v1/upcoming", query: [URLQueryItem(name: "days", value: String(days))]) }

    public func perform(_ action: AppAction) async throws -> ActionResult {
        guard !action.isClientOnly else { throw BudgetAPIError.rejected("\(action.toolName) is handled on the device.") }
        return try await send("POST", "v1/actions", body: action)
    }

    /// With a basis, the server refuses (409) an action whose rows changed since Ask proposed it. A server before
    /// `ServerStatus.actionBasisSince` ignores the header.
    public func perform(_ action: AppAction, basis: String?) async throws -> ActionResult {
        guard let basis else { return try await perform(action) }
        guard !action.isClientOnly else { throw BudgetAPIError.rejected("\(action.toolName) is handled on the device.") }
        return try await send("POST", "v1/actions", body: action, headers: ["Budget-Basis": basis])
    }

    public func updateAccount(id: String, _ change: AccountChange) async throws -> AccountChangeResult {
        try await send("PATCH", "v1/accounts", id: id, body: change)
    }

    public func preview(_ action: AppAction) async throws -> ActionPreview {
        guard !action.isClientOnly else { throw BudgetAPIError.rejected("\(action.toolName) is handled on the device.") }
        return try await send("POST", "v1/actions/preview", body: action)
    }

    public func assistantConfig() async throws -> AssistantConfig { try await get("v1/assistant") }

    public func registerDevice(_ registration: DeviceRegistration) async throws -> DeviceStatus {
        try await send("POST", "v1/devices", body: registration)
    }

    public func sendTestSummary(token: String) async throws -> DeviceStatus {
        // Writing the summary can wait on the chat model.
        try await send("POST", "v1/devices/test", body: ["token": token], timeout: 120)
    }

    /// Pace alerts (server 0.5.0; an older one answers 404, `.notFound`).
    public func paceAlerts() async throws -> PaceAlerts { try await get("v1/alerts/pace") }

    // MARK: - Transport

    /// A row id is one path segment whatever it holds (a statement row's id can contain a slash); `then` follows it.
    func endpoint(_ path: String, id: String?, then tail: String? = nil) -> URL {
        let url = baseURL.appending(path: path)
        let withID = id.map { url.appending(component: $0) } ?? url
        return tail.map { withID.appending(path: $0) } ?? withID
    }

    func get<T: Decodable>(_ path: String, id: String? = nil, then tail: String? = nil, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: endpoint(path, id: id, then: tail), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return try decode(try await load(URLRequest(url: components.url!)))
    }

    func send<T: Decodable>(_ method: String, _ path: String, id: String? = nil, then tail: String? = nil, body: some Encodable,
                            headers: [String: String] = [:], timeout: TimeInterval = timeout) async throws -> T {
        try decode(try await load(try request(method, path, id: id, then: tail, body: body, headers: headers), timeout: timeout))
    }

    func request(_ method: String, _ path: String, id: String? = nil, then tail: String? = nil, body: some Encodable,
                 headers: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: endpoint(path, id: id, then: tail))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try Self.encoder.encode(body)
        return request
    }

    /// The body of a 2xx response (empty for a 204); anything else becomes a `BudgetAPIError`: no connection, a server
    /// that didn't answer in time and one that can't be reached are each said as what they are.
    func load(_ request: URLRequest, timeout: TimeInterval = timeout) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw BudgetAPIError.timedOut
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: throw BudgetAPIError.offline
            default: throw BudgetAPIError.unreachable
            }
        } catch {
            throw BudgetAPIError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw BudgetAPIError.unreachable }
        // The server answers errors as {"error": "..."}.
        let message: String? = {
            if case let .object(o)? = try? JSONValue.parse(data), case let .string(text)? = o["error"] { return text }
            return String(data: data, encoding: .utf8)
        }()
        switch http.statusCode {
        case 200..<300: return data
        case 404: throw BudgetAPIError.notFound
        case 422: throw BudgetAPIError.rejected(message ?? "Rejected.")
        default: throw BudgetAPIError.server(status: http.statusCode, message: message)
        }
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw BudgetAPIError.decoding(String(describing: error))
        }
    }
}
