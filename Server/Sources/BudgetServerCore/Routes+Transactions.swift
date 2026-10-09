import BudgetKit
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

// Tags and the CSV export (server 0.5.0), contract in docs/API.md §Transactions. Both listeners serve them.

func addTransactionToolRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    let api = service.api

    /// `?period=…` narrows to rows in that period; without it, every tag in the ledger.
    router.get("/v1/tags") { request, _ in
        try HTTP.json(try await api.tags(period: request.uri.queryParameters.get("period")))
    }
    /// One tag (a percent-encoded path segment, case ignored) with spending by category; 404 when no row carries it.
    router.get("/v1/tags/:id") { request, context in
        try HTTP.json(try await api.tag(try HTTP.rowID(context), period: request.uri.queryParameters.get("period")))
    }
    /// Every row the filter matches (paging ignored) as RFC 4180 CSV, downloaded as a file.
    /// A static segment next to `/v1/transactions/:id`, like `summary`: no row id is "export.csv".
    router.get("/v1/transactions/export.csv") { request, _ in
        let items = request.uri.queryParameters.map { URLQueryItem(name: String($0.key), value: String($0.value)) }
        let calendar = await service.settings.calendar
        let filter = try TransactionFilter(queryItems: items, calendar: calendar)
        let data = try await api.exportCSV(filter)
        let day = Date().formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
        return Response(status: .ok, headers: [
            .contentType: "text/csv; charset=utf-8; header=present",
            .contentDisposition: "attachment; filename=\"budget-transactions-\(day).csv\"",
            .cacheControl: "no-store",
        ], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}
