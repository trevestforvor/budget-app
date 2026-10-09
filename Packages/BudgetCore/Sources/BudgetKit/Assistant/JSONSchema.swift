import Foundation

/// Any JSON value. Used for tool arguments and for encoding schemas.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not JSON") }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }

    public func data(pretty: Bool = false) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

/// The subset of JSON Schema that OpenAI-compatible tool calling and constrained decoders
/// (llama.cpp grammars, vLLM/SGLang guided decoding) handle reliably: no oneOf/anyOf, no $ref.
public struct JSONSchema: Hashable, Sendable {
    public enum Kind: String, Sendable { case object, string, integer, number, boolean, array }

    public var kind: Kind
    public var description: String?
    public var properties: [String: JSONSchema] = [:]
    public var required: [String] = []
    public var minProperties: Int?
    public var items: [JSONSchema] = []
    public var enumValues: [String]?
    public var pattern: String?
    public var format: String?
    public var minLength: Int?
    public var maxLength: Int?
    public var minimum: Double?
    public var maximum: Double?
    public var minItems: Int?
    public var maxItems: Int?

    public init(kind: Kind, description: String? = nil) {
        self.kind = kind
        self.description = description
    }

    // MARK: Builders

    public static func object(_ description: String? = nil, _ properties: [String: JSONSchema], required: [String] = [], minProperties: Int? = nil) -> JSONSchema {
        var s = JSONSchema(kind: .object, description: description)
        s.properties = properties
        s.required = required
        s.minProperties = minProperties
        return s
    }

    /// This object schema without `names` among its properties (or required).
    public func removingProperties(_ names: Set<String>) -> JSONSchema {
        var s = self
        for name in names { s.properties[name] = nil }
        s.required.removeAll { names.contains($0) }
        return s
    }

    public static func string(_ description: String, enum values: [String]? = nil, pattern: String? = nil, format: String? = nil, minLength: Int? = nil, maxLength: Int? = nil) -> JSONSchema {
        var s = JSONSchema(kind: .string, description: description)
        s.enumValues = values
        s.pattern = pattern
        s.format = format
        s.minLength = minLength
        s.maxLength = maxLength
        return s
    }

    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONSchema {
        var s = JSONSchema(kind: .integer, description: description)
        s.minimum = minimum.map(Double.init)
        s.maximum = maximum.map(Double.init)
        return s
    }

    public static func boolean(_ description: String) -> JSONSchema { JSONSchema(kind: .boolean, description: description) }

    public static func array(_ description: String, of item: JSONSchema, minItems: Int? = nil, maxItems: Int? = nil) -> JSONSchema {
        var s = JSONSchema(kind: .array, description: description)
        s.items = [item]
        s.minItems = minItems
        s.maxItems = maxItems
        return s
    }

    // MARK: Encoding

    public var jsonValue: JSONValue {
        var o: [String: JSONValue] = ["type": .string(kind.rawValue)]
        if let description { o["description"] = .string(description) }
        if kind == .object {
            o["properties"] = .object(properties.mapValues(\.jsonValue))
            if !required.isEmpty { o["required"] = .array(required.sorted().map(JSONValue.string)) }
            o["additionalProperties"] = .bool(false)
            if let minProperties { o["minProperties"] = .number(Double(minProperties)) }
        }
        if let item = items.first { o["items"] = item.jsonValue }
        if let enumValues { o["enum"] = .array(enumValues.map(JSONValue.string)) }
        if let pattern { o["pattern"] = .string(pattern) }
        if let format { o["format"] = .string(format) }
        if let minLength { o["minLength"] = .number(Double(minLength)) }
        if let maxLength { o["maxLength"] = .number(Double(maxLength)) }
        if let minimum { o["minimum"] = .number(minimum) }
        if let maximum { o["maximum"] = .number(maximum) }
        if let minItems { o["minItems"] = .number(Double(minItems)) }
        if let maxItems { o["maxItems"] = .number(Double(maxItems)) }
        return .object(o)
    }

    /// Returns a copy where every property named `name` is transformed.
    func mapProperties(named name: String, _ transform: (JSONSchema) -> JSONSchema) -> JSONSchema {
        var copy = self
        copy.properties = Dictionary(uniqueKeysWithValues: properties.map { key, value in
            let inner = value.mapProperties(named: name, transform)
            return (key, key == name ? transform(inner) : inner)
        })
        copy.items = items.map { $0.mapProperties(named: name, transform) }
        return copy
    }

    // MARK: Validation

    /// Problems with `value` against this schema, as readable messages (empty when valid).
    /// Messages are written so they can be fed back to a model to repair its call.
    public func validate(_ value: JSONValue, at path: String = "$") -> [String] {
        var problems: [String] = []
        switch (kind, value) {
        case let (.object, .object(fields)):
            for key in required where fields[key] == nil { problems.append("\(path).\(key) is required") }
            for key in fields.keys.sorted() where properties[key] == nil { problems.append("\(path).\(key) is not an allowed field") }
            if let minProperties, fields.filter({ $0.value != .null }).count < minProperties {
                problems.append("\(path) needs at least \(minProperties) field\(minProperties == 1 ? "" : "s")")
            }
            for (key, field) in fields.sorted(by: { $0.key < $1.key }) {
                guard let schema = properties[key], field != .null || required.contains(key) else { continue }
                problems += schema.validate(field, at: "\(path).\(key)")
            }
        case let (.string, .string(s)):
            if let enumValues, !enumValues.contains(s) { problems.append("\(path) must be one of \(enumValues.joined(separator: ", ")); got \"\(s)\"") }
            if let pattern, let regex = try? Regex(pattern), s.wholeMatch(of: regex) == nil { problems.append("\(path) must match \(pattern); got \"\(s)\"") }
            if format == "date", !Self.isDate(s) { problems.append("\(path) must be a date like 2026-03-01; got \"\(s)\"") }
            if let minLength, s.count < minLength { problems.append("\(path) must be at least \(minLength) characters") }
            if let maxLength, s.count > maxLength { problems.append("\(path) must be at most \(maxLength) characters") }
        case let (.integer, .number(n)):
            if n.rounded() != n { problems.append("\(path) must be a whole number") }
            problems += rangeProblems(n, path)
        case let (.number, .number(n)):
            problems += rangeProblems(n, path)
        case (.boolean, .bool):
            break
        case let (.array, .array(elements)):
            if let minItems, elements.count < minItems { problems.append("\(path) needs at least \(minItems) item\(minItems == 1 ? "" : "s")") }
            if let maxItems, elements.count > maxItems { problems.append("\(path) allows at most \(maxItems) items") }
            if let item = items.first {
                for (i, element) in elements.enumerated() { problems += item.validate(element, at: "\(path)[\(i)]") }
            }
        default:
            problems.append("\(path) must be \(kind == .integer ? "an integer" : "a \(kind.rawValue)"); got \(value.typeName)")
        }
        return problems
    }

    private func rangeProblems(_ n: Double, _ path: String) -> [String] {
        var problems: [String] = []
        if let minimum, n < minimum { problems.append("\(path) must be ≥ \(minimum.formatted())") }
        if let maximum, n > maximum { problems.append("\(path) must be ≤ \(maximum.formatted())") }
        return problems
    }

    static func isDate(_ s: String) -> Bool {
        guard let m = s.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/), let y = Int(m.1), let mo = Int(m.2), let d = Int(m.3) else { return false }
        let components = DateComponents(calendar: Calendar(identifier: .gregorian), year: y, month: mo, day: d)
        return components.isValidDate
    }
}
