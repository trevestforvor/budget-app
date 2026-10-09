import SwiftUI

/// How loudly a line speaks. Muted is for rows that don't count toward spending — transfers,
/// hidden rows — and uses quieter ink rather than lowered opacity: `inkSecondary` stays about
/// 8.6:1 on a card, while a half-opacity row would fail AA.
public enum DSEmphasis: Sendable, Equatable {
    case normal
    case muted
}

/// Rounded-square glyph with a tone wash — identifies a category at a glance.
public struct DSGlyph: View {
    private let systemImage: String
    private let tone: DSTone
    private let size: CGFloat
    private let emphasis: DSEmphasis

    public init(systemImage: String, tone: DSTone, size: CGFloat = 36, emphasis: DSEmphasis = .normal) {
        self.systemImage = systemImage
        self.tone = tone
        self.size = size
        self.emphasis = emphasis
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: DSRadius.glyph, style: .continuous)
            .fill(emphasis == .muted ? tone.fill.opacity(0.08) : tone.wash)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(emphasis == .muted ? Color.ds.inkTertiary : tone.onCanvas)
            }
            .accessibilityHidden(true)
    }
}

/// One ledger line.
///
/// Trailing, in order: an eye-slash tag when hidden, the amount, an orchid dot when it needs
/// review. Hidden rows are always muted; pass `.muted` yourself for rows that don't count
/// (transfers). VoiceOver reads the title, subtitle and amount, then the statuses.
public struct DSTransactionRow: View {
    private let title: String
    private let subtitle: String
    private let amount: Decimal
    private let currencyCode: String
    private let systemImage: String
    private let tone: DSTone
    private let confidence: DSConfidence?
    private let isPending: Bool
    private let emphasis: DSEmphasis
    private let isHidden: Bool
    private let needsReview: Bool
    private let tags: [String]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - subtitle: the caller's line, e.g. "Groceries · Sapphire ••2864" or "Groceries · Today".
    ///   - confidence: deprecated — review is now the `needsReview` dot, and the per-row badge is
    ///     going away. Still rendered (except `.auto`) until call sites move off it.
    ///   - emphasis: `.muted` for rows that don't count toward spending.
    ///   - isHidden: the person hid it; mutes the row and adds the eye-slash tag.
    ///   - needsReview: the server wants an answer; adds the 6pt orchid dot.
    ///   - tags: the person's own labels, as tags under the subtitle (the first two, then "+N").
    public init(title: String, subtitle: String, amount: Decimal, currencyCode: String = "USD", systemImage: String, tone: DSTone,
                confidence: DSConfidence? = nil, isPending: Bool = false,
                emphasis: DSEmphasis = .normal, isHidden: Bool = false, needsReview: Bool = false, tags: [String] = []) {
        self.title = title
        self.subtitle = subtitle
        self.amount = amount
        self.currencyCode = currencyCode
        self.systemImage = systemImage
        self.tone = tone
        self.confidence = confidence
        self.isPending = isPending
        self.emphasis = emphasis
        self.isHidden = isHidden
        self.needsReview = needsReview
        self.tags = tags
    }

    /// Hidden implies muted.
    private var effectiveEmphasis: DSEmphasis { isHidden ? .muted : emphasis }
    private var isMuted: Bool { effectiveEmphasis == .muted }

    /// What VoiceOver appends after the amount, in reading order.
    nonisolated static func accessibilityStatuses(emphasis: DSEmphasis, isHidden: Bool, needsReview: Bool, isPending: Bool) -> [String] {
        var statuses: [String] = []
        if isHidden { statuses.append("hidden") }
        else if emphasis == .muted { statuses.append("not counted") }
        if needsReview { statuses.append("needs review") }
        if isPending { statuses.append("pending") }
        return statuses
    }

    private var accessibilityValue: String {
        var parts = [DSAmountFormat.string(amount, currencyCode: currencyCode, sign: .inflowPlus)]
        parts += Self.accessibilityStatuses(emphasis: emphasis, isHidden: isHidden, needsReview: needsReview, isPending: isPending)
        if let confidence, confidence != .auto, !(needsReview && confidence == .review) {
            parts.append("categorization: \(confidence.label)")
        }
        return parts.joined(separator: ", ")
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize { stacked } else { inline }
        }
        .padding(.vertical, DSSpace.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)" + (tags.isEmpty ? "" : ", tagged \(tags.joined(separator: ", "))"))
        .accessibilityValue(accessibilityValue)
    }

    private var inline: some View {
        HStack(spacing: DSSpace.sm) {
            DSGlyph(systemImage: systemImage, tone: tone, emphasis: effectiveEmphasis)
            VStack(alignment: .leading, spacing: 3) {
                titleText.lineLimit(1)
                // The subtitle gets the whole width (its account digits tell two cards apart); Pending sits under the amount.
                subtitleText.lineLimit(1)
                if !tags.isEmpty { tagLine }
            }
            Spacer(minLength: DSSpace.xs)
            if isHidden { hiddenTag }
            // Every row keeps the dot's slot, so amounts and Pending line up down a list whether or not a row asks.
            HStack(spacing: Self.reviewSlotGap) {
                VStack(alignment: .trailing, spacing: 4) {
                    amountText
                    if isPending { pendingTag }
                    if let confidence, confidence != .auto {
                        DSConfidenceBadge(confidence)
                    }
                }
                reviewDot
                    .opacity(needsReview ? 1 : 0)
                    .frame(width: Self.reviewSlot)
            }
        }
    }

    /// The review dot's slot at the row's trailing edge, and its gap from the amount.
    static let reviewSlot: CGFloat = 6
    static let reviewSlotGap: CGFloat = 6

    /// Accessibility sizes: the title and subtitle get the full width and wrap; the amount and
    /// the status marks move to their own line beneath them.
    private var stacked: some View {
        HStack(alignment: .top, spacing: DSSpace.sm) {
            DSGlyph(systemImage: systemImage, tone: tone, emphasis: effectiveEmphasis)
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                titleText.lineLimit(3)
                subtitleText.lineLimit(3)
                if !tags.isEmpty { tagLine }
                HStack(spacing: DSSpace.xs) {
                    amountText
                    if isPending { pendingTag }
                    if isHidden { hiddenTag }
                    if let confidence, confidence != .auto { DSConfidenceBadge(confidence) }
                    if needsReview { reviewDot }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var titleText: some View {
        Text(title)
            .dsFont(.body)
            .foregroundStyle(isMuted ? Color.ds.inkSecondary : Color.ds.ink)
    }

    private var subtitleText: some View {
        Text(subtitle)
            .dsFont(.caption)
            .foregroundStyle(isMuted ? Color.ds.inkTertiary : Color.ds.inkSecondary)
    }

    private var amountText: some View {
        DSAmountText(amount, currencyCode: currencyCode, sign: .inflowPlus, tintsInflow: true, emphasis: effectiveEmphasis)
    }

    /// The person's tags, marked with the tag glyph so they never read as a status: two, then how many more, on one line.
    /// Neutral ink (a label, not data), a tier quieter on a muted row.
    private var tagLine: some View {
        HStack(spacing: DSSpace.xxs) {
            ForEach(tags.prefix(2), id: \.self) { DSTag($0, systemImage: "tag", tint: isMuted ? Color.ds.inkTertiary : Color.ds.inkSecondary).lineLimit(1) }
            if tags.count > 2 { DSTag("+\(tags.count - 2)", tint: Color.ds.inkTertiary).fixedSize() }
        }
        .padding(.top, 2)
    }

    /// Fixed so the tag never wraps letter by letter.
    private var pendingTag: some View { DSTag("Pending").fixedSize() }

    private var hiddenTag: some View { DSTag(systemImage: "eye.slash", tint: Color.ds.inkTertiary) }

    /// The one deliberate glow on a dot: it asks for an answer.
    private var reviewDot: some View {
        Circle()
            .fill(DSConfidence.review.tint)
            .frame(width: 6, height: 6)
            .shadow(color: DSConfidence.review.tint.opacity(0.5), radius: 3)
    }
}

/// A chromatic category panel — the only place saturated color fills a surface. Glossed toward
/// the top (`DSTileFill`). Wrap it in a button with `.buttonStyle(.dsPress(radius: DSRadius.tile))`
/// and `wash: Color.ds.surfacePressed.opacity(0.2)` so it darkens under a finger instead of fading.
public struct DSCategoryTile: View {
    private let title: String
    private let systemImage: String
    private let amount: Decimal
    private let currencyCode: String
    private let footnote: String?
    private let tone: DSTone

    public init(title: String, systemImage: String, amount: Decimal, currencyCode: String = "USD", footnote: String? = nil, tone: DSTone) {
        self.title = title
        self.systemImage = systemImage
        self.amount = amount
        self.currencyCode = currencyCode
        self.footnote = footnote
        self.tone = tone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: DSIconSize.lg, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Circle().fill(tone.onFill.opacity(0.1)))
                .accessibilityHidden(true)
            Spacer(minLength: DSSpace.md)
            // Full ink, never faded: at 80% the title fell under AA on violet.
            Text(title)
                .dsFont(.eyebrow)
            Text(DSAmountFormat.string(amount, currencyCode: currencyCode, sign: .magnitude, fractionDigits: 0))
                .dsFont(.amount)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let footnote {
                // Full-strength ink: faded to 75% it fell to 4.2:1 on violet.
                Text(footnote).dsFont(.caption).lineLimit(1)
            }
        }
        .foregroundStyle(tone.onFill)
        .padding(DSSpace.md + 2)
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .topLeading)
        .background { DSTileFill(tone: tone) }
        .accessibilityElement(children: .combine)
    }
}

/// "Found for you": category eyebrow, serif headline, one line of why, on a card that blooms in the tone.
/// The provenance footer names the ledger tool that produced the number.
public struct DSInsightCard: View {
    private let eyebrow: String
    private let title: String
    private let message: String
    private let tone: DSTone
    private let provenance: String?

    public init(eyebrow: String, title: String, message: String, tone: DSTone, provenance: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.message = message
        self.tone = tone
        self.provenance = provenance
    }

    public var body: some View {
        DSCard(padding: DSSpace.lg - 4, tone: tone) {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSEyebrow(eyebrow, dot: tone.onCanvas)
                Text(title)
                    .dsFont(.headline)
                    .foregroundStyle(Color.ds.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .dsFont(.callout)
                    .foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let provenance {
                    DSToolTrace(name: provenance)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Shows which deterministic tool computed a number: `sumByCategory(2026-Q3)`.
public struct DSToolTrace: View {
    private let name: String
    private let arguments: String?

    public init(name: String, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "function").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            Text(arguments.map { "\(name)(\($0))" } ?? name)
                .dsFont(.mono)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.ds.inkTertiary)
        .accessibilityLabel("Computed by the ledger tool \(name)")
    }
}

/// A category's money in a breakdown: its wash glyph, its name and a line under it, and the amount in ink — with an
/// optional line under the amount (a change, an arrow delta). The one row for "by category" lists (a recap's biggest
/// changes, a tag's categories), so they never mix a settings row's filled tile and grey value with transaction rows.
/// At accessibility sizes the amount moves under the name.
public struct DSCategoryAmountRow<Below: View>: View {
    private let title: String
    private let detail: String?
    private let systemImage: String
    private let tone: DSTone
    private let amount: Decimal
    private let currencyCode: String
    private let below: Below
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ title: String, detail: String? = nil, systemImage: String, tone: DSTone, amount: Decimal, currencyCode: String = "USD",
                @ViewBuilder below: () -> Below) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tone = tone
        self.amount = amount
        self.currencyCode = currencyCode
        self.below = below()
    }

    public var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: DSSpace.sm) {
            DSGlyph(systemImage: systemImage, tone: tone)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    label
                    figure(alignment: .leading)
                }
                Spacer(minLength: 0)
            } else {
                label
                Spacer(minLength: DSSpace.xs)
                figure(alignment: .trailing)
            }
        }
        .padding(.vertical, DSSpace.xs)
        .frame(minHeight: DSSize.listRow)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).dsFont(.body).foregroundStyle(Color.ds.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func figure(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            DSAmountText(amount, currencyCode: currencyCode, sign: .magnitude)
            below
        }
    }
}

extension DSCategoryAmountRow where Below == EmptyView {
    public init(_ title: String, detail: String? = nil, systemImage: String, tone: DSTone, amount: Decimal, currencyCode: String = "USD") {
        self.init(title, detail: detail, systemImage: systemImage, tone: tone, amount: amount, currencyCode: currencyCode) { EmptyView() }
    }
}
