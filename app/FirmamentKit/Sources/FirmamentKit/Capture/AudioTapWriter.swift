import AVFoundation
import Foundation

/// Realtime-safe sink for AVAudio input taps. The tap callback runs on
/// CoreAudio's realtime messenger queue; a closure formed inside a
/// `@MainActor` recorder inherits main-actor isolation and trips the
/// runtime's executor assertion there (`_dispatch_assert_queue_fail`).
/// This class is deliberately nonisolated: pass `writer.handle` as the tap
/// block, and main-actor recorder state is reached only through the
/// `@Sendable` level callback, which hops explicitly.
///
/// `@unchecked Sendable` is sound because the `AVAudioFile` is created for,
/// handed to, and written by exactly one tap; nothing else touches it until
/// the recorder tears the tap down and releases this writer (which closes
/// the file and completes the CAF header).
public final class AudioTapWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let onLevel: @Sendable (Float) -> Void

    public init(file: AVAudioFile, onLevel: @escaping @Sendable (Float) -> Void) {
        self.file = file
        self.onLevel = onLevel
    }

    /// Matches `AVAudioNodeTapBlock` — pass as an unapplied method reference
    /// so the block carries no actor isolation.
    public func handle(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        try? file.write(from: buffer)
        onLevel(Self.rmsLevel(of: buffer))
    }

    public static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frames {
            sum += data[index] * data[index]
        }
        return min(1, (sum / Float(frames)).squareRoot() * 6)
    }
}
