import Foundation

extension Ledger {
    /// The demo household's Plan scenarios, dated from the demo's own month so they always lie ahead: a car bought in
    /// five months, a bonus this December and a raise in January, and a move next summer with one change switched off.
    mutating func addPlanScenarios() {
        let current = monthKey(now)
        func ahead(_ months: Int) -> String { PlanMonth.adding(months, to: current)! }
        let month = calendar.component(.month, from: now)
        // This December, or next year's when the demo's month is December already.
        let december = ahead(month == 12 ? 12 : 12 - month)
        let january = PlanMonth.adding(1, to: december)!
        let june = PlanMonth.adding(6, to: december)!
        planScenarios = [
            PlanScenario(id: "scn-car", name: "New car", events: [
                PlanEvent(id: "evt-car-down", name: "Down payment", kind: .expense, amount: Money(3000), startMonth: ahead(5), cadence: .once),
                PlanEvent(id: "evt-car-loan", name: "Car payment", kind: .expense, amount: Money(450), startMonth: ahead(5),
                          endMonth: ahead(5 + 59), cadence: .monthly),
                PlanEvent(id: "evt-car-insurance", name: "Higher insurance", kind: .expense, amount: Money(60), startMonth: ahead(5), cadence: .monthly),
            ]),
            PlanScenario(id: "scn-bonus", name: "Bonus and raise", events: [
                PlanEvent(id: "evt-bonus", name: "Year-end bonus", kind: .income, amount: Money(5000), startMonth: december, cadence: .once),
                PlanEvent(id: "evt-raise", name: "Raise", kind: .income, amount: Money(320), startMonth: january, cadence: .monthly),
            ]),
            PlanScenario(id: "scn-move", name: "Bigger place", events: [
                PlanEvent(id: "evt-movers", name: "Movers", kind: .expense, amount: Money(1800), startMonth: june, cadence: .once),
                PlanEvent(id: "evt-rent", name: "Rent goes up", kind: .expense, amount: Money(200), startMonth: june, cadence: .monthly),
                PlanEvent(id: "evt-renters", name: "Renters insurance", kind: .expense, amount: Money(180), startMonth: june, cadence: .yearly),
                PlanEvent(id: "evt-couch", name: "Sell the old couch", kind: .income, amount: Money(250), startMonth: june, cadence: .once,
                          isEnabled: false),
            ]),
        ]
    }
}
