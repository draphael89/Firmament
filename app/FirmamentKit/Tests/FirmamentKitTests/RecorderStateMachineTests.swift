import Testing
@testable import FirmamentKit

@Suite("Recorder state machine")
struct RecorderStateMachineTests {
    @Test("start → stop emits exactly one capture")
    func startStop() {
        var machine = RecorderStateMachine()
        #expect(machine.start(nowMS: 100) == .beginCapture(startedAtMS: 100))
        #expect(machine.stop() == .finalizeCapture(startedAtMS: 100, interrupted: false))
        #expect(machine.state == .idle)
    }

    @Test("double start cannot spawn a second capture")
    func doubleStart() {
        var machine = RecorderStateMachine()
        #expect(machine.start(nowMS: 100) == .beginCapture(startedAtMS: 100))
        #expect(machine.start(nowMS: 200) == .none)
    }

    @Test("rapid double stop is safe")
    func doubleStop() {
        var machine = RecorderStateMachine()
        _ = machine.start(nowMS: 100)
        #expect(machine.stop() != .none)
        #expect(machine.stop() == .none)
        #expect(machine.stop() == .none)
    }

    @Test("stop while idle is a no-op")
    func stopWhileIdle() {
        var machine = RecorderStateMachine()
        #expect(machine.stop() == .none)
    }

    @Test("interruption finalizes the partial through the same path")
    func interruption() {
        var machine = RecorderStateMachine()
        _ = machine.start(nowMS: 500)
        #expect(machine.interruption() == .finalizeCapture(startedAtMS: 500, interrupted: true))
        #expect(machine.interruption() == .none)
    }
}
