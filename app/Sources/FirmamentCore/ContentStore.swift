import CryptoKit
import Foundation

/// Content-addressed storage for raw imported bytes. The key is the SHA-256
/// hex of the raw bytes (plan §4). Objects are written atomically and deleted
/// only when no entryRevision references their hash (checked by the caller).
public struct ContentStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    public static func hash(of data: Data) -> String {
        var out = [UInt8](); out.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public func objectURL(for hash: String) -> URL {
        rootURL
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    /// Stores data, returns its hash. Idempotent; atomic (temp + rename).
    @discardableResult
    public func put(_ data: Data) throws -> String {
        let hash = Self.hash(of: data)
        let url = objectURL(for: hash)
        if FileManager.default.fileExists(atPath: url.path) { return hash }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return hash
    }

    public func contains(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: objectURL(for: hash).path)
    }

    public func data(for hash: String) throws -> Data {
        try Data(contentsOf: objectURL(for: hash))
    }

    /// Physical removal of the object's bytes (unlink — plan §4's honesty
    /// clause: not a secure overwrite).
    public func delete(_ hash: String) throws {
        let url = objectURL(for: hash)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Every object hash currently on disk (for the orphan sweep).
    public func allObjectHashes() throws -> [String] {
        let fm = FileManager.default
        guard let shards = try? fm.contentsOfDirectory(atPath: rootURL.path) else {
            return []
        }
        var hashes: [String] = []
        for shard in shards where shard.count == 2 {
            let shardURL = rootURL.appendingPathComponent(shard)
            for name in (try? fm.contentsOfDirectory(atPath: shardURL.path)) ?? [] {
                hashes.append(name)
            }
        }
        return hashes
    }
}
