import SwiftUI

/// Picks a category colour from the tones. Six to a row around the colour wheel; the chosen
/// one gets a white ring and a check in its own ink, so the selection never rests on hue alone.
public struct DSSwatchGrid: View {
    @Binding private var selection: DSTone
    private let tones: [DSTone]
    private let inUse: Set<DSTone>

    /// - Parameter inUse: tones other categories already wear; they get a small dot so collisions are a choice.
    public init(selection: Binding<DSTone>, tones: [DSTone] = DSTone.swatches, inUse: Set<DSTone> = []) {
        _selection = selection
        self.tones = tones
        self.inUse = inUse
    }

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: DSSpace.xs), count: 6)

    public var body: some View {
        LazyVGrid(columns: Self.columns, spacing: DSSpace.xs) {
            ForEach(tones, id: \.self) { tone in
                swatch(tone)
            }
        }
    }

    private func swatch(_ tone: DSTone) -> some View {
        let isSelected = tone == selection
        let shape = RoundedRectangle(cornerRadius: DSRadius.control + 2, style: .continuous)
        return Button {
            selection = tone
        } label: {
            VStack(spacing: 3) {
                shape
                    .fill(tone.fill)
                    .frame(width: 36, height: 36)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(tone.onFill)
                        }
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: DSRadius.control + 5, style: .continuous)
                            .strokeBorder(isSelected ? Color.ds.ink : Color.clear, lineWidth: 2)
                    }
                Circle()
                    .fill(inUse.contains(tone) ? Color.ds.inkTertiary : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tone.displayName)
        .accessibilityValue(inUse.contains(tone) ? "In use" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// An SF Symbol offered for a category, with the words people search for it by.
public struct DSSymbol: Identifiable, Hashable, Sendable {
    public let systemName: String
    /// What VoiceOver says, and the first thing search matches.
    public let label: String
    public let keywords: [String]
    public var id: String { systemName }

    public init(_ systemName: String, label: String, keywords: [String] = []) {
        self.systemName = systemName
        self.label = label
        self.keywords = keywords
    }

    /// Case- and accent-insensitive match on the label, keywords or symbol name. Empty matches everything.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return ([label, systemName] + keywords).contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    public static func search(_ query: String, in symbols: [DSSymbol] = budgetCategories) -> [DSSymbol] {
        symbols.filter { $0.matches(query) }
    }

    /// 48 symbols that cover a household budget, grouped so the grid reads by theme.
    /// Includes every default category's symbol, so an existing category always shows as selected.
    public static let budgetCategories: [DSSymbol] = [
        // Food and drink
        .init("cart", label: "Groceries", keywords: ["food", "supermarket", "market"]),
        .init("fork.knife", label: "Dining", keywords: ["restaurant", "eating out", "food"]),
        .init("cup.and.saucer", label: "Coffee", keywords: ["cafe", "tea"]),
        .init("takeoutbag.and.cup.and.straw", label: "Takeout", keywords: ["delivery", "fast food"]),
        .init("wineglass", label: "Drinks", keywords: ["bar", "alcohol", "wine"]),
        // Home
        .init("house", label: "Housing", keywords: ["rent", "mortgage", "home"]),
        .init("bolt", label: "Utilities", keywords: ["electric", "power", "energy"]),
        .init("drop", label: "Water", keywords: ["utilities"]),
        .init("flame", label: "Gas and heating", keywords: ["utilities", "heat"]),
        .init("wifi", label: "Internet", keywords: ["broadband", "utilities"]),
        .init("phone", label: "Phone", keywords: ["mobile", "cell"]),
        .init("hammer", label: "Home repair", keywords: ["maintenance", "tools", "home"]),
        .init("sofa", label: "Furniture", keywords: ["home goods", "decor"]),
        // Getting around
        .init("car", label: "Transport", keywords: ["car", "auto"]),
        .init("fuelpump", label: "Fuel", keywords: ["gas station", "petrol"]),
        .init("wrench.and.screwdriver", label: "Car maintenance", keywords: ["repair", "service"]),
        .init("bus", label: "Transit", keywords: ["train", "subway", "public transport"]),
        .init("bicycle", label: "Bike", keywords: ["cycling", "scooter"]),
        .init("airplane", label: "Travel", keywords: ["flights", "trips", "vacation", "hotel"]),
        // Shopping and personal
        .init("bag", label: "Shopping", keywords: ["retail", "store"]),
        .init("tshirt", label: "Clothing", keywords: ["clothes", "apparel", "shoes"]),
        .init("gift", label: "Gifts", keywords: ["presents", "holidays"]),
        .init("scissors", label: "Personal care", keywords: ["hair", "salon", "beauty"]),
        .init("laptopcomputer", label: "Electronics", keywords: ["tech", "computer", "gadgets"]),
        // Health
        .init("heart", label: "Health", keywords: ["medical", "doctor", "wellness"]),
        .init("pills", label: "Pharmacy", keywords: ["medicine", "prescriptions"]),
        .init("dumbbell", label: "Fitness", keywords: ["gym", "sports"]),
        // Family and learning
        .init("pawprint", label: "Pets", keywords: ["pet", "vet", "dog", "cat"]),
        .init("figure.and.child.holdinghands", label: "Kids", keywords: ["childcare", "family", "children"]),
        .init("graduationcap", label: "Education", keywords: ["school", "tuition", "books"]),
        // Fun and subscriptions
        .init("ticket", label: "Entertainment", keywords: ["events", "concerts", "fun"]),
        .init("film", label: "Movies", keywords: ["cinema", "streaming"]),
        .init("music.note", label: "Music", keywords: ["concerts", "streaming"]),
        .init("gamecontroller", label: "Games", keywords: ["gaming", "video games"]),
        .init("tv", label: "TV and streaming", keywords: ["television", "streaming"]),
        .init("repeat", label: "Subscriptions", keywords: ["recurring", "memberships"]),
        // Money
        .init("percent", label: "Fees and interest", keywords: ["bank fees", "interest", "charges"]),
        .init("banknote", label: "Cash", keywords: ["atm", "money"]),
        .init("creditcard", label: "Card payments", keywords: ["credit card", "payment"]),
        .init("building.columns", label: "Bank", keywords: ["banking", "accounts"]),
        .init("chart.line.uptrend.xyaxis", label: "Investing", keywords: ["investments", "brokerage", "savings"]),
        .init("arrow.down.circle", label: "Income", keywords: ["paycheck", "salary", "deposit"]),
        .init("arrow.left.arrow.right", label: "Transfer", keywords: ["move money", "between accounts"]),
        .init("umbrella", label: "Insurance", keywords: ["cover", "policy"]),
        .init("doc.text", label: "Taxes and bills", keywords: ["tax", "bills", "paperwork"]),
        // Everything else
        .init("hands.sparkles", label: "Giving", keywords: ["charity", "donations"]),
        .init("briefcase", label: "Work", keywords: ["business", "office", "expenses"]),
        .init("tag", label: "Other", keywords: ["misc", "general"]),
    ]
}

/// Picks a category icon. The chosen symbol fills with the category's tone, so the grid
/// previews the glyph the category will wear.
public struct DSSymbolGrid: View {
    @Binding private var selection: String
    private let symbols: [DSSymbol]
    private let tone: DSTone
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    public init(selection: Binding<String>, symbols: [DSSymbol] = DSSymbol.budgetCategories, tone: DSTone) {
        _selection = selection
        self.symbols = symbols
        self.tone = tone
    }

    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: max(side, 44), maximum: max(side, 44) + 20), spacing: DSSpace.xs)],
                  spacing: DSSpace.xs) {
            ForEach(symbols) { symbol in
                cell(symbol)
            }
        }
    }

    private func cell(_ symbol: DSSymbol) -> some View {
        let isSelected = symbol.systemName == selection
        return Button {
            selection = symbol.systemName
        } label: {
            RoundedRectangle(cornerRadius: DSRadius.control + 2, style: .continuous)
                .fill(isSelected ? tone.fill : Color.ds.surfaceRaised)
                .frame(width: max(side, 44), height: max(side, 44))
                .overlay {
                    Image(systemName: symbol.systemName)
                        .font(.system(size: max(side, 44) * 0.4, weight: .medium))
                        .foregroundStyle(isSelected ? tone.onFill : Color.ds.inkSecondary)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
