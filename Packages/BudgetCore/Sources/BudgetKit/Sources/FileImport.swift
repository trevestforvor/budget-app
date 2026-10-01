import Foundation

/// Statement files: the intent's "OFX / QFX / CSV import — always supported", for history older
/// than an aggregator's window and for institutions no aggregator covers.
public enum FileImport {
    public enum Format: String, Codable, Sendable, CaseIterable { case auto, csv, ofx }

    /// How the file signs money. Banks export money-out as negative; Amex exports charges as positive.
    public enum SignConvention: String, Codable, Sendable { case auto, negativeIsOut, positiveIsOut }

    public struct Options: Codable, Sendable {
        public var format: Format
        public var sign: SignConvention
        /// Account kind of the destination, used by `.auto` sign detection.
        public var accountKind: AccountKind?
        public var institution: String
        /// CSV only (a CSV names no account): file the rows into an account of this name, created on
        /// first import and reused after. Without it the caller must name an existing account.
        public var accountName: String?
        /// CSV only: the account's balance today, so balances are real rather than relative.
        public var balance: Money?

        public init(format: Format = .auto, sign: SignConvention = .auto, accountKind: AccountKind? = nil, institution: String = "Import",
                    accountName: String? = nil, balance: Money? = nil) {
            self.format = format
            self.sign = sign
            self.accountKind = accountKind
            self.institution = institution
            self.accountName = accountName
            self.balance = balance
        }
    }

    public struct ParseError: LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static func parse(_ text: String, options: Options = Options()) throws -> SourceSnapshot {
        let format = options.format == .auto ? (text.range(of: "<OFX>", options: .caseInsensitive) != nil || text.contains("OFXHEADER") ? .ofx : .csv) : options.format
        switch format {
        case .ofx: return try OFX.parse(text, institution: options.institution)
        default: return try CSV.parse(text, options: options)
        }
    }

    /// Stable id for a file row, so re-importing the same file dedupes by id.
    static func rowID(_ date: Date, _ amount: Money, _ description: String, occurrence: Int) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in "\(Int(date.timeIntervalSince1970))|\(amount.minorUnits)|\(description)|\(occurrence)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 09/25/2026, 9/5/26, 2026-09-25, 20260925[…OFX time].
    static func date(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let m = s.firstMatch(of: /^(\d{4})-(\d{2})-(\d{2})/) { return day(Int(m.1)!, Int(m.2)!, Int(m.3)!) }
        if let m = s.firstMatch(of: /^(\d{4})(\d{2})(\d{2})/) { return day(Int(m.1)!, Int(m.2)!, Int(m.3)!) }
        if let m = s.wholeMatch(of: /(\d{1,2})\/(\d{1,2})\/(\d{2,4})/) {
            var year = Int(m.3)!
            if year < 100 { year += 2000 }
            return day(year, Int(m.1)!, Int(m.2)!)
        }
        return nil
    }

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        let components = DateComponents(calendar: utc, year: y, month: m, day: d, hour: 12)
        return components.isValidDate ? utc.date(from: components) : nil
    }

    /// "$1,234.56", "(12.00)", "-12.00", "1234.5" → minor units.
    static func amount(_ raw: String) -> Int64? {
        var s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("-") { negative.toggle(); s.removeFirst() }
        if s.hasPrefix("+") { s.removeFirst() }
        guard !s.isEmpty, let value = DecimalAmount(string: s) else { return nil }
        return negative ? -value.minorUnits : value.minorUnits
    }
}

// MARK: - CSV

enum CSV {
    /// RFC 4180-ish: quoted fields, doubled quotes, CRLF.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], field = "", row: [String] = [], quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    static func parse(_ text: String, options: FileImport.Options) throws -> SourceSnapshot {
        let table = rows(text)
        guard let header = table.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }), table.count > 1 else {
            throw FileImport.ParseError(message: "The CSV has no rows.")
        }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let dateCol = column(["posting date", "post date", "date", "transaction date", "posted date"]),
              let descCol = column(["description", "payee", "name", "merchant", "details description"]) else {
            throw FileImport.ParseError(message: "Couldn't find date and description columns (found: \(header.joined(separator: ", "))).")
        }
        let amountCol = column(["amount", "transaction amount"])
        let debitCol = column(["debit", "withdrawal", "withdrawals"]), creditCol = column(["credit", "deposit", "deposits"])
        guard amountCol != nil || debitCol != nil || creditCol != nil else {
            throw FileImport.ParseError(message: "Couldn't find an amount column (or debit/credit columns).")
        }
        let categoryCol = column(["category"])
        // Amex prints a unique reference per transaction; Chase says what kind of row it is.
        let referenceCol = column(["reference"]), typeCol = column(["type"])
        let isAmex = header.contains("extended details") || header.contains("appears on your statement as")

        var parsed: [(Date, Int64, String, String?, String?)] = []
        for (index, row) in table.dropFirst().enumerated() {
            func cell(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            guard let date = FileImport.date(cell(dateCol)) else { continue }
            var minor: Int64
            if let amountCol, let value = FileImport.amount(cell(amountCol)) {
                minor = value
            } else {
                // Separate columns: debit is money out, credit is money in, whatever their printed sign.
                let debit = FileImport.amount(cell(debitCol)).map { -abs($0) } ?? 0
                let credit = FileImport.amount(cell(creditCol)).map { abs($0) } ?? 0
                guard debit != 0 || credit != 0 else { continue }
                minor = debit + credit
            }
            _ = index
            var category = categoryCol.map { cell($0).trimmingCharacters(in: .whitespaces) }
            // Chase leaves card payments uncategorized; their Type says what they are.
            if category?.isEmpty ?? true, let type = typeCol.map({ cell($0).trimmingCharacters(in: .whitespaces) }), ["payment", "fee"].contains(type.lowercased()) {
                category = type.lowercased() == "payment" ? "Payment" : "Fees & Adjustments"
            }
            let reference = referenceCol.map { cell($0).trimmingCharacters(in: CharacterSet(charactersIn: "' \"")) }
            parsed.append((date, minor, cell(descCol).trimmingCharacters(in: .whitespaces), category, reference?.isEmpty == false ? reference : nil))
        }
        guard !parsed.isEmpty else { throw FileImport.ParseError(message: "No rows had a readable date and amount.") }

        let flip: Bool
        switch options.sign {
        case .negativeIsOut: flip = false
        case .positiveIsOut: flip = true
        case .auto:
            // Separate debit/credit columns are already signed. A single amount column on a card
            // statement that's mostly positive (Amex) means charges are positive.
            // Amex's own export always prints charges positive — even a statement that's mostly credits.
            let positiveShare = Double(parsed.filter { $0.1 > 0 }.count) / Double(parsed.count)
            flip = amountCol != nil && (isAmex || (options.accountKind == .credit && positiveShare > 0.5))
        }

        var seen: [String: Int] = [:]
        let transactions = parsed.map { date, minor, description, category, reference -> SourceTransaction in
            let money = Money(minorUnits: flip ? -minor : minor)
            let base = "\(Int(date.timeIntervalSince1970))|\(money.minorUnits)|\(description)"
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            let id = reference.map { "ref-" + $0 } ?? "csv-" + FileImport.rowID(date, money, description, occurrence: occurrence)
            return SourceTransaction(externalID: id, posted: date,
                                     amount: money, description: description, providerCategory: category?.isEmpty == false ? category : nil)
        }
        let name = options.accountName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        // A named account gets a stable id from institution + name, so the next statement lands in it too.
        let externalID = name.map { "csv-" + "\(options.institution) \($0)".lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-") } ?? "file"
        let account = SourceAccount(externalID: externalID, institution: options.institution, institutionDomain: nil, name: name ?? "Imported file",
                                    kind: options.accountKind ?? .checking, balance: options.balance ?? .zero, availableBalance: nil, balanceDate: .now,
                                    transactions: transactions, holdings: [])
        return SourceSnapshot(source: .fileImport, accounts: [account], warnings: flip ? ["Amounts were positive for charges; flipped so money out is negative."] : [])
    }
}

// MARK: - OFX / QFX

enum OFX {
    /// Handles both SGML (OFX 1.x, unclosed tags) and XML (OFX 2.x).
    static func value(_ tag: String, in block: Substring) -> String? {
        guard let start = block.range(of: "<\(tag)>", options: .caseInsensitive) else { return nil }
        let rest = block[start.upperBound...]
        let end = rest.firstIndex(where: { $0 == "<" || $0 == "\n" || $0 == "\r" }) ?? rest.endIndex
        let v = rest[..<end].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    static func blocks(_ tag: String, in text: String) -> [Substring] {
        var out: [Substring] = []
        var search = text.startIndex..<text.endIndex
        while let open = text.range(of: "<\(tag)>", options: .caseInsensitive, range: search) {
            let after = open.upperBound..<text.endIndex
            let close = text.range(of: "</\(tag)>", options: .caseInsensitive, range: after)
            let next = text.range(of: "<\(tag)>", options: .caseInsensitive, range: after)
            let end = [close?.lowerBound, next?.lowerBound, text.range(of: "</BANKTRANLIST>", options: .caseInsensitive, range: after)?.lowerBound]
                .compactMap { $0 }.min() ?? text.endIndex
            out.append(text[open.upperBound..<end])
            search = (close?.upperBound ?? end)..<text.endIndex
        }
        return out
    }

    /// OFX TRNTYPE as a readable description, for rows that have nothing else.
    static func typeName(_ type: String?, _ amount: Money) -> String {
        switch type {
        case "INT": "Interest"
        case "DIV": "Dividend"
        case "XFER": "Transfer"
        case "DIRECTDEP": "Direct deposit"
        case "DIRECTDEBIT": "Direct debit"
        case "ATM": "ATM"
        case "CHECK": "Check"
        case "FEE", "SRVCHG": "Fee"
        case "PAYMENT": "Payment"
        default: amount.isNegative ? "Withdrawal" : "Deposit"
        }
    }

    /// The categories an OFX type settles on its own (Plaid-style names, so the usual mapping applies).
    static func typeCategory(_ type: String?, _ amount: Money) -> String? {
        switch type {
        case "INT", "DIV": "INCOME_INTEREST_EARNED"
        case "DIRECTDEP": "INCOME_WAGES"
        case "XFER": amount.isNegative ? "TRANSFER_OUT" : "TRANSFER_IN"
        case "FEE", "SRVCHG": "BANK_FEES"
        default: nil
        }
    }

    static func parse(_ text: String, institution: String) throws -> SourceSnapshot {
        let rows = blocks("STMTTRN", in: text)
        guard !rows.isEmpty else { throw FileImport.ParseError(message: "No <STMTTRN> transactions in the OFX file.") }
        let whole = Substring(text)
        let accountID = value("ACCTID", in: whole) ?? "ofx"
        let isCard = text.range(of: "<CCSTMTRS>", options: .caseInsensitive) != nil
        let org = value("ORG", in: whole) ?? institution
        // The statement's currency, so ingest can set aside one that isn't the ledger's.
        let currency = value("CURDEF", in: whole)?.trimmingCharacters(in: .whitespaces).uppercased().nonEmpty ?? "USD"
        let transactions = rows.compactMap { block -> SourceTransaction? in
            guard let dateText = value("DTPOSTED", in: block), let date = FileImport.date(dateText),
                  let amountText = value("TRNAMT", in: block), let minor = FileImport.amount(amountText) else { return nil }
            let money = Money(minorUnits: minor, currencyCode: currency) // OFX amounts are signed from the account holder's view
            let type = value("TRNTYPE", in: block)?.uppercased()
            // Some exports (a brokerage's QFX) carry no NAME or MEMO at all; the type is the only description.
            let name = value("NAME", in: block) ?? value("MEMO", in: block) ?? typeName(type, money)
            let id = value("FITID", in: block) ?? FileImport.rowID(date, money, name, occurrence: 0)
            return SourceTransaction(externalID: "ofx-\(accountID)-\(id)", posted: date, amount: money, description: name,
                                     payee: nil, isPending: false, providerCategory: typeCategory(type, money))
        }
        var balance = Money(minorUnits: 0, currencyCode: currency)
        if let ledger = blocks("LEDGERBAL", in: text).first, let amountText = value("BALAMT", in: ledger), let minor = FileImport.amount(amountText) {
            balance = Money(minorUnits: minor, currencyCode: currency)
        }
        let masked = accountID.count > 4 ? "••" + accountID.suffix(4) : accountID
        let account = SourceAccount(externalID: accountID, institution: org, institutionDomain: nil,
                                    name: isCard ? "Card \(masked)" : "Account \(masked)", kind: isCard ? .credit : .checking,
                                    balance: balance, availableBalance: nil, balanceDate: .now, transactions: transactions, holdings: [])
        return SourceSnapshot(source: .fileImport, accounts: [account], warnings: [])
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
