import Foundation

/// A schema-tolerant JSON tree. TeamClaude adds fields between releases, so the
/// parser reads what it needs and ignores the rest instead of failing a decode.
public enum JSONValue: Decodable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var double: Double? {
        if case .number(let number) = self, number.isFinite { return number }
        return nil
    }

    public var int: Int? { double.map { Int($0) } }

    public var string: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A short human description of a value whose type varies between releases
    /// (for example `unavailable`, which may be a string or an object).
    public var text: String? {
        switch self {
        case .null: return nil
        case .bool(let value): return value ? "yes" : nil
        case .number(let value): return String(value)
        case .string(let value): return value.isEmpty ? nil : value
        case .array(let values): return values.compactMap(\.text).joined(separator: ", ").nilIfEmpty
        case .object(let object):
            for key in ["reason", "message", "kind", "type"] {
                if let text = object[key]?.text { return text }
            }
            return nil
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Epoch milliseconds or an ISO 8601 string, as TeamClaude mixes both.
func date(fromMillis value: JSONValue?) -> Date? {
    if let millis = value?.double, millis > 0 { return Date(timeIntervalSince1970: millis / 1000) }
    if let text = value?.string { return isoDate(text) }
    return nil
}

func isoDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}
