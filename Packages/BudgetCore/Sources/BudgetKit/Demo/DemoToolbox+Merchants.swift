import Foundation

// Ask's merchant tools: one merchant in full (`merchantSummary`) and the places the person goes most (`topMerchants`).
// Money is `Money.display`, so grounding matches what the model quotes.

extension DemoToolbox {
    func merchantSummaryTool(_ query: String) throws -> (result: JSONValue, figures: [Figure]) {
        guard let name = ledger.canonicalMerchant(query), let m = try? ledger.merchantSummary(name) else {
            return (.object(["merchant": .string(query), "found": .bool(false), "note": .string("No transactions from this merchant.")]), [])
        }
        var o: [String: JSONValue] = [
            "merchant": .string(m.merchant), "thisMonth": .string(m.thisMonth.display), "last12Months": .string(m.lastTwelveMonths.display),
            "lifetime": .string(m.lifetime.display), "charges": .number(Double(m.charges)),
            "chargesLast12Months": .number(Double(m.chargesLastTwelveMonths)), "frequency": .string(m.frequency),
            "totalsAre": .string("spending net of refunds; hidden rows and transfers left out"),
        ]
        var figures = [Figure(id: "merchant-month", label: "\(m.merchant) · this month", detail: nil, value: m.thisMonth),
                       Figure(id: "merchant-year", label: "\(m.merchant) · last 12 months", detail: "\(m.chargesLastTwelveMonths) charges", value: m.lastTwelveMonths),
                       Figure(id: "merchant-lifetime", label: "\(m.merchant) · all time", detail: "\(m.charges) charges", value: m.lifetime)]
        if let average = m.averageCharge {
            o["averageCharge"] = .string(average.display)
            figures.append(Figure(id: "merchant-average", label: "Average charge", detail: nil, value: average))
        }
        if let first = m.firstCharge { o["firstCharge"] = .string(merchantDay(first)) }
        if let last = m.lastCharge { o["lastCharge"] = .string(merchantDay(last)) }
        if let id = m.categoryID { o["categoryID"] = .string(id) }
        if let recurring = m.recurring {
            o["recurring"] = .object(["cadence": .string(recurring.cadence.rawValue), "kind": .string(recurring.kind.rawValue),
                                      "amount": .string(recurring.amount.display), "nextExpected": .string(merchantDay(recurring.nextExpected)),
                                      "status": .string(recurring.status.rawValue)])
            figures.append(Figure(id: "merchant-recurring", label: "Recurring charge", detail: recurring.cadence.every, value: recurring.amount))
        } else {
            o["recurring"] = .bool(false)
        }
        if let cap = m.cap {
            o["monthlyCap"] = .object(["cap": .string(cap.target.display), "spentThisMonth": .string(cap.spent.display), "capName": .string(cap.merchant)])
            figures.append(Figure(id: "merchant-cap", label: "Monthly cap", detail: cap.merchant, value: cap.target))
        } else {
            o["monthlyCap"] = .string("none set")
        }
        return (.object(o), figures)
    }

    func topMerchantsTool(period: String, sort: TopMerchants.Sort, limit: Int) throws -> (result: JSONValue, figures: [Figure]) {
        let top = try ledger.topMerchants(period: period, limit: min(max(limit, 1), 20), sort: sort)
        let figures = top.merchants.map { Figure(id: "top-\($0.merchant)", label: "\($0.merchant) · \(top.label)", detail: "\($0.visits) charges", value: $0.spent) }
        return (.object([
            "period": .string(top.label), "sortedBy": .string(sort == .visits ? "most charges first" : "most spent first"),
            "merchantsWithCharges": .number(Double(top.merchantCount)),
            "merchants": .array(top.merchants.map { m in
                var o: [String: JSONValue] = ["merchant": .string(m.merchant), "charges": .number(Double(m.visits)), "spent": .string(m.spent.display)]
                if let id = m.categoryID { o["categoryID"] = .string(id) }
                return .object(o)
            }),
        ]), figures)
    }

    private func merchantDay(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: ledger.calendar.timeZone).year().month().day())
    }
}

extension DemoAskEngine {
    /// "Where do I go most?" lists the most visited merchants this month; "How often do I go to Blue Bottle?" or
    /// "Tell me about DoorDash" gives one merchant's page in a sentence.
    func merchantProfileIntent(_ q: String, _ cid: String) -> AskReply? {
        let toolbox = DemoToolbox(ledger: ledger, decisions: nil)
        if ["most often", "most frequent", "top merchants", "shop most", "go most", "visit most"].contains(where: q.contains) {
            guard let out = try? toolbox.topMerchantsTool(period: "this_month", sort: .visits, limit: 5),
                  let top = try? ledger.topMerchants(period: "this_month", limit: 5), let first = top.merchants.first else { return nil }
            let rest = top.merchants.dropFirst().map { "\($0.merchant) (\($0.visits), \($0.spent.display))" }
            let text = "This month you've been to \(first.merchant) most: \(first.visits) charge\(first.visits == 1 ? "" : "s"), \(first.spent.display)."
                + (rest.isEmpty ? "" : " Then \(rest.spokenList).")
            return reply(cid, text: text, figures: out.figures,
                         tools: [call("topMerchants", ["period": .string("this_month"), "sort": .string("visits")])],
                         followUps: ["Tell me about \(first.merchant)"])
        }
        guard ["how often", "tell me about", "average charge", "all time"].contains(where: q.contains),
              let merchant = ledger.merchant(mentionedIn: q), let m = try? ledger.merchantSummary(merchant),
              let out = try? toolbox.merchantSummaryTool(merchant) else { return nil }
        var text = "\(m.merchant): \(m.frequency.prefix(1).lowercased() + m.frequency.dropFirst()), \(m.lastTwelveMonths.display) over the last 12 months"
        if let average = m.averageCharge { text += " at about \(average.display) a charge" }
        text += ". \(m.thisMonth.display) so far this month."
        if let recurring = m.recurring { text += " It recurs \(recurring.cadence.every) at \(recurring.amount.display)." }
        return reply(cid, text: text, figures: out.figures, tools: [call("merchantSummary", ["merchant": .string(m.merchant)])],
                     followUps: ["Cap \(m.merchant) at \(Money(minorUnits: max(m.thisMonth.minorUnits / 1000, 1) * 1000).formatted(fractionDigits: 0)) a month"])
    }
}
