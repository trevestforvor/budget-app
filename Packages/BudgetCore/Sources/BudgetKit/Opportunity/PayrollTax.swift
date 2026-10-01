import Foundation

/// A rough US payroll estimate, used only when the person hasn't said what they earn before tax: 2026 federal income
/// tax for a single filer taking the standard deduction, plus Social Security and Medicare. No state tax, 401(k) or
/// benefits, so it runs a little low for most people; typing the real pay replaces it.
/// Figures: IRS Rev. Proc. 2025-32 and the SSA's 2026 wage base.
public enum PayrollTax {
    static let standardDeduction = 16_100.0
    /// Each bracket's top of taxable income and its rate.
    static let brackets: [(upTo: Double, rate: Double)] = [
        (12_400, 0.10), (50_400, 0.12), (105_700, 0.22), (201_775, 0.24), (256_225, 0.32), (640_600, 0.35), (.infinity, 0.37),
    ]
    static let socialSecurityRate = 0.062
    static let socialSecurityWageBase = 184_500.0
    static let medicareRate = 0.0145
    static let additionalMedicareRate = 0.009
    static let additionalMedicareFrom = 200_000.0

    /// Federal income tax on a year's wages.
    static func incomeTax(grossYearly: Double) -> Double {
        var taxable = max(grossYearly - standardDeduction, 0)
        var floor = 0.0, tax = 0.0
        for bracket in brackets where taxable > 0 {
            let slice = min(taxable, bracket.upTo - floor)
            tax += slice * bracket.rate
            taxable -= slice
            floor = bracket.upTo
        }
        return tax
    }

    /// Social Security and Medicare on a year's wages.
    static func fica(grossYearly: Double) -> Double {
        min(grossYearly, socialSecurityWageBase) * socialSecurityRate
            + grossYearly * medicareRate
            + max(grossYearly - additionalMedicareFrom, 0) * additionalMedicareRate
    }

    /// What a year's gross pay leaves after federal tax and FICA.
    public static func takeHome(grossYearly: Double) -> Double {
        guard grossYearly > 0 else { return 0 }
        return grossYearly - incomeTax(grossYearly: grossYearly) - fica(grossYearly: grossYearly)
    }

    /// The gross pay that leaves `takeHomeYearly` after federal tax and FICA — `takeHome` run backwards. Take-home
    /// rises with gross everywhere (no rate reaches 100%), so halving the interval finds it.
    public static func grossYearly(takeHomeYearly: Double) -> Double {
        guard takeHomeYearly > 0 else { return 0 }
        // The top combined rate is under 45%, so gross is under take-home ÷ 0.55.
        var low = takeHomeYearly, high = takeHomeYearly / 0.55 + standardDeduction
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if takeHome(grossYearly: mid) < takeHomeYearly { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}
