import Foundation

extension Ledger {
    // MARK: Balances

    /// Every account's balance summed by kind. Cards are negative in the ledger; `cardsOwed` turns that around. Assets and
    /// debts kept by hand count in net worth.
    func balances() -> Balances {
        func total(_ kind: AccountKind) -> Money {
            accounts.filter { $0.kind == kind }.map { balance(of: $0.id, through: now) }.sum()
        }
        let cash = cash(through: now)
        let cardsOwed = -total(.credit)
        let investments = total(.investment)
        let (otherAssets, otherDebts) = manualTotals()
        return Balances(cash: cash, cardsOwed: cardsOwed, investments: investments,
                        netWorth: cash - cardsOwed + investments + otherAssets - otherDebts, cashAfterCards: cash - cardsOwed,
                        otherAssets: manualAssets.contains { !$0.isLiability } ? otherAssets : nil,
                        otherDebts: manualAssets.contains(where: \.isLiability) ? otherDebts : nil)
    }

    // MARK: Data health

    /// What keeps the numbers from being current, worst first: each connection the bank ended (sign in again), then
    /// each checking, savings or card account whose newest transaction is older than its own rhythm allows — for an
    /// account that only comes from statements, once the next statement is overdue — or an empty ledger. Home's
    /// attention list and the checkup's data section both come from here.
    /// - Parameter institutions: the deployment's links; only their status is read.
    func dataHealth(institutions: [InstitutionLink]) -> [DataAttention] {
        var result = linkAttention(institutions)
        guard !transactions.isEmpty else {
            result.append(DataAttention(id: "no-data", kind: .emptyLedger, title: "The ledger is empty.",
                                        detail: "Link an account or import a statement on the Budget dashboard."))
            return result
        }
        return result + staleAttention(institutions)
    }

    static func institutionKey(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    /// "Harbor Total Checking", or just "Keystone Mastercard" when the name already says where it is.
    static func fullName(_ account: Account) -> String {
        account.name.localizedCaseInsensitiveContains(account.institution) ? account.name : "\(account.institution) \(account.name)"
    }

    // MARK: - [lane S] institutionLinks

    /// The institutions as the phone lists them: each published link with the ledger accounts it holds and how far their
    /// rows reach, then one entry per institution whose accounts all come from imported statements (nothing to sign in
    /// to). A link holds the accounts at its institution that its provider brought in; a SimpleFIN link, one bridge
    /// for many banks, holds every SimpleFIN account.
    func institutionLinks(_ published: [InstitutionLink]) -> [InstitutionLink] {
        var newest: [String: Date] = [:]
        for row in transactions where row.postedAt > newest[row.accountID] ?? .distantPast { newest[row.accountID] = row.postedAt }
        func summarize(_ link: inout InstitutionLink, _ held: [Account]) {
            link.accountIDs = held.map(\.id)
            link.coversThrough = held.compactMap { newest[$0.id] }.max()
            if link.accountKinds.isEmpty { link.accountKinds = AccountKind.allCases.filter { kind in held.contains { $0.kind == kind } } }
        }
        var claimed: Set<String> = []
        var result = published.map { original in
            var link = original
            let held = accounts.filter { account in
                guard let provider = link.primary, provider != .fileImport, account.source == provider else { return false }
                return provider == .simplefin || Self.institutionKey(account.institution) == Self.institutionKey(link.institution)
            }
            claimed.formUnion(held.map(\.id))
            summarize(&link, held)
            return link
        }
        let statementOnly = Dictionary(grouping: accounts.filter { !claimed.contains($0.id) && $0.source == .fileImport }) { Self.institutionKey($0.institution) }
        for key in statementOnly.keys.sorted() {
            let held = statementOnly[key]!
            var link = InstitutionLink(id: "statements-\(key.filter { $0.isLetter || $0.isNumber })", institution: held[0].institution,
                                       primary: .fileImport, fallback: nil, accountKinds: [], status: .connected,
                                       note: "From statements you import on the Budget dashboard.")
            summarize(&link, held)
            result.append(link)
        }
        // Apps before server 0.2.0 can't read a link without a priority, so every link carries one (nothing reads it now)
        // until those apps are gone.
        for index in result.indices where result[index].priority == nil { result[index].priority = .core }
        return result
    }
}
