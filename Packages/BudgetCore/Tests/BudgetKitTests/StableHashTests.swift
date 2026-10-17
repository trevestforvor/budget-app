@testable import BudgetKit
import Foundation
import Testing

@Suite("Stable hash")
struct StableHashTests {
    @Test("File rows keep the ids they had before the hash moved, so a re-imported statement still dedupes")
    func fileImportRowIDUnchanged() {
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(FileImport.rowID(d, Money(Decimal(string: "-12.34")!), "BLUE BOTTLE COFFEE", occurrence: 0) == "b28c6b2769e43871")
        #expect(FileImport.rowID(d.addingTimeInterval(86_400), Money(Decimal(string: "2500")!), "PAYROLL ACME", occurrence: 1) == "75588685851ebb")
        #expect(FileImport.rowID(Date(timeIntervalSince1970: 0), Money(0), "", occurrence: 0) == "13813954147d1951")
    }

    @Test("The helpers: plain FNV-1a, a padded short form and a 128-bit form from two seeds")
    func helpers() {
        #expect(StableHash.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(StableHash.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)  // the published FNV-1a 64 test vector
        #expect(StableHash.short("a").count == 12 && StableHash.short("a") == "dc4c8601ec8c")
        let wide = StableHash.hex128("a")
        #expect(wide.count == 32 && wide.hasSuffix("af63dc4c8601ec8c") && wide != StableHash.hex128("b"))
        #expect(StableHash.hex128("a") == wide)
    }
}
