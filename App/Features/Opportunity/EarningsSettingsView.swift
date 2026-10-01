import BudgetKit
import DesignSystem
import SwiftUI

/// What opportunity cost counts from: how you're paid, take-home (your paychecks unless you type it), and how money
/// invested instead would grow. Saved on this phone as it changes; nothing goes to the server. Opened from the
/// opportunity-cost screen and from Settings.
struct EarningsSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var profile = EarningsProfile.saved
    @State private var paychecks: Paychecks?
    @State private var loaded = false
    @State private var grossText = ""
    @State private var takeHomeText = ""
    @FocusState private var editing: Field?

    private enum Field { case pay, takeHome }

    private var rate: WorkRate? { WorkRate(profile: profile, paychecksMonthly: paychecks?.monthly) }

    var body: some View {
        List {
            paySection
            takeHomeSection
            growthSection
            if let rate { summary(rate) }
        }
        .dsGroupedList()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Your pay")
        .navigationBarTitleDisplayMode(.inline)
        // A decimal pad has no return key.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = nil }
            }
        }
        .onAppear {
            grossText = Self.text(profile.grossPay)
            takeHomeText = Self.text(profile.takeHomeMonthly)
        }
        .task {
            let api = app.api
            let asOf = (try? await api.overview())?.asOf ?? AppClock.now
            paychecks = try? await Paychecks.load(from: api, asOf: asOf)
            loaded = true
        }
        .onChange(of: profile) { _, next in next.save() }
        .onChange(of: grossText) { _, text in profile.grossPay = Self.amount(text) }
        .onChange(of: takeHomeText) { _, text in profile.takeHomeMonthly = Self.amount(text) }
    }

    // MARK: Pay

    private var paySection: some View {
        DSListSection("How you're paid", footer: "Leave pay empty and Budget estimates it from your paychecks, using 2026 federal tax, Social Security and Medicare for a single filer. That leaves out state tax, 401(k) and benefits, so it usually runs a little low.") {
            Picker("Paid", selection: $profile.payType) {
                ForEach(EarningsProfile.PayType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .segmentedUnlessLargeText()
            .padding(.vertical, DSSpace.sm)
            SettingsField(profile.payType == .salary ? "Yearly pay, before tax" : "Hourly wage, before tax") {
                HStack(spacing: 2) {
                    Text("$").foregroundStyle(Color.ds.inkSecondary)
                    TextField("Pay", text: $grossText, prompt: Text(grossPrompt))
                        .keyboardType(.decimalPad)
                        .focused($editing, equals: .pay)
                        .accessibilityLabel(profile.payType == .salary ? "Yearly pay before tax, in dollars" : "Hourly wage before tax, in dollars")
                }
            }
            hours
        }
    }

    /// What Budget would use if the field stays empty.
    private var grossPrompt: String {
        guard let rate, rate.grossIsEstimated else { return profile.payType == .salary ? "85,000" : "30" }
        let estimate = profile.payType == .salary ? rate.grossYearly.formatted(fractionDigits: 0) : rate.grossHourly.formatted()
        return "About \(estimate.replacingOccurrences(of: "$", with: "")), estimated"
    }

    @ViewBuilder
    private var hours: some View {
        if let rate, rate.hoursAreInferred {
            DSListRow("Hours a week", detail: "Your paychecks at this wage", value: "About \(Int(rate.hoursPerWeek.rounded()))")
        } else {
            Stepper(value: $profile.hoursPerWeek, in: 5...80, step: 1) {
                DSListRow("Hours a week", value: "\(Int(profile.hoursPerWeek))")
            }
        }
    }

    // MARK: Take-home

    private var takeHomeSection: some View {
        DSListSection("Take-home", footer: "Paychecks land after tax, so this is what an hour of work actually buys. It's the middle month of your Income category, so a bonus or a refund doesn't count as pay; anything else filed there that isn't pay belongs in another category.") {
            DSListRow("From your paychecks", detail: paycheckDetail, value: paychecks.map { "\($0.monthly.formatted(fractionDigits: 0))/mo" })
            SettingsField("Use this instead, a month") {
                HStack(spacing: 2) {
                    Text("$").foregroundStyle(Color.ds.inkSecondary)
                    TextField("Take-home", text: $takeHomeText, prompt: Text("Leave empty to use your paychecks"))
                        .keyboardType(.decimalPad)
                        .focused($editing, equals: .takeHome)
                        .accessibilityLabel("Take-home a month, in dollars")
                }
            }
        }
    }

    private var paycheckDetail: String {
        guard loaded else { return "Loading…" }
        guard let paychecks else { return "No income filed in the last six months" }
        return paychecks.months.count == 1 ? "Income filed in \(paychecks.span)" : "A typical month of income, \(paychecks.span)"
    }

    // MARK: Growth

    private var growthSection: some View {
        DSListSection("If you invested it instead", footer: "8% is about the stock market's long-run average. Inflation comes out of it, so what a price would grow to is in today's dollars and compares fairly with today's pay.") {
            Stepper(value: $profile.annualReturn, in: 0...0.15, step: 0.005) {
                DSListRow("Return a year", value: Self.percent(profile.annualReturn))
            }
            Stepper(value: $profile.inflation, in: 0...0.1, step: 0.005) {
                DSListRow("Inflation a year", value: Self.percent(profile.inflation))
            }
            Stepper(value: $profile.years, in: 1...40) {
                DSListRow("Years", value: "\(profile.years)")
            }
        }
    }

    private func summary(_ rate: WorkRate) -> some View {
        DSListSection("An hour of your work") {
            DSListRow("Before tax", detail: rate.grossIsEstimated ? "Estimated" : nil, value: rate.grossHourly.formatted())
            DSListRow("Take-home", detail: OpportunityView.takeHomeLine(rate), value: rate.takeHomeHourly.formatted())
            if let income = rate.incomeNotUsed {
                SettingsNote(text: OpportunityView.incomeNote(income, rate: rate, payType: profile.payType), systemImage: "info.circle")
            }
        }
    }

    // MARK: Parsing

    private static func amount(_ text: String) -> Decimal? {
        let cleaned = text.filter { $0.isNumber || $0 == "." }
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }

    private static func text(_ amount: Decimal?) -> String {
        amount.map { $0.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))) } ?? ""
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0...1)))
    }
}
