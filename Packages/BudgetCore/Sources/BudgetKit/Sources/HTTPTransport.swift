import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession/URLRequest on Linux
#endif
#if canImport(Security)
import Security
#endif

/// The network layer adapters talk through. Swappable so tests use a fake, and so a Linux
/// server can supply its own client (e.g. AsyncHTTPClient with a client certificate).
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

#if canImport(Security)
/// Presents a client certificate (Teller requires mTLS) on Apple platforms.
public final class ClientCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let credential: URLCredential

    public init(identity: SecIdentity) {
        credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }

    /// Loads a PKCS#12 bundle (Teller's certificate + private key, exported as .p12).
    public convenience init(pkcs12 data: Data, password: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw SourceHTTPError(status: Int(status), body: "Couldn't read the client certificate bundle.")
        }
        self.init(identity: identity as! SecIdentity) // swiftlint:disable:this force_cast — CF type bridge
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            return (.useCredential, credential)
        }
        return (.performDefaultHandling, nil)
    }
}

extension URLSessionTransport {
    /// A transport that answers client-certificate challenges — for Teller.
    public static func mutualTLS(_ delegate: ClientCertificateDelegate) -> URLSessionTransport {
        URLSessionTransport(session: URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil))
    }
}
#endif
