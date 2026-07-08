import Foundation

/// The crash-harness driver (plan U11): continuous synthetic captures
/// through the *real* capture pipeline — in-progress recordings included —
/// until killed. The harness SIGKILLs this at randomized points, relaunches
/// with `reconcile`, then `verify`s the chains.
public enum StressCapture {
    public static func makePipeline(root: URL) throws -> CapturePipeline {
        let audio = try AudioFileStore(root: root.appendingPathComponent("media"))
        let store = try LedgerStore.pool(at: root.appendingPathComponent("ledger.sqlite").path)
        let ledger = try Ledger(store: store, deviceID: .mac)
        return CapturePipeline(ledger: ledger, audioStore: audio)
    }

    /// Runs until killed.
    public static func run(root: URL) async throws -> Never {
        let pipeline = try makePipeline(root: root)
        var iteration = 0
        while true {
            let handle = try pipeline.audioStore.beginRecording()
            for _ in 0..<Int.random(in: 1...6) {
                let chunk = Data((0..<Int.random(in: 512...4096)).map { _ in UInt8.random(in: 0...255) })
                try pipeline.audioStore.append(chunk, to: handle)
                try pipeline.audioStore.flush(handle)
            }
            try await pipeline.completeAudioCapture(handle, durationMS: Int64.random(in: 500...5_000))
            if iteration % 3 == 0 {
                try await pipeline.captureText(body: "stress capture \(iteration)", sourcePlane: .composer)
            }
            iteration += 1
        }
    }

    /// The relaunch half: adopt survivors, report.
    public static func reconcile(root: URL) async throws -> Reconciler.Report {
        let pipeline = try makePipeline(root: root)
        return try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
    }
}
