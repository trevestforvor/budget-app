import AsyncHTTPClient
import BudgetKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// `HTTPTransport` over AsyncHTTPClient — the server's network layer for providers.
public struct AHCTransport: HTTPTransport {
    private let client: HTTPClient

    /// A long-lived client; lives for the process.
    public static let shared = AHCTransport(client: HTTPClient(eventLoopGroupProvider: .singleton))

    init(client: HTTPClient) { self.client = client }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw BudgetAPIError.rejected("request has no URL") }
        var r = HTTPClientRequest(url: url.absoluteString)
        r.method = HTTPMethod(rawValue: request.httpMethod ?? "GET")
        for (name, value) in request.allHTTPHeaderFields ?? [:] { r.headers.add(name: name, value: value) }
        if let body = request.httpBody { r.body = .bytes(ByteBuffer(data: body)) }
        let seconds = request.timeoutInterval > 0 ? Int64(request.timeoutInterval) : 60
        let response = try await client.execute(r, timeout: .seconds(seconds))
        let buffer = try await response.body.collect(upTo: 64 * 1024 * 1024)
        var headers: [String: String] = [:]
        for header in response.headers { headers[header.name] = header.value }
        guard let http = HTTPURLResponse(url: url, statusCode: Int(response.status.code), httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw BudgetAPIError.unreachable
        }
        return (Data(buffer: buffer), http)
    }
}
