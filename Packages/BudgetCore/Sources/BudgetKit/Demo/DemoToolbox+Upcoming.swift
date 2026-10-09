import Foundation

extension DemoToolbox {
    /// `findUpcoming`: the ledger's `upcoming(days:)`, every amount as `Money.display` and each one a figure, so what
    /// the model says about it is grounded.
    func findUpcoming(days: Int) -> (result: JSONValue, figures: [Figure]) {
        let upcoming = ledger.upcoming(days: min(max(days, 1), 90))
        let day = Date.ISO8601FormatStyle(timeZone: ledger.calendar.timeZone).year().month().day()
        var figures: [Figure] = []
        func totals(_ t: UpcomingTotals, _ id: String, _ label: String) -> JSONValue {
            figures += [Figure(id: "\(id)-income", label: "Income · \(label)", detail: nil, value: t.income),
                        Figure(id: "\(id)-bills", label: "Bills · \(label)", detail: nil, value: t.bills),
                        Figure(id: "\(id)-subs", label: "Subscriptions · \(label)", detail: nil, value: t.subscriptions),
                        Figure(id: "\(id)-charges", label: "Bills and subscriptions · \(label)", detail: nil, value: t.charges),
                        Figure(id: "\(id)-cards", label: "Card bills · \(label)", detail: nil, value: t.cardBills)]
            return .object(["income": .string(t.income.display), "bills": .string(t.bills.display), "subscriptions": .string(t.subscriptions.display),
                            "billsAndSubscriptions": .string(t.charges.display), "cardBills": .string(t.cardBills.display)])
        }
        var o: [String: JSONValue] = [
            "days": .number(Double(upcoming.days)),
            "totals": totals(upcoming.totals, "window", "next \(upcoming.days) days"),
            "nextSevenDays": totals(upcoming.nextSevenDays, "week", "next 7 days"),
        ]
        if let pay = upcoming.nextPaycheck {
            o["nextPaycheck"] = .object(["date": .string(pay.date.formatted(day)), "from": .string(pay.title), "amount": .string(pay.amount.display),
                                         "estimate": .bool(true)])
            figures.append(Figure(id: "next-pay", label: "Next paycheck · \(pay.title)", detail: pay.date.formatted(day), value: pay.amount))
        } else {
            o["nextPaycheck"] = .string("No regular pay shows in the last four months.")
        }
        if let cadence = upcoming.payCadence { o["payComes"] = .string(cadence) }
        o["items"] = .array(upcoming.items.prefix(60).map { item in
            figures.append(Figure(id: "up-\(item.id)", label: item.title, detail: item.date.formatted(day), value: item.amount.magnitude))
            var row: [String: JSONValue] = ["date": .string(item.date.formatted(day)), "kind": .string(item.kind.rawValue), "name": .string(item.title),
                                            "amount": .string(item.amount.magnitude.display),
                                            "direction": .string(item.kind == .income ? "in" : "out")]
            if item.isLate == true { row["late"] = .string(item.kind == .cardBill ? "past due" : "expected earlier, not seen yet") }
            if let minimum = item.minimumPayment {
                row["minimumPayment"] = .string(minimum.display)
                figures.append(Figure(id: "min-\(item.id)", label: "\(item.title) minimum", detail: nil, value: minimum))
            }
            return .object(row)
        })
        o["cardBills"] = .array(upcoming.cardBills.map { bill in
            var row: [String: JSONValue] = ["card": .string(bill.accountName ?? bill.accountID), "status": .string(bill.status?.rawValue ?? "due")]
            if let v = bill.statementBalance { row["statementBalance"] = .string(v.display); figures.append(Figure(id: "stmt-\(bill.id)", label: "\(bill.accountName ?? "Card") statement", detail: nil, value: v)) }
            if let v = bill.remaining { row["leftToPay"] = .string(v.display); figures.append(Figure(id: "left-\(bill.id)", label: "\(bill.accountName ?? "Card") left to pay", detail: nil, value: v)) }
            if let v = bill.minimumPayment { row["minimumPayment"] = .string(v.display); figures.append(Figure(id: "cmin-\(bill.id)", label: "\(bill.accountName ?? "Card") minimum", detail: nil, value: v)) }
            if let v = bill.dueDate { row["due"] = .string(v.formatted(day)) }
            if let v = bill.statementDate { row["statementDate"] = .string(v.formatted(day)) }
            return .object(row)
        })
        o["note"] = .string("Paychecks, bills and subscriptions are predictions from past ones; card bills come from the card issuer. Card bills pay for spending already made.")
        return (.object(o), figures)
    }
}
