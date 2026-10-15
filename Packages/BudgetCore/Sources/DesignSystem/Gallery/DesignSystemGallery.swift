import SwiftUI

/// A living catalog of every token and component. Reachable from Settings → Design system.
///
/// For screenshots, `-DSGallerySection <title>` (a launch argument, read through UserDefaults)
/// opens scrolled to that section; `"Grouped list"` opens the list page and `"Toast"` presents one.
public struct DesignSystemGallery: View {
    @State private var chipSelection = 0
    @State private var askText = ""
    @State private var tone: DSTone = .teal
    @State private var symbol = "airplane"
    @State private var reviewNewMerchants = true
    @State private var holdPending = false
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selectedBar = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var toast: DSToastMessage?
    @State private var showsGroupedList = Self.requestedSection == "Grouped list"
    @State private var fieldName = "Pottery"
    @State private var fieldEmpty = ""
    @State private var fieldAmount = "42"
    @State private var fieldToken = "sk-live-3f9a"
    @State private var fieldSearch = ""
    @State private var price = ""
    @State private var period = Period.month
    @State private var direction = "out"

    public init() {}

    static var requestedSection: String? { UserDefaults.standard.string(forKey: "DSGallerySection") }

    enum Period: String, CaseIterable { case week = "Week", month = "Month", year = "Year" }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .padding(.horizontal, DSSpace.gutter)
                    .padding(.vertical, DSSpace.lg)
            }
            .onAppear {
                if let section = Self.requestedSection { proxy.scrollTo(section, anchor: .top) }
                if Self.requestedSection == "Toast" { presentSampleToast() }
            }
        }
        .dsScreenBackground()
        .dsToast($toast)
        .navigationDestination(isPresented: $showsGroupedList) { GroupedListDemo() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DSSpace.xl) {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                DSEyebrow("Design system")
                Text("A quiet room\nfor your money.")
                    .dsFont(.display)
                    .foregroundStyle(Color.ds.ink)
            }

            section("Surfaces") {
                HStack(spacing: DSSpace.xs) {
                    swatch("canvasDeep", Color.ds.canvasDeep)
                    swatch("canvas", Color.ds.canvas)
                    swatch("surface", Color.ds.surface)
                    swatch("raised", Color.ds.surfaceRaised)
                    swatch("overlay", Color.ds.surfaceOverlay)
                    swatch("pressed", Color.ds.surfacePressed)
                }
            }

            section("Ink") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ink — headlines and numbers").foregroundStyle(Color.ds.ink)
                    Text("inkSoft — softer display white").foregroundStyle(Color.ds.inkSoft)
                    Text("inkSecondary — body and descriptions").foregroundStyle(Color.ds.inkSecondary)
                    Text("inkTertiary — captions, provenance").foregroundStyle(Color.ds.inkTertiary)
                    Text("inkDisabled — disabled labels only").foregroundStyle(Color.ds.inkDisabled)
                }
                .dsFont(.body)
            }

            section("Tones") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: DSSpace.xs)], spacing: DSSpace.xs) {
                    ForEach(DSTone.swatches, id: \.self) { tone in
                        RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                            .fill(tone.fill)
                            .frame(height: 56)
                            .overlay(alignment: .bottomLeading) {
                                Text(tone.rawValue).dsFont(.eyebrow).foregroundStyle(tone.onFill).padding(8)
                            }
                    }
                }
            }

            section("Type") {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    Text("Display").dsFont(.display)
                    Text("Title — serif regular").dsFont(.title)
                    Text("Headline — serif regular").dsFont(.headline)
                    Text("Body — the workhorse UI voice.").dsFont(.body)
                    Text("Callout and captions for supporting copy.").dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                    Text("Callout emphasis — compact buttons").dsFont(.calloutEmphasis)
                    Text("Label — field and segment labels").dsFont(.label).foregroundStyle(Color.ds.inkSecondary)
                    Text("Eyebrow · mono label").dsFont(.eyebrow).foregroundStyle(Color.ds.inkSecondary)
                    Text("sumByCategory(2026-Q3)").dsFont(.mono).foregroundStyle(Color.ds.inkTertiary)
                    Text("https://budget.example.com").dsFont(.code).foregroundStyle(Color.ds.inkSoft)
                    Text("JAN  FEB  MAR  $1.2K").dsFont(.axis).foregroundStyle(Color.ds.inkTertiary)
                }
                .foregroundStyle(Color.ds.ink)
            }

            section("Numbers") {
                DSHeroAmount(label: "Cash on hand", value: 24_812.46, caption: "+$1,204 in the last 30 days", captionTint: Color.ds.inflow)
                DSCard {
                    HStack {
                        DSStatBlock(label: "Spent", value: 3_120, footnote: "of $4,200")
                        DSStatBlock(label: "Income", value: 7_700, tint: Color.ds.inflow)
                    }
                }
            }

            section("Chart") {
                DSLineChart(actual: Self.samplePoints, style: .full, accessibilitySummary: "Sample trend")
                    .frame(height: 160)
            }

            section("Buttons") {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    Button("Confirm category") {}.buttonStyle(.ds(.primary, size: .large, fullWidth: true))
                    // Every variant at rest, disabled and loading. Press any of them to see its pressed fill.
                    Grid(alignment: .leading, horizontalSpacing: DSSpace.xs, verticalSpacing: DSSpace.xs) {
                        ForEach(Self.buttonVariants, id: \.name) { item in
                            GridRow {
                                Text(item.name).dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                                Button(item.title) {}.buttonStyle(.ds(item.variant, size: .compact))
                                Button(item.title) {}.buttonStyle(.ds(item.variant, size: .compact)).disabled(true)
                                Button(item.title) {}.buttonStyle(.ds(item.variant, size: .compact, isLoading: true))
                            }
                        }
                    }
                    HStack(spacing: DSSpace.xs) {
                        Button("Large") {}.buttonStyle(.ds(.secondary, size: .large))
                        Button("Regular") {}.buttonStyle(.ds(.secondary))
                        Button("Compact") {}.buttonStyle(.ds(.secondary, size: .compact))
                    }
                    HStack(spacing: DSSpace.xs) {
                        DSIconButton(systemImage: "slider.horizontal.3", label: "Filters") {}
                        DSIconButton(systemImage: "plus", label: "Add") {}.disabled(true)
                        DSAskButton(label: "this card") {}
                        DSAskButton(label: "this card", isWorking: true) {}
                        Button("See all") {}.buttonStyle(.ds(.quiet))
                    }
                }
            }

            section("Fields") {
                VStack(alignment: .leading, spacing: DSSpace.md) {
                    DSField("Name", text: $fieldName, prompt: "Pets, Gifts, Kids…", helper: "Shown on every row filed under it.")
                    DSField("Monthly target", text: $fieldAmount, prompt: "0", prefix: "$", suffix: "/mo")
                    DSField("API token", text: $fieldToken, isCode: true)
                    DSField(nil, text: $fieldSearch, prompt: "Search: coffee, pets, gym…", style: .search)
                    DSCard(padding: DSSpace.md) {
                        VStack(alignment: .leading, spacing: 0) {
                            DSField("Bank description contains", text: $fieldEmpty, prompt: "PAYROLL, UBER…", style: .inline, isCode: true)
                            DSDivider()
                            DSField("Merchant name contains", text: $fieldName, style: .inline)
                        }
                    }
                    DSAmountField(isEmpty: price.isEmpty) {
                        TextField("Price", text: $price, prompt: Text("0"))
                    }
                }
            }

            section("Segmented") {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    DSSegmented("Period", selection: $period, options: Period.allCases) { $0.rawValue }
                    DSSegmented("Money", selection: $direction, options: [(value: "either", title: "Either way"), (value: "out", title: "Going out"),
                                                                       (value: "in", title: "Coming in")])
                    DSSegmented("Period", selection: .constant(Period.week), options: Period.allCases) { $0.rawValue }.disabled(true)
                }
            }

            section("Effects") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DSSpace.sm), GridItem(.flexible())], spacing: DSSpace.sm) {
                    effect("G1 lit edge · G2 flat") { Color.clear.dsPanel() }
                    effect("G2 raised") { Color.clear.dsPanel(.raised) }
                    effect("G3 tone bloom") { Color.clear.dsPanel(wash: .tone(.teal)) }
                    effect("G4 caution wash") { Color.clear.dsPanel(wash: .caution) }
                    effect("G7 AI edge · G8 aura") {
                        DSPanelBackground(wash: .ai).dsAIEdge(radius: DSRadius.card)
                    }
                    effect("G7 working") {
                        DSPanelBackground(wash: .ai).dsAIEdge(radius: DSRadius.card, isWorking: true)
                    }
                    effect("G5 data bloom") { Color.clear.dsScreenBackground(bloom: .data).clipShape(RoundedRectangle(cornerRadius: DSRadius.card)) }
                    effect("G5 AI bloom") { Color.clear.dsScreenBackground(bloom: .ai).clipShape(RoundedRectangle(cornerRadius: DSRadius.card)) }
                    effect("G6 pearl") { RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).fill(DSFill.pearl) }
                    effect("G9 tile gloss") { DSTileFill(tone: .violet) }
                    effect("Overlay + shadow") { Color.clear.dsPanel(.overlay).dsShadow(.overlay) }
                    effect("G12 edge fade") {
                        LinearGradient(colors: [Color.ds.canvas.opacity(0), Color.ds.canvas], startPoint: .top, endPoint: .bottom)
                            .background(DSTileFill(tone: .azure))
                            .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
                    }
                }
            }

            section("States") {
                statesMatrix
            }

            section("Chips, tags, badges") {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    HStack(spacing: DSSpace.xs) {
                        ForEach(Array(["This month", "Last month", "90 days"].enumerated()), id: \.offset) { index, title in
                            DSChip(title, isSelected: chipSelection == index) { chipSelection = index }
                        }
                    }
                    HStack(spacing: DSSpace.xs) {
                        Menu {
                            Button("Newest") {}
                            Button("Oldest") {}
                            Button("Largest") {}
                        } label: {
                            DSChipLabel("Newest", trailingSystemImage: "chevron.down")
                        }
                        DSChip("Filters · 2", isSelected: true) {}
                        DSChip("Target", systemImage: "plus") {}
                    }
                    DSFlowLayout(spacing: DSSpace.xs, lineSpacing: DSSpace.xs) {
                        DSConfidenceBadge(.auto)
                        DSConfidenceBadge(.likely, percent: 82)
                        DSConfidenceBadge(.decided, percent: 91)
                        DSConfidenceBadge(.review, percent: 54)
                    }
                    HStack(spacing: DSSpace.xs) {
                        DSChip("Dining", systemImage: "fork.knife", tone: .orchid) {}
                        DSChip("Travel", systemImage: "airplane", tone: .teal) {}
                    }
                    DSFlowLayout(spacing: DSSpace.xs, lineSpacing: DSSpace.xs) {
                        DSPrivacyBadge(.local)
                        DSPrivacyBadge(.aggregatesOnly)
                        DSPrivacyBadge(.cached)
                    }
                    DSFlowLayout(spacing: DSSpace.xs, lineSpacing: DSSpace.xs) {
                        DSTag("Pending")
                        DSTag(systemImage: "eye.slash", tint: Color.ds.inkTertiary)
                        DSTag.over()
                        DSTag.over("Over $38")
                        DSTag("System")
                    }
                }
            }

            section("Progress") {
                DSCard(padding: DSSpace.md) {
                    VStack(alignment: .leading, spacing: DSSpace.md) {
                        DSProgressBar(fraction: 0.64)
                        DSProgressBar(fraction: 1.12)
                        DSProgressBar(fraction: 1.12, tint: DSTone.azure.onCanvas)
                        // Dining is orchid, the same as caution: the notch and the tag carry "over".
                        budgetRow("Dining", symbol: "fork.knife", tone: .orchid, spent: 512, target: 450)
                        budgetRow("Groceries", symbol: "cart", tone: .azure, spent: 388, target: 650)
                    }
                }
            }

            section("Rows") {
                DSCard(padding: DSSpace.md) {
                    VStack(spacing: 0) {
                        DSTransactionRow(title: "Trader Joe's", subtitle: "Groceries · Sapphire ••2864", amount: -84.12, systemImage: "cart", tone: .azure)
                        DSDivider()
                        DSTransactionRow(title: "SQ *CASA TACO", subtitle: "Dining · Yesterday", amount: -23.50, systemImage: "fork.knife", tone: .orchid,
                                         needsReview: true)
                        DSDivider()
                        DSTransactionRow(title: "Harbor Checking", subtitle: "Transfer · Sep 16", amount: -1_200, systemImage: "arrow.left.arrow.right", tone: .violet,
                                         emphasis: .muted)
                        DSDivider()
                        DSTransactionRow(title: "Venmo", subtitle: "Shopping · Sep 15", amount: -40, systemImage: "bag", tone: .cyan, isHidden: true)
                        DSDivider()
                        DSTransactionRow(title: "Blue Bottle", subtitle: "Dining · Today", amount: -6.75, systemImage: "cup.and.saucer", tone: .orchid, isPending: true)
                        DSDivider()
                        DSTransactionRow(title: "ACME Payroll", subtitle: "Income · Sep 15", amount: 3_850, systemImage: "arrow.down.circle", tone: .cyan)
                    }
                }
            }

            section("Lists") {
                DSCard(padding: DSSpace.md) {
                    VStack(spacing: 0) {
                        DSListRow("Categories", detail: "13 · 2 without a target", value: "13", systemImage: "square.grid.2x2", tone: .orchid, showsChevron: true)
                        DSDivider()
                        DSListRow("Rules", systemImage: "arrow.triangle.branch", tone: .azure) {
                            HStack(spacing: DSSpace.xs) {
                                DSTag("1 conflict", tint: Color.ds.caution)
                                DSListValue("8", showsChevron: true)
                            }
                        }
                        DSDivider()
                        DSListRow("Account", value: "Harbor Checking ••0909", showsChevron: true)
                        DSDivider()
                        DSListRow("Descriptor") {
                            Text("SQ *CASA TACO 0412").dsFont(.mono).foregroundStyle(Color.ds.inkSecondary)
                        }
                        DSDivider()
                        DSToggleRow("New merchants", detail: "Ask before filing a merchant for the first time", isOn: $reviewNewMerchants)
                        DSDivider()
                        DSToggleRow("Face ID lock", systemImage: "faceid", tone: .teal, isOn: $holdPending)
                    }
                }
                NavigationLink {
                    GroupedListDemo()
                } label: {
                    Text("Open the grouped list skin")
                }
                .buttonStyle(.ds(.secondary))
            }

            section("Pickers") {
                DSCard(padding: DSSpace.md) {
                    VStack(alignment: .leading, spacing: DSSpace.md) {
                        HStack(spacing: DSSpace.md) {
                            DSGlyph(systemImage: symbol, tone: tone, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Travel").dsFont(.headline).foregroundStyle(Color.ds.ink)
                                Text(tone.displayName).dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                            }
                        }
                        DSEyebrow("Color")
                        DSSwatchGrid(selection: $tone, inUse: [.orchid, .azure, .lilac, .iris])
                        DSEyebrow("Icon")
                        DSSymbolGrid(selection: $symbol, tone: tone)
                    }
                }
            }

            section("Icon tiles") {
                DSFlowLayout(spacing: DSSpace.sm, lineSpacing: DSSpace.sm) {
                    ForEach(DSTone.swatches, id: \.self) { tone in
                        DSIconTile(systemImage: "square.grid.2x2", tone: tone)
                    }
                }
                HStack(spacing: DSSpace.sm) {
                    DSIconTile(systemImage: "checklist", tone: .amber, size: 40)
                    DSIconTile(systemImage: "building.columns", tone: .iris, size: 40)
                    DSIconTile(systemImage: "gearshape.2", tone: .irisDeep, size: 40)
                }
            }

            section("Notices") {
                DSNoticeCard("2 connections need you to sign in again",
                             message: "Your bank expired the connection. Reconnect on your server's dashboard — it keeps your history and accounts.",
                             actionTitle: "Open dashboard") {}
                DSNoticeCard("Showing the offline copy", message: "From 2 hours ago. Changes wait until your server is back.",
                             systemImage: "icloud.slash", tint: Color.ds.amber)
                DSAttentionPill("2 accounts need attention") {}
            }

            section("Toast") {
                DSToast("Filed 12 as Transfer", actionTitle: "Undo", countdown: .seconds(600)) {}
                DSToast("Rule saved")
                Button("Show a toast") { presentSampleToast() }
                .buttonStyle(.ds(.secondary))
            }

            section("Month") {
                DSCard(padding: DSSpace.xs) {
                    DSMonthSwitcher(month: $month, earliest: Calendar.current.date(byAdding: .month, value: -11, to: .now))
                }
            }

            section("Week") {
                DSCard(padding: DSSpace.md) {
                    VStack(alignment: .leading, spacing: DSSpace.sm) {
                        HStack {
                            DSEyebrow("Everyday · last 7 days")
                            Spacer()
                            DSAskButton(label: "the last 7 days") {}
                        }
                        Text("$588").dsFont(.amount).foregroundStyle(Color.ds.ink)
                        DSWeekStrip(days: Self.sampleWeek)
                    }
                }
            }

            section("Gauge") {
                HStack(spacing: DSSpace.sm) {
                    DSCard(padding: DSSpace.md) {
                        DSArcGauge(fraction: 0.56, accessibilityLabel: "Everyday spending") {
                            VStack(spacing: 2) {
                                DSEyebrow("Safe to spend")
                                Text("$1,284").dsFont(.amount).foregroundStyle(Color.ds.ink).lineLimit(1).minimumScaleFactor(0.5)
                                Text("of $2,900").dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                            }
                        }
                    }
                    DSCard(padding: DSSpace.md) {
                        DSArcGauge(fraction: 1.08, accessibilityLabel: "Everyday spending") {
                            VStack(spacing: 2) {
                                DSEyebrow("Over by")
                                Text("$232").dsFont(.amount).foregroundStyle(Color.ds.caution).lineLimit(1).minimumScaleFactor(0.5)
                                Text("of $2,900").dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                            }
                        }
                    }
                }
            }

            section("Month bars") {
                DSCard(padding: DSSpace.md) {
                    DSMonthBars(bars: Self.sampleBars, target: 450, tone: .orchid, selection: selectedBar,
                                accessibilitySummary: "Dining, 12 months against a $450 target") { selectedBar = $0 }
                        .frame(height: 140)
                }
            }

            section("Cash flow") {
                DSCard(padding: DSSpace.md) {
                    DSCashFlowChart(points: Self.sampleFlow, accessibilitySummary: "Six months of money in and out")
                        .frame(height: 200)
                }
            }

            section("Tiles") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DSSpace.sm), GridItem(.flexible())], spacing: DSSpace.sm) {
                    DSCategoryTile(title: "Dining", systemImage: "fork.knife", amount: 412, footnote: "of $450", tone: .orchid)
                    DSCategoryTile(title: "Groceries", systemImage: "cart", amount: 588, footnote: "of $650", tone: .azure)
                    DSCategoryTile(title: "Health", systemImage: "heart", amount: 140, footnote: "of $200", tone: .rose)
                    DSCategoryTile(title: "Travel", systemImage: "airplane", amount: 960, footnote: "3 transactions", tone: .teal)
                }
            }

            section("Insight") {
                DSInsightCard(eyebrow: "Subscriptions", title: "You pay $215 a month on autopilot.", message: "Four recurring charges, one of them up 20% since spring.", tone: .iris, provenance: "queryTransactions")
                    .frame(height: 200)
            }

            section("Proposal") {
                DSActionCard(title: "Set the Dining target to $500 a month", detail: "You're already past that this month.",
                             effects: [.init(id: "a", label: "Current target", value: "$450.00"),
                                       .init(id: "b", label: "New monthly target", value: "$500.00", emphasized: true)],
                             trace: ("setCategoryTarget", #"categoryID: "dining", monthlyAmount: "500.00""#),
                             phase: .proposed, onApply: {}, onDismiss: {})
            }

            section("Conversation") {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    DSUserBubble("What did we spend on dining in Q3 vs Q2?")
                    DSThinkingLine("Running sumByCategory…")
                    DSAskField(text: $askText) {}
                }
            }

            section("Empty and error") {
                DSCard {
                    DSStateView(systemImage: "wifi.slash", title: "Can't reach your server", message: "Showing the copy saved on this phone.", actionTitle: "Retry") {}
                }
            }
        }
    }

    static let buttonVariants: [(name: String, title: String, variant: DSButtonStyle.Variant)] = [
        ("primary", "Save", .primary), ("secondary", "Edit", .secondary), ("tinted", "Sync", .tinted), ("ai", "Ask", .ai),
        ("quiet", "See all", .quiet), ("destructive", "Delete", .destructive), ("armed", "Delete", .destructiveArmed), ("glass", "Done", .glass),
    ]

    /// Rest, focus, error, disabled and read-only side by side, for the controls that have them.
    private var statesMatrix: some View {
        VStack(alignment: .leading, spacing: DSSpace.md) {
            DSEyebrow("Field")
            DSField("Rest", text: .constant(""), prompt: "Placeholder")
            DSField("Focused", isFocused: true) { TextField("Focused", text: .constant("Typing…")) }
            DSField("Error", error: "Enter an amount above zero.") { TextField("Error", text: .constant("-12")) }
            DSField("Disabled") { TextField("Disabled", text: .constant("Can't change this")) }.disabled(true)
            DSField("Read-only", isReadOnly: true) { Text("Harbor Checking ••0909") }
            DSCard(padding: DSSpace.md) {
                VStack(alignment: .leading, spacing: 0) {
                    DSField("Inline, focused", style: .inline, isFocused: true) { TextField("Inline", text: .constant("DoorDash")) }
                    DSDivider()
                    DSField("Inline, error", style: .inline, error: "That merchant already has a cap.") { TextField("Inline", text: .constant("Uber")) }
                }
            }
            DSEyebrow("Chip")
            DSFlowLayout(spacing: DSSpace.xs, lineSpacing: DSSpace.xs) {
                DSChip("Rest") {}
                DSChip("Selected", isSelected: true) {}
                DSChip("Dining", tone: .orchid) {}
                DSChip("Disabled") {}.disabled(true)
            }
            DSEyebrow("Amount")
            DSAmountField(isEmpty: false, isFocused: true) { TextField("Focused", text: .constant("1,280")) }
            DSAmountField(isEmpty: false, error: "That's more than the account holds.") { TextField("Error", text: .constant("98,000")) }
        }
    }

    private func effect<Swatch: View>(_ name: String, @ViewBuilder swatch: () -> Swatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            swatch().frame(height: 88)
            Text(name).dsFont(.caption).foregroundStyle(Color.ds.inkTertiary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func presentSampleToast() {
        toast = .undo("Filed 12 as Transfer") { toast = DSToastMessage("Put back") }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSEyebrow(title)
            content()
        }
        .id(title)
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                .fill(color)
                .frame(height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(Color.ds.hairlineStrong)
                }
            Text(name).dsFont(.axis).foregroundStyle(Color.ds.inkTertiary).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    /// How a budget row composes the over state: caution amount, the "Over" tag, and the notched bar.
    private func budgetRow(_ name: String, symbol: String, tone: DSTone, spent: Decimal, target: Decimal) -> some View {
        let fraction = NSDecimalNumber(decimal: spent / target).doubleValue
        let isOver = DSProgressBar.isOver(fraction)
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.sm) {
                DSGlyph(systemImage: symbol, tone: tone)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).dsFont(.body).foregroundStyle(Color.ds.ink)
                        if isOver { DSTag.over() }
                    }
                    Text(isOver ? "over by \(DSAmountFormat.string(spent - target, currencyCode: "USD", fractionDigits: 0))"
                                : "of \(DSAmountFormat.string(target, currencyCode: "USD", fractionDigits: 0))")
                        .dsFont(.caption)
                        .foregroundStyle(isOver ? Color.ds.caution : Color.ds.inkSecondary)
                }
                Spacer()
                DSAmountText(spent, sign: .magnitude)
            }
            DSProgressBar(fraction: fraction, tint: tone.onCanvas)
                .padding(.leading, 36 + DSSpace.sm)
        }
        .accessibilityElement(children: .combine)
    }

    static let samplePoints: [DSChartPoint] = (0..<12).map { i in
        DSChartPoint(date: Calendar.current.date(byAdding: .month, value: i - 11, to: .now)!, value: 18_000 + Double(i) * 520 + (i.isMultiple(of: 3) ? -700 : 250))
    }

    static let sampleWeek: [DSDaySpend] = zip(0..<7, [48, 0, 126, 22, 310, 64, 18] as [Decimal]).map { offset, amount in
        DSDaySpend(date: Calendar.current.date(byAdding: .day, value: offset - 6, to: .now)!, amount: amount)
    }

    static let sampleBars: [DSMonthBar] = zip(0..<12, [380, 420, 505, 310, 440, 398, 470, 360, 415, 520, 402, 388] as [Double]).map { offset, value in
        DSMonthBar(month: Calendar.current.date(byAdding: .month, value: offset - 11, to: .now)!, value: value)
    }

    static let sampleFlow: [DSCashFlowPoint] = zip(0..<7, [(7_700, 6_240), (7_700, 7_980), (7_900, 5_860), (7_700, 6_710), (8_400, 6_020), (7_700, 7_150), (3_850, 2_940)] as [(Double, Double)])
        .map { offset, flow in
            DSCashFlowPoint(month: Calendar.current.date(byAdding: .month, value: offset - 6, to: .now)!,
                            income: flow.0, spending: flow.1, net: flow.0 - flow.1, isPartial: offset == 6)
        }
}

/// `.dsGroupedList()` with `DSListSection`s — the skin Settings uses.
private struct GroupedListDemo: View {
    @State private var faceID = false
    @State private var bigAmounts = true

    var body: some View {
        List {
            DSListSection("Budget") {
                NavigationLink { Text("Categories") } label: {
                    DSListRow("Categories", value: "13", systemImage: "square.grid.2x2", tone: .orchid)
                }
                NavigationLink { Text("Rules") } label: {
                    DSListRow("Rules", systemImage: "arrow.triangle.branch", tone: .azure) { DSTag("1 conflict", tint: Color.ds.caution) }
                }
                NavigationLink { Text("Review") } label: {
                    DSListRow("Review", value: "12 waiting", systemImage: "checklist", tone: .amber)
                }
                NavigationLink { Text("Targets") } label: {
                    DSListRow("Targets & caps", systemImage: "target", tone: .cyan)
                }
            }
            DSListSection("Accounts") {
                NavigationLink { Text("Accounts") } label: {
                    DSListRow("Linked accounts", detail: "11 accounts · synced 2 h ago", systemImage: "building.columns", tone: .iris)
                }
            }
            DSListSection("Privacy & security", footer: "The offline copy is encrypted on this phone.") {
                DSToggleRow("Face ID lock", systemImage: "faceid", tone: .teal, isOn: $faceID)
                DSToggleRow("Big amounts", detail: "Anything over $500 that a rule doesn't cover", systemImage: "dollarsign", tone: .coral, isOn: $bigAmounts)
            }
        }
        .dsGroupedList()
        .navigationTitle("Settings")
        .dsInlineNavigationTitle()
    }
}

private extension View {
    @ViewBuilder
    func dsInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#Preview {
    NavigationStack { DesignSystemGallery() }.preferredColorScheme(.dark)
}
