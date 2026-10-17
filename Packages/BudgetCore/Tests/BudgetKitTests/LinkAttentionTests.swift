@testable import BudgetKit
import Foundation
import Testing

@Suite("Link attention: sign in again, renew access")
struct LinkAttentionTests {
    static let ledger = MonthFixture.ledger(accounts: [], rows: [])

    static func link(_ id: String, _ institution: String, status: ConnectionStatus = .connected, expiresInDays: Double? = nil,
                     reconnect: ReconnectMethod? = nil, errorKind: LinkErrorKind? = nil) -> InstitutionLink {
        InstitutionLink(id: id, institution: institution, primary: .plaid, fallback: nil, accountKinds: [], status: status, note: "",
                        errorKind: errorKind, consentExpiresAt: expiresInDays.map { MonthFixture.day(-$0) }, reconnect: reconnect)
    }

    @Test("Consent ending within 14 days is one item with its link, its date and the consentExpiring reason")
    func expiring() throws {
        let items = Self.ledger.linkAttention([Self.link("plaid-amex", "Amex", expiresInDays: 13, reconnect: .phone)])
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.id == "expiring-plaid-amex")
        #expect(item.kind == .needsReauth, "a kind every app knows")
        #expect(item.reason == .consentExpiring)
        #expect(item.linkID == "plaid-amex")
        #expect(item.dueBy == MonthFixture.day(-13))
        #expect(item.title.hasPrefix("Amex access ends "))
        #expect(item.detail.contains("Linked accounts"), "the phone can renew it")
    }

    @Test("Twenty days out, no date, or a link already waiting for a sign-in: no renew item")
    func notYet() {
        let links = [Self.link("a", "A", expiresInDays: 20), Self.link("b", "B"),
                     Self.link("c", "C", status: .needsReauth, expiresInDays: 3)]
        let items = Self.ledger.linkAttention(links)
        #expect(items.map(\.id) == ["reauth-c"], "the sign-in speaks for C")
    }

    @Test("A consent that already ran out on a link still working says so")
    func ended() throws {
        let item = try #require(Self.ledger.linkAttention([Self.link("x", "Chase", expiresInDays: -1)]).first)
        #expect(item.title == "Chase access has ended.")
        #expect(item.detail.contains("dashboard"), "no phone reconnect on this link")
    }

    @Test("Sign-in items carry their link and reason, and point to the phone, the dashboard or a new link")
    func reauthReasons() {
        let items = Self.ledger.linkAttention([
            Self.link("p", "Harbor", status: .needsReauth, reconnect: .phone, errorKind: .needsSignIn),
            Self.link("d", "Summit", status: .needsReauth),
            Self.link("n", "Keystone", status: .needsReauth, reconnect: .newLink, errorKind: .revoked),
        ])
        #expect(items.map(\.id) == ["reauth-p", "reauth-d", "reauth-n"], "ids unchanged from older servers")
        #expect(items.map(\.reason) == [.needsSignIn, .needsSignIn, .revoked])
        #expect(items.map(\.linkID) == ["p", "d", "n"])
        #expect(items[0].detail.contains("Sign in again from Linked accounts"))
        #expect(items[1].detail.contains("Reconnect it on the Budget dashboard"))
        #expect(items[2].detail.contains("Link it again"))
    }

    @Test("Sign-ins come before renewals, and Home and the checkup show both")
    func order() {
        let links = [Self.link("e", "Amex", expiresInDays: 7, reconnect: .phone), Self.link("r", "Harbor", status: .needsReauth)]
        let health = Self.ledger.dataHealth(institutions: links)
        #expect(health.map(\.id) == ["reauth-r", "expiring-e", "no-data"])
        let data = Self.ledger.checkup(institutions: links).sections.first { $0.id == "data" }
        #expect(data?.findings.contains { $0.id == "expiring-e" } == true)
    }

    @Test("The new fields survive the wire and an old client's decoder ignores them")
    func wire() throws {
        let item = try #require(Self.ledger.linkAttention([Self.link("e", "Amex", expiresInDays: 9, reconnect: .phone)]).first)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(item)
        let back = try decoder.decode(DataAttention.self, from: data)
        #expect(back.reason == .consentExpiring && back.linkID == "e" && back.dueBy != nil)
        struct OldAttention: Decodable { var id: String; var kind: String; var title: String; var detail: String }
        #expect(try decoder.decode(OldAttention.self, from: data).kind == "needsReauth")
    }
}
