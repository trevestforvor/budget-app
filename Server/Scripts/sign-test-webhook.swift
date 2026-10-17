// Signs a Plaid-shaped webhook with a local test key and posts it to a TEST server (SPEC §7.4 b). Test only: the server
// accepts these only with BUDGET_TEST_WEBHOOK_JWK_FILE on an in-memory demo server in the Plaid sandbox.
//
//   swift Server/Scripts/sign-test-webhook.swift keygen <dir>
//       writes <dir>/test-webhook.key (the private key, mode 600) and <dir>/test-webhook.jwk (the JWK set, kid "test-1").
//       Start the test server with BUDGET_TEST_WEBHOOK_JWK_FILE=<dir>/test-webhook.jwk.
//   swift Server/Scripts/sign-test-webhook.swift send <dir>/test-webhook.key <body.json> [--url URL] [--iat-offset SECONDS] [--flip-body]
//       signs the body's exact bytes (ES256, kid test-1, iat now + offset, request_body_sha256) and POSTs it; prints only
//       the HTTP status and the server's answer. --flip-body changes one byte after signing (the hash no longer matches).
//
// Neither the private key nor the JWT is ever printed.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

let kid = "test-1"
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: keygen <dir> | send <key> <body.json> [--url URL] [--iat-offset S] [--flip-body]") }
args.removeFirst()

switch command {
case "keygen":
    guard let dir = args.first else { fail("keygen needs a directory") }
    let key = P256.Signing.PrivateKey()
    let keyURL = URL(fileURLWithPath: dir).appendingPathComponent("test-webhook.key")
    let jwkURL = URL(fileURLWithPath: dir).appendingPathComponent("test-webhook.jwk")
    FileManager.default.createFile(atPath: keyURL.path, contents: Data(key.pemRepresentation.utf8), attributes: [.posixPermissions: 0o600])
    let raw = key.publicKey.rawRepresentation  // x || y, 32 bytes each
    let jwk: [String: Any] = ["keys": [["kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": kid,
                                        "x": base64URL(raw.prefix(32)), "y": base64URL(raw.suffix(32))]]]
    let data = try JSONSerialization.data(withJSONObject: jwk, options: [.sortedKeys])
    FileManager.default.createFile(atPath: jwkURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    print("wrote \(keyURL.lastPathComponent) and \(jwkURL.lastPathComponent) (kid \(kid))")

case "send":
    guard args.count >= 2 else { fail("send needs <key> <body.json>") }
    let keyPath = args[0], bodyPath = args[1]
    var url = "http://127.0.0.1:18080/v1/plaid/webhook"
    var iatOffset = 0.0
    var flip = false
    var rest = Array(args.dropFirst(2))
    while let flag = rest.first {
        rest.removeFirst()
        switch flag {
        case "--url": url = rest.isEmpty ? url : rest.removeFirst()
        case "--iat-offset": iatOffset = rest.isEmpty ? 0 : Double(rest.removeFirst()) ?? 0
        case "--flip-body": flip = true
        default: fail("unknown flag \(flag)")
        }
    }
    guard let target = URL(string: url), target.host == "127.0.0.1" || target.host == "localhost" else { fail("only a local test server") }
    guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8), let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
        fail("can't read the private key")
    }
    guard var body = FileManager.default.contents(atPath: bodyPath) else { fail("can't read the body") }
    let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": kid, "typ": "JWT"], options: [.sortedKeys])
    let claims = try JSONSerialization.data(withJSONObject: ["iat": Int(Date().timeIntervalSince1970 + iatOffset), "request_body_sha256": hash],
                                            options: [.sortedKeys])
    let signingInput = base64URL(header) + "." + base64URL(claims)
    let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation  // r || s, as JWS ES256 wants
    let jwt = signingInput + "." + base64URL(signature)
    if flip, !body.isEmpty { body[body.startIndex] ^= 0x01 }

    var request = URLRequest(url: target)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(jwt, forHTTPHeaderField: "Plaid-Verification")
    request.httpBody = body
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { print("no answer: \(error.localizedDescription)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("HTTP \(status) \(data.map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? "")")
        done.signal()
    }.resume()
    done.wait()

default:
    fail("unknown command \(command)")
}
