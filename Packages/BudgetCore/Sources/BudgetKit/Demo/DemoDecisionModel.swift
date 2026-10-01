import Foundation

/// Deterministic stand-in for a decision model, so the demo shows threshold behavior.
/// Confidences are plausible for the demo's unsure rows: a clear Square taco shop scores
/// high, PayPal (merchant hidden) scores low.
struct DemoDecisionModel: DecisionModel {
    let provider: DecisionProvider

    var label: String {
        switch provider {
        case .jev: "jev-1.13 (demo)"
        case .laya: "laya-0.3.20 (demo)"
        default: "qwen3.8-27b-decide (demo)"
        }
    }

    var runsLocally: Bool { provider.runsLocally }

    static let table: [(match: String, distribution: [String: Double])] = [
        ("CASA TACO", ["dining": 0.91, "groceries": 0.06, "shopping": 0.03]),
        ("LOCAL", ["dining": 0.86, "shopping": 0.09, "groceries": 0.05]),
        ("APPLE.COM/BILL", ["subscriptions": 0.84, "shopping": 0.14, "utilities": 0.02]),
        ("AMZN", ["shopping": 0.74, "groceries": 0.22, "health": 0.04]),
        ("CVS", ["health": 0.66, "shopping": 0.30, "groceries": 0.04]),
        ("VENMO", ["transfer": 0.58, "dining": 0.35, "shopping": 0.07]),
        ("PAYPAL", ["shopping": 0.47, "subscriptions": 0.41, "transfer": 0.12]),
        ("WITHDRAWAL", ["transfer": 0.62, "housing": 0.21, "shopping": 0.17]),
    ]

    /// Jev's answers on the rows the local model was least sure of — mirrors decision-bench,
    /// where Jev led on intent-style label sets.
    static let jevTable: [(match: String, distribution: [String: Double])] = [
        ("CASA TACO", ["dining": 0.94, "groceries": 0.04, "shopping": 0.02]),
        ("LOCAL", ["dining": 0.81, "shopping": 0.12, "groceries": 0.07]),
        ("APPLE.COM/BILL", ["subscriptions": 0.88, "shopping": 0.10, "utilities": 0.02]),
        ("AMZN", ["shopping": 0.83, "groceries": 0.14, "health": 0.03]),
        ("CVS", ["health": 0.71, "shopping": 0.25, "groceries": 0.04]),
        ("VENMO", ["transfer": 0.88, "dining": 0.09, "shopping": 0.03]),
        ("PAYPAL", ["shopping": 0.52, "subscriptions": 0.40, "transfer": 0.08]),
        ("WITHDRAWAL", ["transfer": 0.71, "housing": 0.17, "shopping": 0.12]),
    ]

    func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
        let table = provider == .jev ? Self.jevTable : Self.table
        return requests.map { request in
            let state = request.state.uppercased()
            let distribution = table.first { state.contains($0.match) }?.distribution ?? ["shopping": 0.4, "groceries": 0.3, "dining": 0.3]
            let best = distribution.max { $0.value < $1.value }!
            return DecisionResponse(answers: [CategoryDecisions.questionID: DecisionAnswer(value: best.key, confidence: best.value, distribution: distribution)],
                                    model: label)
        }
    }
}
