import Foundation

/// The restricted canonical value model (plan KTD1). Deliberately narrower
/// than JSON: no floats (timestamps and counters are `Int64`), ASCII-only
/// object keys, strings NFC-normalized at serialization. The emitted bytes
/// are the hashed, stored, synced representation — verification re-hashes
/// stored bytes and never re-serializes, so this serializer only has to be
/// deterministic with itself, and is additionally held to the RFC 8785
/// escaping/sorting rules within its subset.
public indirect enum CanonicalValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([CanonicalValue])
    case object([String: CanonicalValue])
}

public enum CanonicalJSONError: Error, Equatable {
    case nonASCIIKey(String)
    case duplicateKey(String)
    case floatRejected
    case integerOverflow
    case malformed(String)
    case trailingGarbage
    case invalidEscape
    case loneSurrogate
    case unterminatedString
    case depthExceeded
}

// MARK: - Serialization

extension CanonicalValue {
    /// Deterministic canonical bytes: sorted ASCII keys, RFC 8785 escaping,
    /// NFC-normalized strings, no insignificant whitespace.
    public func serialized() throws -> Data {
        var out = [UInt8]()
        try serialize(into: &out)
        return Data(out)
    }

    private func serialize(into out: inout [UInt8]) throws {
        switch self {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let b):
            out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let i):
            out.append(contentsOf: Array(String(i).utf8))
        case .string(let s):
            try Self.serializeString(s, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                try item.serialize(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let dict):
            out.append(UInt8(ascii: "{"))
            let keys = try dict.keys.map { key -> String in
                guard key.allSatisfy(\.isASCII) else { throw CanonicalJSONError.nonASCIIKey(key) }
                return key
            }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                try Self.serializeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                try dict[key]!.serialize(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func serializeString(_ s: String, into out: inout [UInt8]) throws {
        // NFC normalization is part of the permanent preimage: identical
        // visible text hashes identically regardless of the source's
        // composition form (APFS filenames arrive NFD).
        let normalized = s.precomposedStringWithCanonicalMapping
        out.append(UInt8(ascii: "\""))
        for scalar in normalized.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: Array("\\\"".utf8))
            case "\\": out.append(contentsOf: Array("\\\\".utf8))
            case "\u{08}": out.append(contentsOf: Array("\\b".utf8))
            case "\u{09}": out.append(contentsOf: Array("\\t".utf8))
            case "\u{0A}": out.append(contentsOf: Array("\\n".utf8))
            case "\u{0C}": out.append(contentsOf: Array("\\f".utf8))
            case "\u{0D}": out.append(contentsOf: Array("\\r".utf8))
            case let c where c.value < 0x20:
                let hex = String(format: "\\u%04x", c.value)
                out.append(contentsOf: Array(hex.utf8))
            default:
                // Non-ASCII is emitted as raw UTF-8, per RFC 8785.
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

// MARK: - Strict parsing

extension CanonicalValue {
    /// Strict parser for the canonical subset. Rejects floats, duplicate
    /// keys, non-ASCII keys, lone surrogates, and trailing bytes — stored
    /// payloads that fail this parse are corrupt by definition.
    public static func parse(_ data: Data) throws -> CanonicalValue {
        var parser = Parser(bytes: [UInt8](data))
        let value = try parser.parseValue(depth: 0)
        parser.skipNothing()
        guard parser.isAtEnd else { throw CanonicalJSONError.trailingGarbage }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        static let maxDepth = 64

        var isAtEnd: Bool { i >= bytes.count }

        mutating func skipNothing() {
            // Canonical form has no whitespace; tolerate none.
        }

        mutating func peek() throws -> UInt8 {
            guard i < bytes.count else { throw CanonicalJSONError.malformed("unexpected end") }
            return bytes[i]
        }

        mutating func parseValue(depth: Int) throws -> CanonicalValue {
            guard depth < Self.maxDepth else { throw CanonicalJSONError.depthExceeded }
            switch try peek() {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .int(try parseInt())
            case let b:
                throw CanonicalJSONError.malformed("unexpected byte 0x\(String(b, radix: 16))")
            }
        }

        mutating func expect(_ literal: String) throws {
            for c in literal.utf8 {
                guard i < bytes.count, bytes[i] == c else {
                    throw CanonicalJSONError.malformed("bad literal")
                }
                i += 1
            }
        }

        mutating func parseObject(depth: Int) throws -> CanonicalValue {
            i += 1 // {
            var dict = [String: CanonicalValue]()
            if try peek() == UInt8(ascii: "}") { i += 1; return .object(dict) }
            while true {
                let key = try parseString()
                guard key.allSatisfy(\.isASCII) else { throw CanonicalJSONError.nonASCIIKey(key) }
                guard dict[key] == nil else { throw CanonicalJSONError.duplicateKey(key) }
                guard try peek() == UInt8(ascii: ":") else { throw CanonicalJSONError.malformed("expected ':'") }
                i += 1
                dict[key] = try parseValue(depth: depth + 1)
                switch try peek() {
                case UInt8(ascii: ","): i += 1
                case UInt8(ascii: "}"): i += 1; return .object(dict)
                default: throw CanonicalJSONError.malformed("expected ',' or '}'")
                }
            }
        }

        mutating func parseArray(depth: Int) throws -> CanonicalValue {
            i += 1 // [
            var items = [CanonicalValue]()
            if try peek() == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(try parseValue(depth: depth + 1))
                switch try peek() {
                case UInt8(ascii: ","): i += 1
                case UInt8(ascii: "]"): i += 1; return .array(items)
                default: throw CanonicalJSONError.malformed("expected ',' or ']'")
                }
            }
        }

        mutating func parseInt() throws -> Int64 {
            let start = i
            if try peek() == UInt8(ascii: "-") { i += 1 }
            var digits = 0
            var leadingZero = false
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) {
                if digits == 0 && bytes[i] == UInt8(ascii: "0") { leadingZero = true }
                digits += 1
                i += 1
            }
            guard digits > 0 else { throw CanonicalJSONError.malformed("bare '-'") }
            if leadingZero && digits > 1 { throw CanonicalJSONError.malformed("leading zero") }
            if i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
                    throw CanonicalJSONError.floatRejected
                default: break
                }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard let value = Int64(text) else { throw CanonicalJSONError.integerOverflow }
            return value
        }

        mutating func parseString() throws -> String {
            guard try peek() == UInt8(ascii: "\"") else { throw CanonicalJSONError.malformed("expected string") }
            i += 1
            var scalars = String.UnicodeScalarView()
            while true {
                guard i < bytes.count else { throw CanonicalJSONError.unterminatedString }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    return String(scalars)
                }
                if b == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { throw CanonicalJSONError.invalidEscape }
                    switch bytes[i] {
                    case UInt8(ascii: "\""): scalars.append("\""); i += 1
                    case UInt8(ascii: "\\"): scalars.append("\\"); i += 1
                    case UInt8(ascii: "/"): scalars.append("/"); i += 1
                    case UInt8(ascii: "b"): scalars.append("\u{08}"); i += 1
                    case UInt8(ascii: "t"): scalars.append("\u{09}"); i += 1
                    case UInt8(ascii: "n"): scalars.append("\u{0A}"); i += 1
                    case UInt8(ascii: "f"): scalars.append("\u{0C}"); i += 1
                    case UInt8(ascii: "r"): scalars.append("\u{0D}"); i += 1
                    case UInt8(ascii: "u"):
                        i += 1
                        let unit = try parseHex4()
                        if (0xD800...0xDBFF).contains(unit) {
                            // High surrogate — require a low surrogate escape.
                            guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"),
                                  bytes[i + 1] == UInt8(ascii: "u") else {
                                throw CanonicalJSONError.loneSurrogate
                            }
                            i += 2
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else {
                                throw CanonicalJSONError.loneSurrogate
                            }
                            let combined = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                            guard let scalar = Unicode.Scalar(combined) else {
                                throw CanonicalJSONError.loneSurrogate
                            }
                            scalars.append(scalar)
                        } else if (0xDC00...0xDFFF).contains(unit) {
                            throw CanonicalJSONError.loneSurrogate
                        } else {
                            guard let scalar = Unicode.Scalar(UInt32(unit)) else {
                                throw CanonicalJSONError.invalidEscape
                            }
                            scalars.append(scalar)
                        }
                    default:
                        throw CanonicalJSONError.invalidEscape
                    }
                    continue
                }
                if b < 0x20 { throw CanonicalJSONError.malformed("unescaped control char") }
                // Decode one UTF-8 scalar.
                let len: Int
                switch b {
                case 0x00...0x7F: len = 1
                case 0xC2...0xDF: len = 2
                case 0xE0...0xEF: len = 3
                case 0xF0...0xF4: len = 4
                default: throw CanonicalJSONError.malformed("invalid UTF-8 lead byte")
                }
                guard i + len <= bytes.count else { throw CanonicalJSONError.malformed("truncated UTF-8") }
                let slice = Array(bytes[i..<(i + len)])
                var decoded = ""
                var decoder = UTF8()
                var iterator = slice.makeIterator()
                switch decoder.decode(&iterator) {
                case .scalarValue(let scalar): decoded.unicodeScalars.append(scalar)
                default: throw CanonicalJSONError.malformed("invalid UTF-8 sequence")
                }
                scalars.append(contentsOf: decoded.unicodeScalars)
                i += len
            }
        }

        mutating func parseHex4() throws -> UInt16 {
            guard i + 4 <= bytes.count else { throw CanonicalJSONError.invalidEscape }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let b = bytes[i]
                let digit: UInt16
                switch b {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(b - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(b - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(b - UInt8(ascii: "A") + 10)
                default: throw CanonicalJSONError.invalidEscape
                }
                value = value << 4 | digit
                i += 1
            }
            return value
        }
    }
}

// MARK: - Convenience accessors

extension CanonicalValue {
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [CanonicalValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: CanonicalValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public subscript(key: String) -> CanonicalValue? {
        objectValue?[key]
    }
}
