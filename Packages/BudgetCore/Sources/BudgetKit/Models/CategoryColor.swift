import Foundation

/// The twelve colors a category can wear, by design-system token name.
///
/// Contract: every raw value is the name of a `DSTone` case in DesignSystem (the seven original tones plus
/// coral, rose, teal, lime and violet), and `BudgetCategory.color` stores one of these names, never a hex
/// value. DesignSystem can't see BudgetKit and no test target sees both, so the app's bridge maps a name with
/// `DSTone(rawValue:)` and the dashboard with `var(--<name>)`; a name either side doesn't know falls back to
/// the standard color for the category's id. Adding a case here means adding the tone there first.
public enum CategoryColor: String, CaseIterable, Hashable, Sendable, Codable {
    case iris, lilac, orchid, azure, cyan, irisDeep, amber, coral, rose, teal, lime, violet

    /// What the standard categories wear when they have no color of their own. No two spending
    /// categories share one; income shares cyan, the inflow color.
    public static func standard(forCategoryID id: String) -> CategoryColor? {
        switch id {
        case "groceries": .azure
        case "dining": .orchid
        case "transport": .lilac
        case "housing": .iris
        case "utilities": .lime
        case "subscriptions": .irisDeep
        case "shopping": .cyan
        case "entertainment": .amber
        case "health": .rose
        case "travel": .teal
        case "fees": .coral
        case "income": .cyan
        case "transfer": .violet
        default: nil
        }
    }
}

extension BudgetCategory {
    /// The color to draw this category in: its own, else the standard one for its id, else amber.
    public var effectiveColor: CategoryColor {
        color.flatMap(CategoryColor.init(rawValue:)) ?? CategoryColor.standard(forCategoryID: id) ?? .amber
    }
}
