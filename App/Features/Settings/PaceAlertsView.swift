import BudgetKit
import DesignSystem
import SwiftUI

/// Settings → Notifications → Pace alerts: which heads-ups this phone gets when the month runs ahead — the everyday
/// budget on pace to finish over, a category target or merchant cap at 80% or on pace to go over — and what they'd
/// say right now. The ledger works every figure out (`GET /v1/alerts/pace`); the server sends them.
struct PaceAlertsView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<PaceAlerts> = .loading
    /// The server answered 404: it's older than pace alerts.
    @State private var tooOld = false

    private var morning: MorningSummaryModel { .shared }

    var body: some View {
        List {
            SettingsCaption("A heads-up when the month is running ahead of what you set. Each one comes once a month at most, and only between 9 am and 9 pm wherever your phone is.")
            choices
            rightNow
        }
        .dsGroupedList()
        .dsScreenBackground()
        .navigationTitle("Pace alerts")
        .navigationBarTitleDisplayMode(.inline)
        .announcesProblem(morning.problem)
        .task(id: app.revision) { await load() }
        .reloadable(button: false) { await load() }
    }

    // MARK: Sections

    private var choices: some View {
        DSListSection("Send me", footer: choicesFooter) {
            DSToggleRow("Everyday budget", detail: "When this month is on pace to finish over", systemImage: "gauge.with.dots.needle.67percent",
                        tone: .cyan, isOn: binding(.everyday))
                .accessibilityIdentifier("paceEveryday")
            DSToggleRow("Category targets", detail: "At 80% of a target, or on pace to go over", systemImage: "chart.pie", tone: .amber,
                        isOn: binding(.category))
                .accessibilityIdentifier("paceCategories")
            DSToggleRow("Merchant caps", detail: "At 80% of a cap, or on pace to go over", systemImage: "storefront", tone: .violet,
                        isOn: binding(.merchant))
                .accessibilityIdentifier("paceMerchants")
        }
        .disabled(!canChoose)
    }

    @ViewBuilder
    private var rightNow: some View {
        switch state {
        case .loading:
            DSListSection("Right now") { LoadingPlaceholder(text: "Checking this month's pace…") }
        case let .failed(message):
            DSListSection("Right now") { SettingsNote(text: message, tint: Color.ds.caution, systemImage: "exclamationmark.triangle.fill") }
        case let .loaded(report):
            DSListSection("Right now", footer: report.projecting ? "On pace means this month so far, spread over the whole month."
                                                                 : "Projections start in the month's second week; until then only what's spent counts.") {
                let others = report.alerts.filter { $0.kind != .everyday }
                if let everyday = report.everyday { everydayRow(everyday) }
                ForEach(others, id: \.id) { alert in alertRow(alert, month: report.month) }
                if others.isEmpty { SettingsNote(text: "No target or cap is at 80% or on pace to go over.") }
            }
        }
    }

    /// The everyday budget always shows, alerting or not: it's the pace the others sit inside.
    private func everydayRow(_ s: PaceStatus) -> some View {
        let alert = (state.value?.alerts ?? []).first { $0.kind == .everyday }
        let detail: String = if let over = s.over {
            "\(over.formatted(fractionDigits: 0)) past the \(s.limit.formatted(fractionDigits: 0)) budget"
        } else if let projected = s.projected {
            "On pace for \(projected.formatted(fractionDigits: 0)) of \(s.limit.formatted(fractionDigits: 0))"
                + (s.perDayLeft.map { " · \($0.formatted(fractionDigits: 0))/day keeps you on budget" } ?? "")
        } else {
            "\(s.spent.formatted(fractionDigits: 0)) of \(s.limit.formatted(fractionDigits: 0)) so far"
        }
        return Button { morning.open(alert ?? Self.budgetAlert, month: state.value?.month ?? "") } label: {
            DSListRow(alert?.title ?? "Everyday is on track", detail: detail, systemImage: "gauge.with.dots.needle.67percent",
                      tone: alert == nil ? .cyan : .orchid) {
                DSListValue("\(s.usedPercent)%", showsChevron: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this month's budget")
    }

    private func alertRow(_ alert: PaceAlert, month: String) -> some View {
        Button { morning.open(alert, month: month) } label: {
            DSListRow(alert.title, detail: alert.body, systemImage: alert.kind == .merchant ? "storefront" : "chart.pie",
                      // Caution is orchid and carries its glyph; 80% used is something to watch.
                      tone: alert.threshold == .used80 ? .amber : .orchid) {
                DSListValue("\(alert.status.usedPercent)%", showsChevron: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(alert.kind == .merchant ? "Shows \(alert.name) charges in Activity" : "Opens the category")
    }

    // MARK: State

    /// Only with a server of your own that keeps the choice (0.5.0 on).
    private var canChoose: Bool { morning.available && !tooOld && !morning.paceUnsupported && !morning.working }

    private var choicesFooter: String? {
        if !morning.available { return "The demo has no server to send from. Below is what pace alerts would say now." }
        if tooOld || morning.paceUnsupported { return "Your server doesn't send pace alerts yet. Update it to 0.5.0 or later." }
        if let problem = morning.problem { return problem }
        if morning.blockedInSettings { return "Notifications are off for Budget in iOS Settings, so nothing will show." }
        if let status = morning.status, !status.pushConfigured, morning.paceActive {
            return "Your server can't send yet: add an APNs key on the dashboard, under Notifications."
        }
        return nil
    }

    private func binding(_ kind: PaceAlert.Kind) -> Binding<Bool> {
        Binding(get: { morning.wantsPace(kind) }, set: { on in Task { await morning.setPace(kind, on) } })
    }

    private static let budgetAlert = PaceAlert(kind: .everyday, threshold: .unknown, targetID: "everyday", name: "Everyday",
                                               status: PaceStatus(spent: .zero, limit: .zero, projected: nil, perDayLeft: nil, usedPercent: 0),
                                               title: "", body: "", link: .budget)

    @discardableResult
    private func load() async -> String? {
        guard let api = app.api as? any PaceAlertsAPI else {
            state = .failed("Pace alerts need a server of your own.")
            return nil
        }
        do {
            state = .loaded(try await api.paceAlerts())
            tooOld = false
            return nil
        } catch BudgetAPIError.notFound {
            tooOld = true
            state = .failed("Your server doesn't work out pace alerts yet. Update it to 0.5.0 or later.")
            return nil
        } catch {
            if Task.isCancelled { return nil }
            if state.value == nil { state = .failed(error.localizedDescription) }
            return error.localizedDescription
        }
    }
}
