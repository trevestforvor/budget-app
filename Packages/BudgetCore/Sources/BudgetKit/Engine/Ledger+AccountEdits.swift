import Foundation

extension Ledger {
    /// The longest nickname kept, in characters.
    static let nicknameLimit = 60

    /// Changes an account's kind, nickname or last digits (`PATCH /v1/accounts/:id`). Each field left nil stays as it is;
    /// an empty nickname or mask clears it. The bank's `name` keeps updating underneath a nickname, and a mask the person
    /// set isn't replaced by a provider's (`prepareIngest`). A kind change re-pairs old matched transfers (they depend on
    /// cash versus card) and, when the account became a card, sends its money in filed as Income back to review, as the
    /// one-time card upgrade did (`sendCardIncomeToReview`). Nothing flips a balance's sign: a card with a positive balance
    /// is only warned about. Re-pairing only adds pairs: a pair this change made card-to-card stays paired, and neither the
    /// pairs nor the rows sent to review are undone when the kind is changed back.
    ///
    /// A nickname is one line: whitespace inside it (a pasted newline or tab) becomes one space, other control characters
    /// are refused, and so is a run of six or more digits, so an account number can't be stored and exported through it.
    mutating func updateAccount(id: String, _ change: AccountChange) throws -> AccountChangeResult {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
        var account = accounts[index]

        if let raw = change.nickname {
            let nickname = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard nickname.count <= Self.nicknameLimit else {
                throw BudgetAPIError.rejected("A nickname can be at most \(Self.nicknameLimit) characters.")
            }
            guard !nickname.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw BudgetAPIError.rejected("A nickname can't hold control characters.")
            }
            guard nickname.firstMatch(of: /[0-9]{6,}/) == nil else {
                throw BudgetAPIError.rejected("Leave the account number out of a nickname; its last digits go under Last digits.")
            }
            account.nickname = nickname.isEmpty ? nil : nickname
        }
        if let raw = change.mask {
            let mask = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if mask.isEmpty {
                // Cleared: the next sync's digits, if the provider sends any, are used again.
                account.mask = nil
                account.maskSetByPerson = nil
            } else {
                // Amex shows five digits; two is the least a bank prints.
                guard (2...5).contains(mask.count), mask.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                    throw BudgetAPIError.rejected("Last digits are 2 to 5 numbers, like 0909.")
                }
                account.mask = mask
                account.maskSetByPerson = true
            }
        }

        var warning: String?
        var sentToReview = 0
        let kindChanged = change.kind.map { $0 != account.kind } ?? false
        if let kind = change.kind {
            // Saving the same kind still confirms it: a provider's guess the person checked is no longer a guess.
            account.kind = kind
            account.kindSetByPerson = true
            if kind == .credit && account.balance.minorUnits > 0 {
                warning = "Cards normally show what's owed as a negative balance; this one is positive. Check it after the next sync."
            }
        }
        accounts[index] = account
        if kindChanged {
            pairLegacyTransfers()
            if account.kind == .credit { sentToReview = sendCardIncomeToReview(onlyOn: id) }
        }
        return AccountChangeResult(account: account, warning: warning, sentToReview: sentToReview)
    }
}
