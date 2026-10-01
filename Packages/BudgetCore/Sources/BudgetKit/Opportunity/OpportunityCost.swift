import Foundation

// What a price costs in work and in growth given up — the numbers behind the phone's opportunity-cost screen. All of
// it is arithmetic on what the person set and what their paychecks show; nothing here asks a model or the server.

/// How the person is paid and how to count growth, as they set it. Kept on the phone.
public struct EarningsProfile: Codable, Hashable, Sendable {
    public enum PayType: String, Codable, CaseIterable, Sendable {
        case salary, hourly

        public var label: String {
            switch self {
            case .salary: "Salary"
            case .hourly: "Hourly"
            }
        }
    }

    public var payType: PayType
    /// Gross pay as the person gave it: a year's salary, or an hourly wage. Nil estimates it from take-home.
    public var grossPay: Decimal?
    /// Take-home a month as the person typed it; nil uses what the paychecks show.
    public var takeHomeMonthly: Decimal?
    /// Hours worked a week. With an hourly wage and paychecks to go on, the paychecks decide this instead.
    public var hoursPerWeek: Double
    /// Expected yearly return on money invested instead (0.08 is 8%).
    public var annualReturn: Double
    /// Yearly inflation taken out of that return, so the growth is in today's dollars.
    public var inflation: Double
    /// How many years ahead the growth is counted.
    public var years: Int

    public init(payType: PayType = .salary, grossPay: Decimal? = nil, takeHomeMonthly: Decimal? = nil, hoursPerWeek: Double = 40,
                annualReturn: Double = 0.08, inflation: Double = 0.03, years: Int = 10) {
        self.payType = payType
        self.grossPay = grossPay
        self.takeHomeMonthly = takeHomeMonthly
        self.hoursPerWeek = hoursPerWeek
        self.annualReturn = annualReturn
        self.inflation = inflation
        self.years = years
    }

    /// A saved profile missing a field (one saved by an older app) takes the default for it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EarningsProfile()
        payType = try c.decodeIfPresent(PayType.self, forKey: .payType) ?? d.payType
        grossPay = try c.decodeIfPresent(Decimal.self, forKey: .grossPay)
        takeHomeMonthly = try c.decodeIfPresent(Decimal.self, forKey: .takeHomeMonthly)
        hoursPerWeek = try c.decodeIfPresent(Double.self, forKey: .hoursPerWeek) ?? d.hoursPerWeek
        annualReturn = try c.decodeIfPresent(Double.self, forKey: .annualReturn) ?? d.annualReturn
        inflation = try c.decodeIfPresent(Double.self, forKey: .inflation) ?? d.inflation
        years = try c.decodeIfPresent(Int.self, forKey: .years) ?? d.years
    }

    /// Growth after inflation: (1 + return) ÷ (1 + inflation) − 1. 8% less 3% is about 4.9%.
    public var realReturn: Double { (1 + annualReturn) / (1 + inflation) - 1 }
}

/// Take-home as the ledger shows it.
public enum TakeHome {
    /// A typical month of income: the median of the months that had any (the mean of the middle two for an even
    /// count), so a bonus, a tax refund or a month with a third biweekly paycheck doesn't pass for pay. Nil when no
    /// month had any.
    public static func typicalMonth(_ totals: [Money]) -> Money? {
        let sorted = totals.map(\.minorUnits).filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return Money(minorUnits: sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle])
    }
}

/// An hour of work before and after tax, and where each figure came from.
public struct WorkRate: Hashable, Sendable {
    public var grossHourly: Money
    public var takeHomeHourly: Money
    public var hoursPerWeek: Double
    public var grossYearly: Money
    public var takeHomeMonthly: Money
    /// Gross pay came from the tax estimate, not from the person.
    public var grossIsEstimated: Bool
    /// Take-home came from the tax estimate: no paychecks to go on (or none that fit the pay) and none typed.
    public var takeHomeIsEstimated: Bool
    /// Hours a week came from the paychecks (hourly pay with a wage given), not from the person.
    public var hoursAreInferred: Bool
    /// The Income category's month, left aside: with pay typed, it came to more than that pay could leave after tax —
    /// a second income, most likely — so take-home is estimated from the pay instead. Nil when the paychecks are used.
    public var incomeNotUsed: Money?

    /// The share of gross pay that never reaches the account: taxes, and whatever else comes out before payday
    /// (401(k), insurance).
    public var withheldShare: Double {
        guard grossYearly.minorUnits > 0 else { return 0 }
        return max(0, 1 - Double(takeHomeMonthly.minorUnits * 12) / Double(grossYearly.minorUnits))
    }

    /// Hours in a workday: a fifth of the week.
    public var hoursPerDay: Double { hoursPerWeek / 5 }

    /// How far paychecks may run over the federal-and-FICA estimate of the pay's take-home and still be this pay (state
    /// tax, 401(k) and benefits only ever bring it lower).
    static let paycheckSlack = 1.1
    /// Hours a week the paychecks can plausibly pay for at an hourly wage.
    static let plausibleHours = 10.0...70.0

    /// Works the rate out from the profile and the paychecks' monthly figure (nil when there are none). Nil when there's
    /// nothing to go on: no paychecks, no take-home typed and no gross pay.
    public init?(profile: EarningsProfile, paychecksMonthly: Money?) {
        let typed = profile.takeHomeMonthly.flatMap { $0 > 0 ? Double(Money($0).minorUnits) / 100 * 12 : nil }
        let paychecks = paychecksMonthly.flatMap { $0.minorUnits > 0 ? Double($0.minorUnits) / 100 * 12 : nil }
        let gross = profile.grossPay.flatMap { $0 > 0 ? NSDecimalNumber(decimal: $0).doubleValue : nil }
        var hours = min(max(profile.hoursPerWeek, 1), 100)
        var grossYearly: Double
        var takeHomeYearly: Double
        var grossEstimated = false, takeHomeEstimated = false, hoursInferred = false, setAside = false

        switch (profile.payType, gross) {
        case (.salary, let salary?):
            grossYearly = salary
            let estimate = PayrollTax.takeHome(grossYearly: salary)
            if let typed {
                takeHomeYearly = typed
            } else if let paychecks, paychecks <= estimate * Self.paycheckSlack {
                takeHomeYearly = paychecks
            } else {
                takeHomeYearly = estimate
                takeHomeEstimated = true
                setAside = paychecks != nil
            }
        case (.hourly, let wage?):
            // What take-home adds up to before tax, at this wage, is how many hours it pays for — when that's a working week.
            let known = typed ?? paychecks
            let inferred = known.map { PayrollTax.grossYearly(takeHomeYearly: $0) / (wage * 52) }
            if let known, let inferred, typed != nil || Self.plausibleHours.contains(inferred) {
                hours = min(max(inferred, 1), 100)
                hoursInferred = true
                takeHomeYearly = known
                grossYearly = wage * hours * 52
            } else {
                grossYearly = wage * hours * 52
                takeHomeYearly = PayrollTax.takeHome(grossYearly: grossYearly)
                takeHomeEstimated = true
                setAside = paychecks != nil
            }
        case (_, nil):
            guard let known = typed ?? paychecks else { return nil }
            takeHomeYearly = known
            grossYearly = PayrollTax.grossYearly(takeHomeYearly: known)
            grossEstimated = true
        }

        let yearlyHours = hours * 52
        self.grossHourly = Money(Decimal(grossYearly / yearlyHours))
        self.takeHomeHourly = Money(Decimal(takeHomeYearly / yearlyHours))
        self.hoursPerWeek = hours
        self.grossYearly = Money(Decimal(grossYearly))
        self.takeHomeMonthly = Money(Decimal(takeHomeYearly / 12))
        self.grossIsEstimated = grossEstimated
        self.takeHomeIsEstimated = takeHomeEstimated
        self.hoursAreInferred = hoursInferred
        self.incomeNotUsed = setAside ? paychecksMonthly : nil
    }
}

/// One price in hours of work, and in what it would have grown to.
public struct PriceCost: Hashable, Sendable {
    public var price: Money
    /// Hours at gross pay: the price over the wage on the offer letter.
    public var hoursBeforeTax: Double
    /// Hours at take-home: what it really takes, since the price is paid from money that's already been taxed.
    public var hoursAfterTax: Double
    /// The price invested instead for `years`, in today's dollars.
    public var grownValue: Money
    public var years: Int
    /// Take-home hours to earn what it would have grown to. With an everyday budget, `AfterNecessities.grownHours`
    /// puts it on the same footing as the necessities line instead.
    public var hoursForGrownValue: Double

    public init(price: Money, rate: WorkRate, profile: EarningsProfile) {
        let amount = price.doubleValue
        self.price = price
        hoursBeforeTax = Self.hours(amount, at: rate.grossHourly)
        hoursAfterTax = Self.hours(amount, at: rate.takeHomeHourly)
        years = max(profile.years, 0)
        let grown = amount * pow(1 + profile.realReturn, Double(years))
        grownValue = Money(Decimal(grown))
        hoursForGrownValue = Self.hours(grown, at: rate.takeHomeHourly)
    }

    private static func hours(_ amount: Double, at hourly: Money) -> Double {
        hourly.minorUnits > 0 ? amount / hourly.doubleValue : 0
    }

    /// The price against the everyday budget: what a month's take-home leaves after bills, subscriptions and saving
    /// first. $600 against a $500 everyday budget is 1.2 months of it, and so 1.2 months of work.
    public struct AfterNecessities: Hashable, Sendable {
        /// Months of the everyday budget the price takes (1.2 is a month and a fifth).
        public var months: Double
        /// Those months in hours of work, at `hoursPerWeek`.
        public var hours: Double
        /// Hours of work, on the same footing, to put by what the price would have grown to. Always more than `hours`
        /// when it grows, so invested instead never reads as cheaper than the line above it.
        public var grownHours: Double
    }

    /// Nil when nothing is left after necessities (an everyday budget of zero or less): no amount of work pays for it
    /// from what's spare.
    public func afterNecessities(everydayBudget: Money, hoursPerWeek: Double) -> AfterNecessities? {
        guard everydayBudget.minorUnits > 0, hoursPerWeek > 0 else { return nil }
        let hoursPerMonth = hoursPerWeek * 52 / 12
        let months = price.doubleValue / everydayBudget.doubleValue
        let grownMonths = grownValue.doubleValue / everydayBudget.doubleValue
        return AfterNecessities(months: months, hours: months * hoursPerMonth, grownHours: grownMonths * hoursPerMonth)
    }

    /// How the price sits against what's safe to spend this month.
    public enum BudgetFit: Hashable, Sendable {
        /// It fits: this share of what's left (0.42 is 42%).
        case within(share: Double, left: Money)
        /// It would take safe to spend below zero by this much.
        case over(by: Money)
        /// Safe to spend is already at or below zero, so it would come out of savings.
        case alreadyOver(Money)
    }

    public func fit(safeToSpend: Money) -> BudgetFit {
        guard safeToSpend.minorUnits > 0 else { return .alreadyOver(safeToSpend) }
        if price > safeToSpend { return .over(by: price - safeToSpend) }
        return .within(share: Double(price.minorUnits) / Double(safeToSpend.minorUnits), left: safeToSpend)
    }
}

/// Hours of work said the way people think about them: under a workday in hours ("45 min", "4.2 hours"), from a
/// workday in days ("1.5 days"), from a work week in weeks ("1.6 weeks"), with the hours alongside once it's days or
/// weeks. A workday is a fifth of the person's week: 8 hours at 40 a week.
public enum WorkTime {
    /// The headline and, once that's in days or weeks, the hours behind it.
    public static func describe(_ hours: Double, hoursPerWeek: Double) -> (headline: String, hours: String?) {
        guard hoursPerWeek > 0 else { return (Self.hours(hours), nil) }
        if hours >= hoursPerWeek { return (count(hours / hoursPerWeek, "week"), Self.hours(hours)) }
        if hours >= hoursPerWeek / 5 { return (count(hours / (hoursPerWeek / 5), "day"), Self.hours(hours)) }
        return (Self.hours(hours), nil)
    }

    public static func hours(_ hours: Double) -> String {
        if hours < 1 {
            let minutes = max(Int((hours * 60).rounded()), 1)
            return "\(minutes) min"
        }
        if hours < 10 { return count(hours, "hour") }
        return "\(Int(hours.rounded()).formatted()) hours"
    }

    /// "1 day", "1.5 days", "12 weeks": one decimal at most.
    private static func count(_ value: Double, _ unit: String) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == 1 ? "1 \(unit)" : "\(tenths.formatted(.number.precision(.fractionLength(0...1)))) \(unit)s"
    }
}
