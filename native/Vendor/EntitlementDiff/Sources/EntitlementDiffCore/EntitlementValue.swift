import Foundation

/// A typed property-list value. Numeric widths are not entitlement semantics;
/// integers and reals are distinct, and integers larger than Int64 are retained.
public indirect enum EntitlementValue: Sendable, Equatable {
    case boolean(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case real(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case array([EntitlementValue])
    case dictionary(EntitlementDictionary)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.boolean(a), .boolean(b)): a == b
        case let (.integer(a), .integer(b)): a == b
        case let (.unsignedInteger(a), .unsignedInteger(b)): a == b
        case let (.integer(a), .unsignedInteger(b)), let (.unsignedInteger(b), .integer(a)):
            a >= 0 && UInt64(a) == b
        case let (.real(a), .real(b)): a.bitPattern == b.bitPattern
        case let (.string(a), .string(b)): a.utf8.elementsEqual(b.utf8)
        case let (.data(a), .data(b)): a == b
        case let (.date(a), .date(b)):
            a.timeIntervalSinceReferenceDate.bitPattern == b.timeIntervalSinceReferenceDate.bitPattern
        case let (.array(a), .array(b)): a == b
        case let (.dictionary(a), .dictionary(b)): a == b
        default: false
        }
    }

    public var typeName: String {
        switch self {
        case .boolean: "Boolean"
        case .integer, .unsignedInteger: "Integer"
        case .real: "Real"
        case .string: "String"
        case .data: "Data"
        case .date: "Date"
        case .array: "Array"
        case .dictionary: "Dictionary"
        }
    }
}

public struct EntitlementEntry: Sendable, Equatable, Encodable {
    public let key: String
    public let value: EntitlementValue

    public init(key: String, value: EntitlementValue) {
        self.key = key
        self.value = value
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value == rhs.value
    }
}

/// Sorted entries avoid Swift Dictionary's Unicode canonical-key equivalence.
/// Use init(entries:) when distinct Unicode spellings must survive construction.
public struct EntitlementDictionary: Sendable, Equatable, Encodable {
    public let entries: [EntitlementEntry]

    public init(_ values: [String: EntitlementValue] = [:]) {
        entries = values.map { EntitlementEntry(key: $0.key, value: $0.value) }
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }

    public init(entries: [EntitlementEntry]) throws {
        let sorted = entries.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        for index in sorted.indices.dropFirst() {
            if sorted[index - 1].key.utf8.elementsEqual(sorted[index].key.utf8) {
                throw EntitlementDataError.duplicateKey(sorted[index].key)
            }
        }
        self.entries = sorted
    }

    public subscript(key: String) -> EntitlementValue? {
        entries.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for entry in entries { try container.encode(entry) }
    }
}

extension EntitlementValue: Encodable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .boolean(let value):
            try container.encode("boolean", forKey: .type)
            try container.encode(value, forKey: .value)
        case .integer(let value):
            try container.encode("integer", forKey: .type)
            try container.encode(String(value), forKey: .value)
        case .unsignedInteger(let value):
            try container.encode("integer", forKey: .type)
            try container.encode(String(value), forKey: .value)
        case .real(let value):
            try container.encode("real", forKey: .type)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode("string", forKey: .type)
            try container.encode(value, forKey: .value)
        case .data(let value):
            try container.encode("data-base64", forKey: .type)
            try container.encode(value.base64EncodedString(), forKey: .value)
        case .date(let value):
            try container.encode("date-reference-seconds", forKey: .type)
            try container.encode(value.timeIntervalSinceReferenceDate, forKey: .value)
        case .array(let value):
            try container.encode("array", forKey: .type)
            try container.encode(value, forKey: .value)
        case .dictionary(let value):
            try container.encode("dictionary", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}
