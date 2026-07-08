import CloudKit
import Foundation
import Testing
@testable import FirmamentKit

@Suite("Sync record mapping")
struct RecordMappingTests {
    private func sampleEvent(
        kind: EventKind = .captureText,
        device: DeviceID = .phone,
        author: Author = .human,
        tier: Tier = .personal,
        parentID: UUID? = nil,
        body: String = "synced note"
    ) throws -> Event {
        let draft = Event.Draft(
            kind: kind, occurredAt: 1_780_000_000_000, recordedAt: 1_780_000_005_000,
            deviceID: device, author: author, tier: tier, parentID: parentID,
            payload: CaptureTextPayload(body: body, sourcePlane: .composer).canonical)
        return try Event.seal(draft, prevHash: HashChain.genesis(for: device))
    }

    @Test("event → record → event is identity across every field")
    func mappingIdentity() throws {
        let parent = UUID.firmamentV7()
        let event = try sampleEvent(author: .agent(grantID: "g_7f2"), tier: .open, parentID: parent)
        let record = try RecordMapping.record(for: event)
        let (decoded, audioURL) = try RecordMapping.event(from: record)
        #expect(decoded == event)
        #expect(audioURL == nil)
        #expect(record.recordID.recordName == "event:\(event.id.uuidString.lowercased())")
    }

    @Test("payload rides encryptedValues, not plaintext fields")
    func payloadEncrypted() throws {
        let event = try sampleEvent()
        let record = try RecordMapping.record(for: event)
        #expect(record.encryptedValues[RecordMapping.Field.payload] as? Data == event.payload)
        #expect(record[RecordMapping.Field.payload] == nil)
        #expect(record.encryptedValues[RecordMapping.Field.hash] as? Data == event.hash)
        #expect(record.encryptedValues[RecordMapping.Field.prevHash] as? Data == event.prevHash)
    }

    @Test("oversized payload spills transport-side and round-trips against payloadHash")
    func oversizeSpill() throws {
        let bigBody = String(repeating: "x", count: RecordMapping.payloadSpillThreshold + 10_000)
        let event = try sampleEvent(body: bigBody)
        let spillDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-spill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: spillDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: spillDir) }

        let record = try RecordMapping.record(for: event, spillDirectory: spillDir)
        #expect(record.encryptedValues[RecordMapping.Field.payload] == nil)
        #expect(record[RecordMapping.Field.payloadAsset] is CKAsset)

        let (decoded, _) = try RecordMapping.event(from: record)
        #expect(decoded == event)
        #expect(decoded.verifySelfIntegrity())
    }

    @Test("tampered payload bytes fail ingest with payloadHashMismatch")
    func tamperDetection() throws {
        let event = try sampleEvent()
        let record = try RecordMapping.record(for: event)
        var tampered = event.payload
        tampered[0] ^= 0xFF
        record.encryptedValues[RecordMapping.Field.payload] = tampered
        #expect(throws: RecordMapping.MappingError.payloadHashMismatch(event.id)) {
            _ = try RecordMapping.event(from: record)
        }
    }

    @Test("a foreign chain synced record-by-record verifies on the receiving device")
    func foreignChainVerifies() async throws {
        // Phone builds a chain…
        var prev = HashChain.genesis(for: .phone)
        var phoneEvents = [Event]()
        for index in 0..<10 {
            let draft = Event.Draft(
                kind: .captureText, occurredAt: Int64(index) * 1000, recordedAt: Int64(index) * 1000,
                deviceID: .phone, author: .human, tier: .personal,
                payload: CaptureTextPayload(body: "phone \(index)", sourcePlane: .composer).canonical)
            let event = try Event.seal(draft, prevHash: prev)
            prev = event.hash
            phoneEvents.append(event)
        }
        // …which arrives on the Mac as records, out of order, some twice.
        let store = try LedgerStore.inMemory()
        let ledger = try Ledger(store: store, deviceID: .mac)
        var arrivals = phoneEvents + [phoneEvents[3], phoneEvents[7]]
        var rng = SplitMix64(seed: 99)
        arrivals.shuffle(using: &rng)
        for original in arrivals {
            let record = try RecordMapping.record(for: original)
            let (decoded, _) = try RecordMapping.event(from: record)
            try await ledger.ingest(decoded)
        }
        guard case .intact(_, let count) = try store.verifyChains()[.phone] else {
            Issue.record("foreign chain not intact after synced ingest")
            return
        }
        #expect(count == 10)
    }

    @Test("conflict policy: identical immutable record adopts server; divergence alarms")
    func conflictPolicy() throws {
        let event = try sampleEvent()
        #expect(ConflictPolicy.resolveServerRecordChanged(local: event, server: event) == .adoptServer)

        var tamperedPayload = event.payload
        tamperedPayload[0] ^= 0x01
        let divergent = Event(
            id: event.id, kind: event.kind, occurredAt: event.occurredAt,
            recordedAt: event.recordedAt, deviceID: event.deviceID,
            author: event.author, tier: event.tier, parentID: event.parentID,
            payload: tamperedPayload, payloadHash: event.payloadHash,
            prevHash: event.prevHash, hash: event.hash)
        #expect(ConflictPolicy.resolveServerRecordChanged(local: event, server: divergent)
            == .integrityAlarm(eventID: event.id))
    }

    @Test("upload gate: capture.audio waits for its staged asset; text never waits")
    func uploadGating() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let audioStore = try AudioFileStore(root: root)
        let ledger = try Ledger(store: LedgerStore.inMemory(), deviceID: .mac)
        let pipeline = CapturePipeline(ledger: ledger, audioStore: audioStore)

        let text = try await pipeline.captureText(body: "gate me", sourcePlane: .composer)
        #expect(UploadGate.isReadyToUpload(text, audioStore: audioStore))

        // An audio event whose file is not staged (foreign-style) is held.
        let draft = Event.Draft(
            kind: .captureAudio, occurredAt: 1, recordedAt: 1,
            deviceID: .mac, author: .human, tier: .personal,
            payload: CaptureAudioPayload(
                fileHash: String(repeating: "e", count: 64), durationMS: 100).canonical)
        let held = try Event.seal(draft, prevHash: HashChain.genesis(for: .mac))
        #expect(!UploadGate.isReadyToUpload(held, audioStore: audioStore))
        #expect(UploadGate.audioFileURL(for: held, audioStore: audioStore) == nil)

        // A locally captured audio event is ready, with its URL.
        let handle = try audioStore.beginRecording()
        try audioStore.append(Data("real audio".utf8), to: handle)
        let capture = try await pipeline.completeAudioCapture(handle, durationMS: 800)
        #expect(UploadGate.isReadyToUpload(capture, audioStore: audioStore))
        #expect(UploadGate.audioFileURL(for: capture, audioStore: audioStore) != nil)
    }

    @Test("audio asset round-trips through the record")
    func audioAsset() throws {
        let audioBytes = Data("caf bytes".utf8)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-asset-\(UUID().uuidString).caf")
        try audioBytes.write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let draft = Event.Draft(
            kind: .captureAudio, occurredAt: 1, recordedAt: 1,
            deviceID: .phone, author: .human, tier: .personal,
            payload: CaptureAudioPayload(
                fileHash: String(repeating: "f", count: 64), durationMS: 100).canonical)
        let event = try Event.seal(draft, prevHash: HashChain.genesis(for: .phone))
        let record = try RecordMapping.record(for: event, audioFileURL: audioURL)
        let (decoded, assetURL) = try RecordMapping.event(from: record)
        #expect(decoded == event)
        #expect(assetURL != nil)
        #expect(try Data(contentsOf: assetURL!) == audioBytes)
    }
}
