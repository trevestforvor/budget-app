import Foundation

/// The body of `PATCH /v1/accounts/:id`: what the person changes about an account. Nil leaves a field as it is; an
/// empty nickname or mask clears it.
public struct AccountChange: Hashable, Codable, Sendable {
    public var kind: AccountKind?
    public var nickname: String?
    public var mask: String?

    public init(kind: AccountKind? = nil, nickname: String? = nil, mask: String? = nil) {
        self.kind = kind; self.nickname = nickname; self.mask = mask
    }
}

/// What an account edit did. Undo is a second PATCH with the previous values.
public struct AccountChangeResult: Hashable, Codable, Sendable {
    public var account: Account
    /// Something to check, in a sentence (a card with a positive balance, say).
    public var warning: String?
    /// Rows the change sent back to review.
    public var sentToReview: Int

    public init(account: Account, warning: String? = nil, sentToReview: Int = 0) {
        self.account = account; self.warning = warning; self.sentToReview = sentToReview
    }
}
