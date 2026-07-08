import Foundation
import Testing
@testable import FirmamentKit

@Suite("CanonicalJSON")
struct CanonicalJSONTests {
    private func bytes(_ value: CanonicalValue) throws -> String {
        String(decoding: try value.serialized(), as: UTF8.self)
    }

    @Test("keys sort by UTF-16 code unit, not locale")
    func keySorting() throws {
        let value = CanonicalValue.object([
            "b": .int(2), "a": .int(1), "Z": .int(0), "_x": .int(3),
        ])
        // ASCII byte order: 'Z' (0x5A) < '_' (0x5F) < 'a' (0x61) < 'b' (0x62).
        #expect(try bytes(value) == #"{"Z":0,"_x":3,"a":1,"b":2}"#)
    }

    @Test("NFC and NFD inputs serialize to identical bytes")
    func normalization() throws {
        let nfc = "é" // U+00E9
        let nfd = "e\u{0301}" // e + combining acute
        // Different composition forms (byte-distinct), canonically equal.
        #expect(nfc.unicodeScalars.count != nfd.unicodeScalars.count)
        let a = try bytes(.string(nfc))
        let b = try bytes(.string(nfd))
        #expect(a == b)
        #expect(a == "\"\u{00E9}\"")
    }

    @Test("RFC 8785 escaping: shorthand controls, \\u00xx, non-ASCII as-is")
    func escaping() throws {
        let s = "\u{08}\u{09}\u{0A}\u{0C}\u{0D}\u{01}\"\\€"
        #expect(try bytes(.string(s)) == "\"\\b\\t\\n\\f\\r\\u0001\\\"\\\\€\"")
    }

    @Test("forward slash is not escaped")
    func slashes() throws {
        #expect(try bytes(.string("a/b")) == "\"a/b\"")
    }

    @Test("non-ASCII key throws at serialization")
    func nonASCIIKey() {
        let value = CanonicalValue.object(["café": .int(1)])
        #expect(throws: CanonicalJSONError.nonASCIIKey("café")) {
            _ = try value.serialized()
        }
    }

    @Test("nested structures serialize without whitespace")
    func nested() throws {
        let value = CanonicalValue.object([
            "list": .array([.int(1), .null, .bool(true), .string("x")]),
            "obj": .object(["k": .string("v")]),
        ])
        #expect(try bytes(value) == #"{"list":[1,null,true,"x"],"obj":{"k":"v"}}"#)
    }

    @Test("round-trip: parse(serialized(v)) == normalized v")
    func roundTrip() throws {
        let value = CanonicalValue.object([
            "a": .array([.int(-42), .int(0), .int(Int64.max), .int(Int64.min)]),
            "s": .string("héllo\nworld"),
            "n": .null,
            "b": .bool(false),
            "o": .object(["inner": .array([])]),
        ])
        let data = try value.serialized()
        let reparsed = try CanonicalValue.parse(data)
        #expect(try reparsed.serialized() == data)
    }

    @Test("parser rejects floats")
    func floatRejected() {
        #expect(throws: CanonicalJSONError.floatRejected) {
            _ = try CanonicalValue.parse(Data(#"{"x":1.5}"#.utf8))
        }
        #expect(throws: CanonicalJSONError.floatRejected) {
            _ = try CanonicalValue.parse(Data(#"[1e3]"#.utf8))
        }
    }

    @Test("parser rejects duplicate keys")
    func duplicateKeys() {
        #expect(throws: CanonicalJSONError.duplicateKey("a")) {
            _ = try CanonicalValue.parse(Data(#"{"a":1,"a":2}"#.utf8))
        }
    }

    @Test("parser rejects lone surrogate escapes")
    func loneSurrogate() {
        #expect(throws: CanonicalJSONError.loneSurrogate) {
            _ = try CanonicalValue.parse(Data(#""\ud800""#.utf8))
        }
        #expect(throws: CanonicalJSONError.loneSurrogate) {
            _ = try CanonicalValue.parse(Data(#""\udc00x""#.utf8))
        }
    }

    @Test("parser accepts surrogate pairs")
    func surrogatePair() throws {
        let value = try CanonicalValue.parse(Data(#""😀""#.utf8))
        #expect(value == .string("😀"))
    }

    @Test("parser rejects trailing garbage, leading zeros, and overflow")
    func strictness() {
        #expect(throws: CanonicalJSONError.trailingGarbage) {
            _ = try CanonicalValue.parse(Data("{}x".utf8))
        }
        #expect(throws: CanonicalJSONError.malformed("leading zero")) {
            _ = try CanonicalValue.parse(Data("[01]".utf8))
        }
        #expect(throws: CanonicalJSONError.integerOverflow) {
            _ = try CanonicalValue.parse(Data("[92233720368547758080]".utf8))
        }
    }

    @Test("adapted RFC 8785 vectors (integer/string/structure subset)")
    func jcsVectors() throws {
        // From the JCS reference set, restricted to the canonical subset
        // (float vectors are excluded by the type model itself).
        #expect(try bytes(.object([
            "literals": .array([.null, .bool(true), .bool(false)]),
        ])) == #"{"literals":[null,true,false]}"#)
        #expect(try bytes(.object([
            "numbers": .array([.int(333333333), .int(-1), .int(0)]),
        ])) == #"{"numbers":[333333333,-1,0]}"#)
        // U+20AC euro sign stays literal; DEL (U+007F) is not escaped per JCS.
        #expect(try bytes(.string("€$\u{000F}\nA'B\"\\\\\"/")) ==
            "\"€$\\u000f\\nA'B\\\"\\\\\\\\\\\"/\"")
    }
}
