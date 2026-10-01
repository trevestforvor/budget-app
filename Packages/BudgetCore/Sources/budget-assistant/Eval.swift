import BudgetKit
import Foundation

/// A labeled categorization eval: realistic US bank descriptors with the right answer, plus
/// acceptable alternatives where reasonable people differ. `ambiguous` items are ones a careful
/// human couldn't call from the descriptor alone — a well-calibrated model should be unsure there.
struct EvalItem {
    var raw: String
    var merchant: String
    var amount: Decimal
    var gold: String
    var alsoOK: [String] = []
    var ambiguous = false

    func correct(_ answer: String) -> Bool { answer == gold || alsoOK.contains(answer) }
}

enum CategorizeEval {
    static let version = "categorize-v1 (2026-09-25, 64 items)"

    static let items: [EvalItem] = [
        .init(raw: "UBER *TRIP HELP.UBER.COM", merchant: "Uber", amount: -24.18, gold: "transport"),
        .init(raw: "UBER *EATS PENDING", merchant: "Uber Eats", amount: -38.40, gold: "dining"),
        .init(raw: "LYFT *RIDE SUN 5PM", merchant: "Lyft", amount: -18.20, gold: "transport"),
        .init(raw: "SHELL OIL 57444839", merchant: "Shell", amount: -52.10, gold: "transport"),
        .init(raw: "CHEVRON 0204371", merchant: "Chevron", amount: -61.35, gold: "transport"),
        .init(raw: "METRO TRANSIT SERVICE", merchant: "Metro Transit", amount: -20, gold: "transport"),
        .init(raw: "SQ *BLUE BOTTLE COFFEE", merchant: "Blue Bottle Coffee", amount: -6.25, gold: "dining"),
        .init(raw: "STARBUCKS STORE 08812", merchant: "Starbucks", amount: -5.45, gold: "dining"),
        .init(raw: "DD *DOORDASH CHIPOTLE", merchant: "DoorDash", amount: -28.90, gold: "dining"),
        .init(raw: "TST* HARVEST TABLE", merchant: "Harvest Table", amount: -96.40, gold: "dining"),
        .init(raw: "SWEETGREEN MISSION", merchant: "Sweetgreen", amount: -15.95, gold: "dining"),
        .init(raw: "MCDONALD'S F12345", merchant: "McDonald's", amount: -11.20, gold: "dining"),
        .init(raw: "TST* LOCAL 123", merchant: "Local 123", amount: -17.25, gold: "dining"),
        .init(raw: "SQ *CASA TACO 0423", merchant: "Casa Taco", amount: -23.50, gold: "dining"),
        .init(raw: "TRADER JOE S #236 QPS", merchant: "Trader Joe's", amount: -84.12, gold: "groceries"),
        .init(raw: "WHOLEFDS MKT 10238", merchant: "Whole Foods Market", amount: -112.40, gold: "groceries"),
        .init(raw: "SAFEWAY #1507", merchant: "Safeway", amount: -64.18, gold: "groceries"),
        .init(raw: "INSTACART", merchant: "Instacart", amount: -142.30, gold: "groceries"),
        .init(raw: "COSTCO WHSE #0144", merchant: "Costco", amount: -236.80, gold: "groceries", alsoOK: ["shopping"]),
        .init(raw: "TARGET 00027", merchant: "Target", amount: -58.99, gold: "shopping", alsoOK: ["groceries"]),
        .init(raw: "AMAZON.COM*RT4K29", merchant: "Amazon", amount: -42.17, gold: "shopping"),
        .init(raw: "AMZN MKTP US*2K4LL", merchant: "Amazon Marketplace", amount: -23.99, gold: "shopping"),
        .init(raw: "UNIQLO USA", merchant: "Uniqlo", amount: -89.70, gold: "shopping"),
        .init(raw: "THE HOME DEPOT #0651", merchant: "The Home Depot", amount: -73.20, gold: "shopping"),
        .init(raw: "PETCO 1234", merchant: "Petco", amount: -41.50, gold: "shopping"),
        .init(raw: "BEST BUY 00012", merchant: "Best Buy", amount: -219.99, gold: "shopping"),
        .init(raw: "NETFLIX.COM", merchant: "Netflix", amount: -15.49, gold: "subscriptions"),
        .init(raw: "SPOTIFY USA", merchant: "Spotify", amount: -11.99, gold: "subscriptions"),
        .init(raw: "APPLE.COM/BILL 866-712", merchant: "Apple", amount: -2.99, gold: "subscriptions", alsoOK: ["shopping"]),
        .init(raw: "NYTIMES DIGITAL", merchant: "The New York Times", amount: -25, gold: "subscriptions"),
        .init(raw: "OPENAI *CHATGPT SUBSCR", merchant: "OpenAI", amount: -20, gold: "subscriptions"),
        .init(raw: "HULU 877-8244858", merchant: "Hulu", amount: -17.99, gold: "subscriptions"),
        .init(raw: "PEAK FITNESS #144", merchant: "Peak Fitness", amount: -185, gold: "health", alsoOK: ["subscriptions"]),
        .init(raw: "CVS/PHARMACY #09112", merchant: "CVS", amount: -31.84, gold: "health", alsoOK: ["shopping"]),
        .init(raw: "WALGREENS #3021", merchant: "Walgreens", amount: -18.60, gold: "health", alsoOK: ["shopping"]),
        .init(raw: "CHECKCARD 0917 CVS/PHARM", merchant: "CVS", amount: -31.84, gold: "health", alsoOK: ["shopping"]),
        .init(raw: "QUEST DIAGNOSTICS", merchant: "Quest Diagnostics", amount: -40, gold: "health"),
        .init(raw: "TELADOC HEALTH", merchant: "Teladoc", amount: -199, gold: "health", alsoOK: ["subscriptions"]),
        .init(raw: "CITYPOWER WEB ONLINE", merchant: "City Power", amount: -142.18, gold: "utilities"),
        .init(raw: "COMCAST XFINITY", merchant: "Xfinity", amount: -79.99, gold: "utilities"),
        .init(raw: "VERIZON WRLS P1234", merchant: "Verizon", amount: -85, gold: "utilities"),
        .init(raw: "CITY WATER UTIL", merchant: "City Water", amount: -64.20, gold: "utilities"),
        .init(raw: "MAPLE CT APTS ACH", merchant: "Maple Court Apartments", amount: -2400, gold: "housing"),
        .init(raw: "KEYSTONE RENT PAYMENT", merchant: "Keystone", amount: -2400, gold: "housing"),
        .init(raw: "LEMONADE INSURANCE", merchant: "Lemonade", amount: -18, gold: "housing", alsoOK: ["utilities", "subscriptions"], ambiguous: true),
        .init(raw: "UNITED 0162348851", merchant: "United Airlines", amount: -486.20, gold: "travel"),
        .init(raw: "DELTA AIR 0062345", merchant: "Delta", amount: -312.40, gold: "travel"),
        .init(raw: "AIRBNB * HMXZ12", merchant: "Airbnb", amount: -612, gold: "travel"),
        .init(raw: "MARRIOTT DOWNTOWN", merchant: "Marriott", amount: -289, gold: "travel"),
        .init(raw: "HERTZ RENT-A-CAR", merchant: "Hertz", amount: -178, gold: "travel", alsoOK: ["transport"]),
        .init(raw: "ACME CORP PAYROLL PPD", merchant: "Acme Corp", amount: 3850, gold: "income"),
        .init(raw: "INTEREST PAYMENT", merchant: "Interest", amount: 12.44, gold: "income"),
        .init(raw: "IRS TREAS 310 TAX REF", merchant: "IRS", amount: 842, gold: "income"),
        .init(raw: "AMAZON.COM REFUND", merchant: "Amazon", amount: 42.17, gold: "income", alsoOK: ["shopping"]),
        .init(raw: "ONLINE TRANSFER TO SAV", merchant: "Transfer to Savings", amount: -500, gold: "transfer"),
        .init(raw: "SUMMIT EPAYMENT ACH PMT", merchant: "Summit Payment", amount: -1741.62, gold: "transfer"),
        .init(raw: "HARBOR CREDIT CRD AUTOPAY", merchant: "Harbor Card Payment", amount: -612.40, gold: "transfer"),
        .init(raw: "MEADOW EDI PYMNTS", merchant: "Meadow", amount: -1000, gold: "transfer"),
        .init(raw: "TIDEWATER DEBITS", merchant: "Tidewater", amount: -250, gold: "transfer"),
        .init(raw: "ATM WITHDRAWAL 0923", merchant: "ATM", amount: -100, gold: "transfer", alsoOK: ["shopping"], ambiguous: true),
        .init(raw: "ZELLE TO JOHN SMITH", merchant: "Zelle", amount: -60, gold: "transfer", alsoOK: ["dining", "housing"], ambiguous: true),
        .init(raw: "VENMO *J. PARK", merchant: "Venmo", amount: -45, gold: "transfer", alsoOK: ["dining"], ambiguous: true),
        .init(raw: "VENMO CASHOUT", merchant: "Venmo", amount: 200, gold: "transfer", alsoOK: ["income"]),
        .init(raw: "PAYPAL *XJ29QK", merchant: "PayPal", amount: -64, gold: "shopping", alsoOK: ["subscriptions", "transfer"], ambiguous: true),
    ]

    struct Result {
        var provider: String
        var items: Int
        var accuracy: Double
        var ece: Double
        var seconds: Double
        var thresholds: [(t: Double, coverage: Double, precision: Double, wrongAccepted: Int)]
        var meanConfidenceClear: Double
        var meanConfidenceAmbiguous: Double
        var misses: [String]
    }

    static func run(_ model: any DecisionModel, categories: [BudgetCategory], repeatCount: Int = 1) async throws -> Result {
        let set = Array(repeating: items, count: max(1, repeatCount)).flatMap { $0 }
        let requests = set.map { CategoryDecisions.request(merchant: $0.merchant, rawDescription: $0.raw, amount: Money($0.amount), categories: categories) }
        let started = Date()
        let responses = try await model.decide(requests)
        let seconds = Date().timeIntervalSince(started)

        let scored = zip(set, responses).map { item, response -> (item: EvalItem, answer: String, confidence: Double, ok: Bool) in
            let a = response.answers[CategoryDecisions.questionID]
            let answer = a?.value ?? "none"
            return (item, answer, a?.confidence ?? 0, item.correct(answer))
        }
        let n = Double(scored.count)
        let accuracy = Double(scored.filter(\.ok).count) / n

        // Expected calibration error, 10 equal-width bins on the top-label confidence.
        var ece = 0.0
        for bin in 0..<10 {
            let lo = Double(bin) / 10, hi = Double(bin + 1) / 10
            let members = scored.filter { $0.confidence > lo && $0.confidence <= hi || (bin == 0 && $0.confidence == 0) }
            guard !members.isEmpty else { continue }
            let conf = members.map(\.confidence).reduce(0, +) / Double(members.count)
            let acc = Double(members.filter(\.ok).count) / Double(members.count)
            ece += Double(members.count) / n * abs(conf - acc)
        }

        let thresholds = [0.5, 0.8, 0.9, 0.95, 0.99].map { t -> (Double, Double, Double, Int) in
            let accepted = scored.filter { $0.confidence >= t }
            let right = accepted.filter(\.ok).count
            return (t, Double(accepted.count) / n, accepted.isEmpty ? 1 : Double(right) / Double(accepted.count), accepted.count - right)
        }
        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        let first = Array(scored.prefix(items.count))
        return Result(
            provider: model.label, items: scored.count, accuracy: accuracy, ece: ece, seconds: seconds, thresholds: thresholds,
            meanConfidenceClear: mean(first.filter { !$0.item.ambiguous }.map(\.confidence)),
            meanConfidenceAmbiguous: mean(first.filter { $0.item.ambiguous }.map(\.confidence)),
            misses: first.filter { !$0.ok }.map { "\($0.item.raw) → \($0.answer) \(Int(($0.confidence * 100).rounded()))% (expected \($0.item.gold))" })
    }

    static func markdown(_ r: Result) -> String {
        var s = "### \(r.provider)\n\n"
        s += "\(r.items) decisions in \(String(format: "%.2f", r.seconds)) s (\(String(format: "%.1f", Double(r.items) / max(r.seconds, 0.001))) decisions/s). "
        s += "Accuracy **\(pct(r.accuracy))**, ECE **\(String(format: "%.3f", r.ece))**. "
        s += "Mean confidence: clear items \(pct(r.meanConfidenceClear)), ambiguous items \(pct(r.meanConfidenceAmbiguous)).\n\n"
        s += "| Auto-accept at | Filed automatically | Correct among filed | Wrong but filed |\n|---|---|---|---|\n"
        for t in r.thresholds { s += "| \(Int(t.t * 100))% | \(pct(t.coverage)) | \(pct(t.precision)) | \(t.wrongAccepted) |\n" }
        if !r.misses.isEmpty { s += "\nMisses:\n" + r.misses.map { "- `\($0)`" }.joined(separator: "\n") + "\n" }
        return s
    }

    static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}
