import Foundation
import GRDB

/// A Lens is a pure fold over the Ledger (SPEC §6): disposable, rebuildable,
/// versioned. Implementations are idempotent — folding the same event twice
/// equals folding it once — and refold affected outputs on late arrivals.
public protocol Lens: Sendable {
    var name: String { get }
    /// Pins fold code + parameters (a timezone change, a prompt change, a
    /// model change all bump this). Mismatch with stored metadata triggers
    /// truncate-and-rebuild from genesis.
    var viewVersion: String { get }

    /// Fold newly arrived events. `all` is the full current Ledger (M0
    /// corpus scale makes the full snapshot the simple, correct choice).
    func fold(new: [Event], all: [Event]) throws
    /// Truncate derived output for a rebuild.
    func reset() throws
}

/// The per-Lens fold loop (SPEC §11.7's Folder actor): tracks
/// (viewVersion, high-water rowid) per lens, rebuilds on version bumps,
/// folds incrementally otherwise. Nothing writes a Lens except through here.
public actor Folder {
    private let store: LedgerStore
    private let lenses: [any Lens]

    public init(store: LedgerStore, lenses: [any Lens]) throws {
        self.store = store
        self.lenses = lenses
        try store.writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS lens (
                  name TEXT PRIMARY KEY,
                  view_version TEXT NOT NULL,
                  high_water_rowid INTEGER NOT NULL
                ) STRICT
                """)
        }
    }

    /// Fold everything unfolded, per lens. Returns the number of events
    /// folded per lens name.
    @discardableResult
    public func foldPending() async throws -> [String: Int] {
        var folded = [String: Int]()
        for lens in lenses {
            folded[lens.name] = try foldPending(lens: lens)
        }
        return folded
    }

    /// Force a rebuild from genesis for one lens.
    public func rebuild(lensNamed name: String) async throws {
        guard let lens = lenses.first(where: { $0.name == name }) else { return }
        try setMetadata(lens: lens, highWater: 0, resetVersion: true)
        try lens.reset()
        _ = try foldPending(lens: lens)
    }

    private func foldPending(lens: any Lens) throws -> Int {
        var highWater = try metadata(for: lens)
        if highWater == nil {
            // Fresh lens or version bump: rebuild from genesis while the
            // Ledger keeps serving (SPEC §6).
            try lens.reset()
            try setMetadata(lens: lens, highWater: 0)
            highWater = 0
        }
        let batch = try store.fetch(after: highWater!)
        guard !batch.isEmpty else { return 0 }
        let all = try store.fetchAll()
        try lens.fold(new: batch.map(\.event), all: all)
        try setMetadata(lens: lens, highWater: batch.last!.rowID)
        return batch.count
    }

    /// nil means "needs rebuild" (absent or version-mismatched).
    private func metadata(for lens: any Lens) throws -> Int64? {
        try store.writer.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT view_version, high_water_rowid FROM lens WHERE name = ?",
                arguments: [lens.name]) else { return nil }
            guard row["view_version"] as String == lens.viewVersion else { return nil }
            return row["high_water_rowid"]
        }
    }

    private func setMetadata(lens: any Lens, highWater: Int64, resetVersion: Bool = false) throws {
        try store.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO lens (name, view_version, high_water_rowid) VALUES (?, ?, ?)
                ON CONFLICT(name) DO UPDATE SET view_version = excluded.view_version,
                                                high_water_rowid = excluded.high_water_rowid
                """,
                arguments: [lens.name, resetVersion ? "" : lens.viewVersion, highWater])
        }
    }
}
