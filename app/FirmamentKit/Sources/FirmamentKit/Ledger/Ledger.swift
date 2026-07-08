import Foundation
import GRDB

/// The single-writer append authority (SPEC §11.7). All local event creation
/// funnels through this actor so chain heads never race; sync ingest of
/// foreign events funnels through it too (idempotent by id).
public actor Ledger {
    public nonisolated let store: LedgerStore
    /// This device's identity — the chain local appends extend.
    public nonisolated let deviceID: DeviceID

    private var chainHead: Data

    public init(store: LedgerStore, deviceID: DeviceID) throws {
        self.store = store
        self.deviceID = deviceID
        self.chainHead = try store.chainHead(for: deviceID)
    }

    /// Seal a draft onto this device's chain and persist it. The sacred
    /// append path's DB half — callers (U4 capture pipeline) fsync any
    /// sidecar file *before* calling this.
    @discardableResult
    public func append(
        kind: EventKind,
        occurredAt: Int64,
        recordedAt: Int64 = UUIDv7Generator.currentMS(),
        author: Author,
        tier: Tier = .personal,
        parentID: UUID? = nil,
        payload: CanonicalValue
    ) throws -> Event {
        let draft = Event.Draft(
            kind: kind, occurredAt: occurredAt, recordedAt: recordedAt,
            deviceID: deviceID, author: author, tier: tier,
            parentID: parentID, payload: payload
        )
        let event = try Event.seal(draft, prevHash: chainHead)
        try store.insert(event)
        chainHead = event.hash
        return event
    }

    /// Ingest a foreign (synced) event verbatim. Idempotent by id; never
    /// re-seals — stored bytes and hashes arrive as truth and are verified
    /// by chain verification, not silently recomputed.
    /// - Returns: true when the event was new.
    @discardableResult
    public func ingest(_ event: Event) throws -> Bool {
        try store.insert(event)
    }

    public func currentChainHead() -> Data {
        chainHead
    }
}
