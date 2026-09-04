import Foundation

// MARK: - The protocol's JSON value

/// A closed representation of a JSON value, `Sendable` and `Codable`.
///
/// WHY NOT `[String: Any]`: requests arrive from a network connection and leave towards the
/// `@MainActor`. Under Swift 6, `Any` is not `Sendable` — every border crossing would have
/// needed an `@unchecked` or an unchecked copy. A closed enum settles the question once and
/// for all, and throws in typed accessors for the command adapters.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// A shorthand for integers, by far the most common thing in the responses (lanes,
    /// counters, durations in ms).
    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }

    /// An optional string → `null` when it is absent. Written once here rather than as
    /// `optional.map { .string($0) } ?? .null` at every site, a form where inference of `map`'s
    /// generic type is fragile. A name distinct from the `string(_:)` case so that no overload
    /// turns on a label alone.
    static func stringOrNull(_ value: String?) -> JSONValue {
        guard let value else { return .null }
        return .string(value)
    }
}

// MARK: - Codable

extension JSONValue: Codable {

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // The order matters: `Bool` BEFORE `Double`. JSONDecoder does refuse to read `true` as a
        // Double and `1` as a Bool, but the other order would make correctness depend on an
        // implementation detail of Foundation.
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let b):   try c.encode(b)
        case .string(let s): try c.encode(s)
        case .array(let a):  try c.encode(a)
        case .object(let o): try c.encode(o)
        case .number(let d):
            // A whole number re-encodes as an integer: a Python client reading `lane` wants `2`,
            // not `2.0` (and `range(2.0)` raises). The threshold is 2^53, beyond which a Double no
            // longer represents integers exactly — we then return the Double as it is.
            if d.isFinite, d.rounded() == d, abs(d) < 9_007_199_254_740_992 {
                try c.encode(Int(d))
            } else {
                try c.encode(d)
            }
        }
    }
}

// MARK: - Literals (writing comfort for the adapters)

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .number(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

// MARK: - Reading

extension JSONValue {
    var stringValue: String?  { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double?  { if case .number(let d) = self { return d }; return nil }
    var boolValue: Bool?      { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// A strict integer: refuses `2.5` (a fractional lane is a call error, not a rounding to
    /// be done in silence).
    var intValue: Int? {
        guard case .number(let d) = self, d.isFinite, d.rounded() == d else { return nil }
        return Int(d)
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// The type's name as it appears in `bad_params` error messages.
    var typeName: String {
        switch self {
        case .null:   return "null"
        case .bool:   return "bool"
        case .number: return "number"
        case .string: return "string"
        case .array:  return "array"
        case .object: return "object"
        }
    }
}

// MARK: - Line-by-line serialisation

extension JSONValue {

    /// Encodes on a SINGLE line (the protocol is JSON-lines: one message = one line).
    /// `withoutEscapingSlashes` keeps file paths readable in the logs.
    func encodedLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(line: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: line)
    }
}
