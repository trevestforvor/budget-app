import Foundation
import Testing
@testable import BudgetKit

/// The opportunity-cost screen's arithmetic: pay into an hourly rate, a price into hours and growth given up, prices
/// read out of text.
struct OpportunityCostTests {
    private func d(_ text: String) -> Decimal { Decimal(string: text)! }
    private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

    // MARK: Payroll estimate

    @Test("$100k gross: 2026 federal tax for a single filer on $83,900 taxable is $13,170, FICA $7,650")
    func takeHomeOnHundredThousand() {
        #expect(near(PayrollTax.incomeTax(grossYearly: 100_000), 13_170))
        #expect(near(PayrollTax.fica(grossYearly: 100_000), 7_650))
        #expect(near(PayrollTax.takeHome(grossYearly: 100_000), 79_180))
    }

    @Test("Gross from take-home runs the estimate backwards, from part-time pay to past the Social Security wage base")
    func grossRoundTrips() {
        for gross in [12_000.0, 62_400, 100_000, 190_000, 250_000, 700_000] {
            #expect(near(PayrollTax.grossYearly(takeHomeYearly: PayrollTax.takeHome(grossYearly: gross)), gross, 0.5))
        }
        #expect(PayrollTax.grossYearly(takeHomeYearly: 0) == 0)
    }

    // MARK: Take-home

    @Test("A typical month is the median of the months with income: a March bonus doesn't pass for pay")
    func typicalMonth() {
        let months = ["6210.40", "9875.15", "7420.30", "24310.80", "7980.70", "6195.25"].map { Money(d($0)) }
        #expect(TakeHome.typicalMonth(months) == Money(d("7700.50")))
        #expect(TakeHome.typicalMonth([Money(3_000), .zero, Money(5_000), Money(4_000)]) == Money(4_000))
        #expect(TakeHome.typicalMonth([.zero]) == nil)
        #expect(TakeHome.typicalMonth([]) == nil)
    }

    // MARK: Hourly rate

    @Test("Salary typed in, paychecks in the ledger: gross over 2,080 hours, take-home from the paychecks")
    func salaryWithPaychecks() throws {
        let profile = EarningsProfile(payType: .salary, grossPay: 104_000)
        let rate = try #require(WorkRate(profile: profile, paychecksMonthly: Money(6_500)))
        #expect(rate.grossHourly == Money(50))
        #expect(rate.takeHomeHourly == Money(d("37.50")))
        #expect(near(rate.withheldShare, 0.25, 0.0001))
        #expect(!rate.grossIsEstimated && !rate.takeHomeIsEstimated && !rate.hoursAreInferred)
    }

    @Test("No salary typed: gross is estimated from the paychecks")
    func salaryEstimated() throws {
        let rate = try #require(WorkRate(profile: EarningsProfile(), paychecksMonthly: Money(d("6598.33"))))
        #expect(rate.grossIsEstimated)
        #expect(near(rate.grossHourly.doubleValue, 48.08))
        #expect(near(rate.takeHomeHourly.doubleValue, 38.07))
    }

    @Test("An hourly wage and paychecks say how many hours are worked; the typed hours give way")
    func hourlyInfersHours() throws {
        // $30 × 40 × 52 = $62,400 gross leaves $52,318.40 a year, $4,359.87 a month.
        let profile = EarningsProfile(payType: .hourly, grossPay: 30, hoursPerWeek: 25)
        let rate = try #require(WorkRate(profile: profile, paychecksMonthly: Money(d("4359.87"))))
        #expect(rate.hoursAreInferred)
        #expect(near(rate.hoursPerWeek, 40, 0.01))
        #expect(rate.grossHourly == Money(30))
        #expect(near(rate.takeHomeHourly.doubleValue, 25.15))
        #expect(!rate.grossIsEstimated)
    }

    @Test("A wage and no paychecks: the typed hours stand and take-home is estimated")
    func hourlyWithoutPaychecks() throws {
        let rate = try #require(WorkRate(profile: EarningsProfile(payType: .hourly, grossPay: 30, hoursPerWeek: 40), paychecksMonthly: nil))
        #expect(rate.takeHomeIsEstimated && !rate.hoursAreInferred)
        #expect(near(rate.takeHomeMonthly.doubleValue, 4_359.87))
    }

    @Test("Typed take-home wins over the paychecks; nothing at all is no rate")
    func takeHomeOverride() throws {
        let typed = EarningsProfile(payType: .salary, grossPay: 104_000, takeHomeMonthly: 7_000)
        let rate = try #require(WorkRate(profile: typed, paychecksMonthly: Money(6_500)))
        #expect(rate.takeHomeMonthly == Money(7_000))
        #expect(WorkRate(profile: EarningsProfile(), paychecksMonthly: nil) == nil)
        #expect(WorkRate(profile: EarningsProfile(), paychecksMonthly: .zero) == nil)
    }

    @Test("Income worth more than the typed pay could leave after tax isn't this pay: take-home comes from the pay")
    func incomeAboveSalary() throws {
        // $11,500 a month of Income against a $100,000 salary, which leaves about $6,598 after federal tax and FICA.
        let rate = try #require(WorkRate(profile: EarningsProfile(payType: .salary, grossPay: 100_000), paychecksMonthly: Money(11_500)))
        #expect(rate.grossHourly == Money(d("48.08")))
        #expect(near(rate.takeHomeMonthly.doubleValue, 6_598.33))
        #expect(rate.takeHomeIsEstimated && rate.incomeNotUsed == Money(11_500))
        #expect(rate.takeHomeHourly < rate.grossHourly && rate.withheldShare > 0.2)
        // Typed take-home is the person's word, even so.
        let typed = try #require(WorkRate(profile: EarningsProfile(payType: .salary, grossPay: 100_000, takeHomeMonthly: 6_200), paychecksMonthly: Money(11_500)))
        #expect(typed.takeHomeMonthly == Money(6_200) && typed.incomeNotUsed == nil)
        // An hourly wage the paychecks would need 190 hours a week to earn: the typed hours stand.
        let hourly = try #require(WorkRate(profile: EarningsProfile(payType: .hourly, grossPay: 20, hoursPerWeek: 40), paychecksMonthly: Money(11_500)))
        #expect(!hourly.hoursAreInferred && hourly.hoursPerWeek == 40 && hourly.grossHourly == Money(20) && hourly.incomeNotUsed == Money(11_500))
    }

    @Test("A profile saved before a field existed decodes with that field's default")
    func decodesOlderProfile() throws {
        let saved = Data(#"{"payType":"hourly","grossPay":31.5}"#.utf8)
        let profile = try JSONDecoder().decode(EarningsProfile.self, from: saved)
        #expect(profile.payType == .hourly && profile.grossPay == d("31.5"))
        #expect(profile.years == 10 && profile.annualReturn == 0.08 && profile.hoursPerWeek == 40)
    }

    // MARK: A price

    @Test("$500 at $50 gross and $37.50 take-home: 10 hours before tax, 13.3 after, about $803 in ten years in today's dollars")
    func priceCost() throws {
        let profile = EarningsProfile(payType: .salary, grossPay: 104_000)
        let rate = try #require(WorkRate(profile: profile, paychecksMonthly: Money(6_500)))
        let cost = PriceCost(price: Money(500), rate: rate, profile: profile)
        #expect(near(cost.hoursBeforeTax, 10))
        #expect(near(cost.hoursAfterTax, 13.33))
        // 8% less 3% inflation is 4.85% a year: 500 × 1.0485^10.
        #expect(near(cost.grownValue.doubleValue, 803.24, 0.5))
        #expect(near(cost.hoursForGrownValue, cost.grownValue.doubleValue / 37.5, 0.01))

        var nominal = profile
        nominal.inflation = 0
        #expect(PriceCost(price: Money(500), rate: rate, profile: nominal).grownValue == Money(d("1079.46")))
    }

    @Test("Against safe to spend: a share of what's left, how far past it, or already past")
    func budgetFit() throws {
        let rate = try #require(WorkRate(profile: EarningsProfile(grossPay: 104_000), paychecksMonthly: Money(6_500)))
        let cost = PriceCost(price: Money(500), rate: rate, profile: EarningsProfile())
        #expect(cost.fit(safeToSpend: Money(1_000)) == .within(share: 0.5, left: Money(1_000)))
        #expect(cost.fit(safeToSpend: Money(300)) == .over(by: Money(200)))
        #expect(cost.fit(safeToSpend: Money(d("-246.40"))) == .alreadyOver(Money(d("-246.40"))))
        #expect(cost.fit(safeToSpend: .zero) == .alreadyOver(.zero))
    }

    @Test("After necessities: $600 against a $500 everyday budget is 1.2 months of it, 208 hours at 40 a week; nothing left, no line")
    func afterNecessities() throws {
        let rate = try #require(WorkRate(profile: EarningsProfile(grossPay: 104_000), paychecksMonthly: Money(6_500)))
        let cost = PriceCost(price: Money(600), rate: rate, profile: EarningsProfile())
        let after = try #require(cost.afterNecessities(everydayBudget: Money(500), hoursPerWeek: 40))
        #expect(near(after.months, 1.2))
        #expect(near(after.hours, 208)) // 1.2 × 40 × 52 / 12
        #expect(WorkTime.describe(after.hours, hoursPerWeek: 40).headline == "5.2 weeks")
        #expect(cost.afterNecessities(everydayBudget: .zero, hoursPerWeek: 40) == nil)
        #expect(cost.afterNecessities(everydayBudget: Money(-120), hoursPerWeek: 40) == nil)
        // It always takes longer than after tax alone, since the budget is take-home less bills and saving.
        let roomy = try #require(cost.afterNecessities(everydayBudget: Money(4_000), hoursPerWeek: 40))
        #expect(roomy.hours > cost.hoursAfterTax)
    }

    @Test("Invested instead on the necessities footing: what it'd grow to over the everyday budget, so never less than the line above")
    func grownAfterNecessities() throws {
        let rate = try #require(WorkRate(profile: EarningsProfile(grossPay: 104_000), paychecksMonthly: Money(6_500)))
        let cost = PriceCost(price: Money(600), rate: rate, profile: EarningsProfile())
        let after = try #require(cost.afterNecessities(everydayBudget: Money(500), hoursPerWeek: 40))
        #expect(near(after.grownHours, cost.grownValue.doubleValue / 500 * 40 * 52 / 12, 0.01))
        #expect(after.grownHours > after.hours)
        // Take-home alone reads cheaper than the necessities line: the ladder broke there (8.8 weeks, then 6.5).
        #expect(cost.hoursForGrownValue < after.hours)

        var flat = EarningsProfile()
        flat.years = 0
        let now = try #require(PriceCost(price: Money(600), rate: rate, profile: flat).afterNecessities(everydayBudget: Money(500), hoursPerWeek: 40))
        #expect(near(now.grownHours, now.hours))
    }

    @Test("Work time reads in hours, then days from a workday, then weeks from a work week")
    func workTime() {
        #expect(WorkTime.hours(0.5) == "30 min")
        #expect(WorkTime.hours(0.001) == "1 min")
        #expect(WorkTime.hours(1) == "1 hour")
        #expect(WorkTime.hours(4.23) == "4.2 hours")
        #expect(WorkTime.hours(62.4) == "62 hours")
        // Hours under a workday; days from 8 hours; weeks from 40 — each with the hours alongside.
        #expect(WorkTime.describe(4.23, hoursPerWeek: 40) == ("4.2 hours", nil))
        #expect(WorkTime.describe(8, hoursPerWeek: 40) == ("1 day", "8 hours"))
        #expect(WorkTime.describe(12, hoursPerWeek: 40) == ("1.5 days", "12 hours"))
        #expect(WorkTime.describe(39, hoursPerWeek: 40) == ("4.9 days", "39 hours"))
        #expect(WorkTime.describe(40, hoursPerWeek: 40) == ("1 week", "40 hours"))
        #expect(WorkTime.describe(62.4, hoursPerWeek: 40) == ("1.6 weeks", "62 hours"))
        #expect(WorkTime.describe(400, hoursPerWeek: 40) == ("10 weeks", "400 hours"))
        // A longer week makes a longer workday: 10 hours at 50 a week is one day.
        #expect(WorkTime.describe(10, hoursPerWeek: 50) == ("1 day", "10 hours"))
    }

    // MARK: Reading prices

    @Test("Prices in text: a dollar sign or cents marks one; SKUs, quantities and longer numbers don't count")
    func amounts() {
        #expect(PriceText.amounts(in: "$1,299.99") == [d("1299.99")])
        #expect(PriceText.amounts(in: "Now $14.99 was $19.99") == [d("14.99"), d("19.99")])
        #expect(PriceText.amounts(in: "$ 5") == [5])
        #expect(PriceText.amounts(in: "12.99") == [d("12.99")])
        #expect(PriceText.amounts(in: "$3.49/lb") == [d("3.49")])
        #expect(PriceText.amounts(in: "SKU 12345 · 12 oz · 1,299").isEmpty)
        #expect(PriceText.amounts(in: "3.14159").isEmpty)
        #expect(PriceText.amounts(in: "$0.00").isEmpty)
    }

    @Test("The biggest printed price leads, then the rest in reading order, each once")
    func ranked() {
        let lines: [(text: String, height: Double)] = [
            ("$3.49/oz", 10), ("$24.99", 40), ("was $29.99", 12), ("Free shipping over $35", 12), ("$24.99", 20),
        ]
        #expect(PriceText.ranked(lines) == [d("24.99"), d("29.99"), 35, d("3.49")])
    }
}
