/// Platform-free recorder state logic (plan U4): U5's AVAudioEngine adapter
/// on the Mac and U10's session adapter on the phone stay thin — start/stop/
/// interruption semantics and the exactly-one-capture guarantee live here.
public struct RecorderStateMachine: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case recording(startedAtMS: Int64)
    }

    public enum Effect: Sendable, Equatable {
        /// Open a temp file and start streaming frames.
        case beginCapture(startedAtMS: Int64)
        /// Finalize the current temp file into a capture (interrupted marks
        /// an unnatural end — phone call, route loss).
        case finalizeCapture(startedAtMS: Int64, interrupted: Bool)
        case none
    }

    public private(set) var state: State = .idle

    public init() {}

    /// Start requested (hotkey, Action Button). Ignored while recording —
    /// rapid double-start cannot spawn a second capture.
    public mutating func start(nowMS: Int64) -> Effect {
        guard case .idle = state else { return .none }
        state = .recording(startedAtMS: nowMS)
        return .beginCapture(startedAtMS: nowMS)
    }

    /// Stop requested. Ignored while idle — rapid double-stop is safe.
    public mutating func stop() -> Effect {
        guard case .recording(let startedAtMS) = state else { return .none }
        state = .idle
        return .finalizeCapture(startedAtMS: startedAtMS, interrupted: false)
    }

    /// System interruption (phone call, route change): the partial capture
    /// finalizes through the same path — saved, never lost.
    public mutating func interruption() -> Effect {
        guard case .recording(let startedAtMS) = state else { return .none }
        state = .idle
        return .finalizeCapture(startedAtMS: startedAtMS, interrupted: true)
    }
}
