import BudgetKit
import DesignSystem
import PhotosUI
import SwiftUI

/// Opportunity cost: a price — tapped in the live camera, read off a photo or typed — in hours of work before and after
/// tax, in what it would grow to invested instead, and against this month's safe to spend. Opened from the tag button
/// above Ask and from the "Check a Price" shortcut (which the Action button can run). The arithmetic is BudgetKit's
/// (`WorkRate`, `PriceCost`); the pay settings stay on the phone.
///
/// The camera waits for Scan, and closes — the scanner leaves the screen, not just pauses — when a text field takes the
/// keyboard here or on Your pay. Typing hung the app on a phone (never in the simulator, which has no scanner) while
/// VisionKit's scanner was in this sheet, running or paused under Your pay.
struct OpportunityView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile = EarningsProfile.saved
    @State private var paychecks: Paychecks?
    @State private var loaded = false
    @State private var flex: FlexBudget?
    /// The price as typed, or as picked from the camera or a photo ("24.99").
    @State private var typed = ""
    @State private var access: PriceScanner.Access = .unknown
    @State private var photoItem: PhotosPickerItem?
    /// Every price on the last photo, most likely first; the first is the one shown.
    @State private var photoPrices: [Decimal] = []
    @State private var photoNote: String?
    @State private var readingPhoto = false
    @State private var showsPay = false
    @State private var showsCamera = false
    @FocusState private var typing: Bool

    private var price: Decimal? {
        let cleaned = typed.filter { $0.isNumber || $0 == "." }
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }

    private var rate: WorkRate? { WorkRate(profile: profile, paychecksMonthly: paychecks?.monthly) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    if showsCamera { camera.transition(.opacity) }
                    sources
                    priceField
                    result
                    payRow
                }
                .padding(.horizontal, DSSpace.gutter)
                .padding(.bottom, DSSpace.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .dsScreenBackground()
            .navigationTitle("Opportunity cost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
            .navigationDestination(isPresented: $showsPay) { EarningsSettingsView() }
        }
        .presentationBackground(Color.ds.canvas)
        .task { await load() }
        .onAppear {
            if let pending = app.pendingPrice {
                show(pending)
                app.pendingPrice = nil
            }
        }
        .onChange(of: typing) { _, typing in
            if typing {
                closeCamera()
            } else if let price {
                // Grouped once the keyboard is away ("11,299"); `price` reads past the commas.
                show(price)
            }
        }
        .onChange(of: showsPay) { _, open in
            if open {
                closeCamera()
            } else {
                // The pay screen saves as it goes; pick up what it saved on the way back.
                profile = .saved
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            closeCamera()
            Task { await read(item) }
        }
    }

    private func load() async {
        let api = app.api
        let overview = try? await api.overview()
        flex = overview?.flex
        paychecks = try? await Paychecks.load(from: api, asOf: overview?.asOf ?? AppClock.now)
        loaded = true
    }

    private func show(_ amount: Decimal) {
        typed = amount.formatted(.number.precision(.fractionLength(0...2)).grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    // MARK: Camera

    /// Asks for the camera the first time, then opens it.
    private func openCamera() {
        typing = false
        withAnimation(DSMotion.standard) { showsCamera = true }
        guard access == .unknown else { return }
        Task { access = await PriceScanner.requestAccess() }
    }

    private func closeCamera() {
        guard showsCamera else { return }
        withAnimation(DSMotion.standard) { showsCamera = false }
    }

    @ViewBuilder
    private var camera: some View {
        switch access {
        case .ready:
            PriceScanner(isScanning: scenePhase == .active) { amount in
                photoPrices = []
                photoNote = nil
                withAnimation(DSMotion.standard) { show(amount) }
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
            .overlay(alignment: .bottom) {
                Text(price == nil ? "Tap a price" : "Tap another price to compare")
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.ink)
                    .padding(.horizontal, DSSpace.sm)
                    .padding(.vertical, DSSpace.xxs + 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, DSSpace.sm)
            }
            .overlay(alignment: .topTrailing) { closeCameraButton }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Camera. Prices it can read are highlighted; tap one to use it.")
        case .denied:
            DSNoticeCard("The camera is off for Budget",
                         message: "Turn it on in Settings to read prices through the camera. A photo or typing works without it.",
                         systemImage: "camera", tint: Color.ds.amber, actionTitle: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        case .unknown:
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(Color.ds.surface)
                .frame(height: 280)
                .overlay { ProgressView() }
        case .unsupported:
            EmptyView()
        }
    }

    private var closeCameraButton: some View {
        Button(action: closeCamera) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ds.ink)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(DSSpace.xs)
        .accessibilityLabel("Close the camera")
        .accessibilityIdentifier("opportunityCloseCamera")
    }

    // MARK: Photo and typing

    private var sources: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            if PriceScanner.isSupported, !showsCamera {
                Button(action: openCamera) {
                    Label("Scan a price", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.ds(.secondary, fullWidth: true))
                .accessibilityIdentifier("opportunityScan")
            }
            HStack(spacing: DSSpace.sm) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(readingPhoto ? "Reading…" : "From a photo", systemImage: "photo")
                }
                .buttonStyle(.ds(.secondary, fullWidth: true))
                .disabled(readingPhoto)
                Button { typing = true } label: {
                    Label("Type it", systemImage: "keyboard")
                }
                .buttonStyle(.ds(.secondary, fullWidth: true))
            }
            if photoPrices.count > 1 {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    Text("Also on the photo").dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DSSpace.xs) {
                            ForEach(photoPrices, id: \.self) { amount in
                                DSChip(Money(amount).formatted(), isSelected: price == amount) { show(amount) }
                            }
                        }
                    }
                }
            }
            if let photoNote {
                Text(photoNote).dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func read(_ item: PhotosPickerItem) async {
        readingPhoto = true
        defer {
            readingPhoto = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let found = try await PhotoPrices.read(data)
            photoPrices = found
            if let first = found.first {
                withAnimation(DSMotion.standard) { show(first) }
                photoNote = found.count > 1 ? "Picked the biggest price on it. Tap another if that's not the one." : nil
            } else {
                photoNote = "No price on that photo. Try one where the price is easy to read, or type it."
            }
        } catch {
            photoNote = "Couldn't read that photo: \(error.localizedDescription)"
        }
    }

    private var priceField: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSEyebrow("Price")
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("$").dsFont(.amount).foregroundStyle(Color.ds.inkSecondary)
                TextField("Price", text: $typed, prompt: Text("0"))
                    .keyboardType(.decimalPad)
                    .dsFont(.amountXL)
                    .foregroundStyle(Color.ds.ink)
                    .focused($typing)
                    .accessibilityLabel("Price in dollars")
                    .accessibilityIdentifier("opportunityPrice")
            }
            DSDivider()
        }
    }

    // MARK: Result

    @ViewBuilder
    private var result: some View {
        if let price {
            if let rate {
                cost(PriceCost(price: Money(price), rate: rate, profile: profile), rate: rate)
            } else if loaded {
                DSNoticeCard("Add what you earn",
                             message: "No income is filed in your last six months, so there's nothing to count hours from yet.",
                             systemImage: "person.text.rectangle", tint: Color.ds.iris, actionTitle: "Add your pay") { showsPay = true }
            } else {
                LoadingPlaceholder()
            }
        }
    }

    private func cost(_ cost: PriceCost, rate: WorkRate) -> some View {
        let after = flex.flatMap { cost.afterNecessities(everydayBudget: $0.flexNumber, hoursPerWeek: rate.hoursPerWeek) }
        return DSCard {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                // Weeks and days here are working ones (40 hours, 8 hours at 40 a week), not calendar ones.
                DSEyebrow("What it costs you in work time")
                line("Before tax", detail: "At \(rate.grossHourly.formatted()) an hour\(rate.grossIsEstimated ? ", estimated" : "")",
                     hours: cost.hoursBeforeTax, rate: rate, systemImage: "briefcase", tone: .azure)
                DSDivider()
                line("After tax", detail: Self.takeHomeLine(rate), hours: cost.hoursAfterTax, rate: rate, systemImage: "percent", tone: .amber)
                if let flex {
                    DSDivider()
                    if let after {
                        line("After necessities", detail: Self.necessitiesLine(after, everydayBudget: flex.flexNumber),
                             hours: after.hours, rate: rate, systemImage: "cart", tone: .coral)
                    } else {
                        DSListRow("After necessities", detail: "Nothing is left each month after bills, subscriptions and saving, so this would come out of savings.",
                                  systemImage: "cart", tone: .coral)
                    }
                }
                DSDivider()
                // On the necessities footing when there is one, so the lines only climb; take-home otherwise.
                line("Invested instead", detail: Self.investedLine(cost, afterNecessities: after != nil),
                     hours: after?.grownHours ?? cost.hoursForGrownValue, rate: rate, systemImage: "chart.line.uptrend.xyaxis", tone: .iris)
                if let set = rate.incomeNotUsed {
                    DSDivider()
                    Text(Self.incomeNote(set, rate: rate, payType: profile.payType))
                        .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, DSSpace.sm)
                }
                if let flex {
                    DSDivider()
                    fit(cost.fit(safeToSpend: flex.safeToSpend))
                        .padding(.vertical, DSSpace.sm)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func line(_ title: String, detail: String, hours: Double, rate: WorkRate, systemImage: String, tone: DSTone) -> some View {
        DSListRow(title, detail: detail, systemImage: systemImage, tone: tone) {
            let time = WorkTime.describe(hours, hoursPerWeek: rate.hoursPerWeek)
            VStack(alignment: .trailing, spacing: 2) {
                Text(time.headline)
                    .dsFont(.headline)
                    .foregroundStyle(Color.ds.ink)
                    .monospacedDigit()
                if let hours = time.hours {
                    Text("(\(hours))").dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func fit(_ fit: PriceCost.BudgetFit) -> some View {
        let (text, tint): (String, Color) = switch fit {
        case let .within(share, left):
            ("That's \(percent(share)) of what's safe to spend this month (\(left.formatted(fractionDigits: 0)) left).", Color.ds.inkSecondary)
        case let .over(by):
            ("That's \(by.formatted(fractionDigits: 0)) more than what's safe to spend this month.", Color.ds.caution)
        case let .alreadyOver(safe):
            ("Safe to spend is \(safe.formatted(fractionDigits: 0)) this month, so this would come out of savings.", Color.ds.caution)
        }
        return HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
            Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(tint)
            Text(text).dsFont(.callout).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percent(_ share: Double) -> String {
        share < 0.01 && share > 0 ? "under 1%" : share.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Pay

    private var payRow: some View {
        Button { showsPay = true } label: {
            DSListRow("Your pay", detail: payDetail, systemImage: "banknote", tone: .teal, showsChevron: true)
                .padding(.horizontal, DSSpace.md)
                .background(Color.ds.surface, in: RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("opportunityPay")
    }

    private var payDetail: String {
        guard let rate else { return loaded ? "Add what you earn" : "Loading…" }
        let source = profile.takeHomeMonthly != nil ? "the take-home you typed"
            : rate.takeHomeIsEstimated ? "an estimate from your \(profile.payType == .salary ? "salary" : "wage")" : "your paychecks"
        return "\(profile.payType.label) · \(rate.takeHomeMonthly.formatted(fractionDigits: 0)) a month take-home, from \(source)"
    }

    /// "$34.20 an hour take-home · 22% withheld" — the share left out when there is none to say. Short, since it sits
    /// beside the hours in a narrow column.
    static func takeHomeLine(_ rate: WorkRate) -> String {
        let hourly = "\(rate.takeHomeHourly.formatted()) an hour take-home"
        let estimated = rate.takeHomeIsEstimated ? ", estimated" : ""
        guard rate.withheldShare >= 0.01 else { return hourly + estimated }
        return "\(hourly)\(estimated) · \(rate.withheldShare.formatted(.percent.precision(.fractionLength(0)))) withheld"
    }

    /// "1.2 months of the $500 a month left after bills, subscriptions and saving", "About 2 months of…" when a tenth
    /// rounds away, or "12% of…" under a month.
    static func necessitiesLine(_ after: PriceCost.AfterNecessities, everydayBudget: Money) -> String {
        let tenths = (after.months * 10).rounded() / 10
        let months = tenths == 1 ? "a month" : "\(tenths.formatted(.number.precision(.fractionLength(0...1)))) months"
        let rounded = tenths == tenths.rounded() && abs(after.months - tenths) >= 0.005
        let share = after.months >= 1
            ? (rounded ? "About \(months)" : months.prefix(1).uppercased() + months.dropFirst())
            : after.months < 0.01 ? "Under 1%" : after.months.formatted(.percent.precision(.fractionLength(0)))
        return "\(share) of the \(everydayBudget.formatted(fractionDigits: 0)) a month left after bills, subscriptions and saving"
    }

    /// "The $18,151 it'd grow to in 10 years in today's dollars, from what's left after necessities", or "…at take-home
    /// pay" when there's no everyday budget to put it against.
    static func investedLine(_ cost: PriceCost, afterNecessities: Bool) -> String {
        let footing = afterNecessities ? ", from what's left after necessities" : ", at take-home pay"
        return "The \(cost.grownValue.formatted(fractionDigits: 0)) it'd grow to in \(cost.years) years in today's dollars\(footing)"
    }

    /// Why take-home isn't what the Income category says.
    static func incomeNote(_ income: Money, rate: WorkRate, payType: EarningsProfile.PayType) -> String {
        let pay = payType == .salary ? "this salary" : "this wage"
        return "Your Income comes to \(income.formatted(fractionDigits: 0)) a month, more than \(pay) leaves after tax, so it likely includes other money. Take-home here is estimated from \(pay); type yours in Your pay to use it instead."
    }
}
