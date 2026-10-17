import BudgetKit
import Foundation

/// SimpleFIN's own state for one link, kept on its `StoredLink` (`StoredLink.simplefin`). Fields come later, each
/// optional, so a link stored before one existed still decodes.
public struct SimpleFINLinkState: Codable, Hashable, Sendable {
    public init() {}

    /// Each bank behind the link, for the dashboard; nil until per-bank state is kept.
    func banksSummary() -> [LinkBank]? { nil }

    /// The rows Settings → Accounts lists for this link: today the link itself.
    static func institutionRows(_ link: StoredLink, base: InstitutionLink, accounts: [Account]) -> [InstitutionLink] { [base] }
}
