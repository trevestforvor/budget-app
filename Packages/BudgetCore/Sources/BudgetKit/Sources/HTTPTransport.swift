import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession/URLRequest on Linux
#endif

/// The network layer adapters talk through. Swappable so tests use a fake, and so a Linux
/// server can supply its own client (AsyncHTTPClient).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BudgetAPIError.unreachable }
        return (data, http)
    }
}

public struct SourceHTTPError: LocalizedError, Equatable {
    public var status: Int
    public var body: String
    public var errorDescription: String? { "Provider returned \(status): \(body.prefix(300))" }

    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
}

extension HTTPTransport {
    func json(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SourceHTTPError(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONValue.parse(data)
    }
}
