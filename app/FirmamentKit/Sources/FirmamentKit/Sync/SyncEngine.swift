import CloudKit
import Foundation
import os

/// The thin CloudKit-facing shell (plan U12/KTD7). Everything with logic —
/// mapping, gating, conflicts, ingest, state, checkpoints — lives in the
/// pure U9/SyncState layers and is CI-tested; this actor is wiring, and its
/// verification is the operator-assisted two-device round-trip (CloudKit
/// push works on real devices only).
public actor SyncEngine {
    private let ledger: Ledger
    private let audioStore: AudioFileStore
    private let stateStore: SyncStateStore
    private let containerIdentifier: String
    private let folder: Folder?

    private var engine: CKSyncEngine?
    /// The engine does not retain its delegate — we must, or events never
    /// arrive and no state is ever persisted (silent no-op sync).
    private var delegate: Delegate?
    private var zoneCreated = false
    private let log = Logger(subsystem: "com.davidraphael.firmament", category: "sync")
    /// Integrity alarms from divergent "immutable" records — surfaced to the
    /// app layer; never resolved silently (KTD7).
    public private(set) var integrityAlarms = [UUID]()

    public init(
        ledger: Ledger,
        audioStore: AudioFileStore,
        stateStore: SyncStateStore,
        containerIdentifier: String = "iCloud.com.davidraphael.firmament",
        folder: Folder? = nil
    ) {
        self.ledger = ledger
        self.audioStore = audioStore
        self.stateStore = stateStore
        self.containerIdentifier = containerIdentifier
        self.folder = folder
    }

    /// Build the engine with the saved state serialization and enqueue
    /// anything the Ledger says is unsent. Requires CloudKit entitlements —
    /// never called from unit tests.
    public func start() throws {
        let container = CKContainer(identifier: containerIdentifier)
        let delegate = Delegate(owner: self)
        self.delegate = delegate
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadStateSerialization(),
            delegate: delegate
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if !zoneCreated {
            engine.state.add(pendingDatabaseChanges: [
                .saveZone(CKRecordZone(zoneID: RecordMapping.zoneID())),
            ])
            zoneCreated = true
        }
        try enqueueUnsent()
        log.info("sync engine started; container \(self.containerIdentifier, privacy: .public)")
    }

    /// Force a fetch+send cycle (test/diagnostic path — never called from
    /// inside a delegate callback, which would risk a loop).
    public func syncNow() async throws {
        guard let engine else { return }
        try enqueueUnsent()
        try await engine.fetchChanges()
        try await engine.sendChanges()
    }

    /// Diagnostics for the operator: is the engine live, and what's pending?
    public func status() throws -> String {
        let pending = try stateStore.pendingUploads(deviceID: ledger.deviceID, audioStore: audioStore)
        let started = engine != nil
        return "engine: \(started ? "started" : "not started"); pending uploads: \(pending.count); alarms: \(integrityAlarms.count)"
    }

    /// Re-derive pending uploads from the Ledger (the durability boundary)
    /// and hand them to the engine. Called at start and after local appends.
    public func enqueueUnsent() throws {
        guard let engine else { return }
        let pending = try stateStore.pendingUploads(deviceID: ledger.deviceID, audioStore: audioStore)
        guard !pending.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: pending.map {
            .saveRecord(RecordMapping.recordID(for: $0.id))
        })
    }

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = stateStore.loadEngineState() else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    // MARK: Event handling (delegate calls back into the actor)

    func handle(_ event: CKSyncEngine.Event) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            if let data = try? JSONEncoder().encode(stateUpdate.stateSerialization) {
                try? stateStore.saveEngineState(data)
            }

        case .accountChange(let change):
            await handleAccountChange(change)

        case .fetchedRecordZoneChanges(let changes):
            log.info("fetched \(changes.modifications.count) record(s)")
            await ingest(modifications: changes.modifications.map(\.record))

        case .sentRecordZoneChanges(let sent):
            let savedIDs = sent.savedRecords.compactMap { RecordMapping.eventID(from: $0.recordID) }
            try? stateStore.markSent(savedIDs)
            log.info("sent \(savedIDs.count) record(s); \(sent.failedRecordSaves.count) failure(s)")
            for failure in sent.failedRecordSaves {
                log.error("save failed: \(failure.error.localizedDescription, privacy: .public)")
                await handleFailedSave(failure)
            }

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                log.error("zone save failed: \(failure.error.localizedDescription, privacy: .public)")
            }

        default:
            break
        }
    }

    func nextBatch(_ context: CKSyncEngine.SendChangesContext) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let engine else { return nil }
        let scope = context.options.scope
        let changes = engine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            await self.record(for: recordID)
        }
    }

    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard let eventID = RecordMapping.eventID(from: recordID),
              let event = try? ledger.store.fetchEvent(id: eventID) else { return nil }
        // The gate re-checks at send time: an audio capture whose asset is
        // not staged yet steps out of this batch (KTD7).
        guard UploadGate.isReadyToUpload(event, audioStore: audioStore) else { return nil }
        return try? RecordMapping.record(
            for: event,
            audioFileURL: UploadGate.audioFileURL(for: event, audioStore: audioStore)
        )
    }

    private func ingest(modifications: [CKRecord]) async {
        var ingestedAny = false
        for record in modifications {
            guard let (event, assetURL) = try? RecordMapping.event(from: record) else { continue }
            // Copy the asset out before the delegate returns — CloudKit may
            // delete its temp file afterwards.
            if let assetURL, event.kind == .captureAudio {
                _ = try? audioStore.adopt(temporaryFile: assetURL)
            }
            if (try? await ledger.ingest(event)) == true {
                ingestedAny = true
            }
        }
        if ingestedAny, let folder {
            try? await folder.foldPending()
        }
    }

    private func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) async {
        guard failure.error.code == .serverRecordChanged,
              let serverRecord = failure.error.serverRecord,
              let eventID = RecordMapping.eventID(from: failure.record.recordID),
              let local = try? ledger.store.fetchEvent(id: eventID),
              let (server, _) = try? RecordMapping.event(from: serverRecord) else { return }
        switch ConflictPolicy.resolveServerRecordChanged(local: local, server: server) {
        case .adoptServer:
            // Content is identical by construction; drop the pending save.
            try? stateStore.markSent([eventID])
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
        case .integrityAlarm(let id):
            integrityAlarms.append(id)
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        switch change.changeType {
        case .signIn:
            // Cold-start also fires signIn — just flush the queue.
            try? enqueueUnsent()
        case .signOut, .switchAccounts:
            // n=1 personal tool: never delete local data on sign-out (the
            // Ledger is the operator's, not the account's — deliberate
            // deviation from Apple's multi-user guidance). Reset engine
            // state so a future sign-in re-uploads from the Ledger.
            try? stateStore.reset()
            engine = nil
        @unknown default:
            break
        }
    }

    // MARK: Delegate bridge (CKSyncEngineDelegate is a nonisolated protocol)

    private final class Delegate: NSObject, CKSyncEngineDelegate {
        /// Weak: the actor retains this delegate, so a strong back-reference
        /// would be a cycle that never releases the engine. Weak reads are
        /// atomic in the Swift runtime, which is what `unsafe` waives here.
        nonisolated(unsafe) weak var owner: SyncEngine?

        init(owner: SyncEngine) {
            self.owner = owner
        }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            await owner?.handle(event)
        }

        func nextRecordZoneChangeBatch(
            _ context: CKSyncEngine.SendChangesContext,
            syncEngine: CKSyncEngine
        ) async -> CKSyncEngine.RecordZoneChangeBatch? {
            await owner?.nextBatch(context)
        }
    }
}
