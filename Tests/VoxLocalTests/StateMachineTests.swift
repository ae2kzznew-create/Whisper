import XCTest
@testable import VoxLocalCore

final class StateMachineTests: XCTestCase {
    func testHappyPathFullPipeline() throws {
        var machine = DictationStateMachine()
        for state: DictationState in [.preparing, .recording, .stopping, .transcribing, .refining, .inserting, .completed, .idle] {
            try machine.transition(to: state)
        }
        XCTAssertEqual(machine.state, .idle)
    }

    func testHappyPathWithoutRefining() throws {
        var machine = DictationStateMachine()
        for state: DictationState in [.preparing, .recording, .stopping, .transcribing, .inserting, .completed, .idle] {
            try machine.transition(to: state)
        }
        XCTAssertEqual(machine.state, .idle)
    }

    func testCannotStartWhileActive() throws {
        var machine = DictationStateMachine()
        try machine.transition(to: .preparing)
        XCTAssertTrue(machine.isActive)
        XCTAssertFalse(machine.canTransition(to: .preparing))
        XCTAssertThrowsError(try machine.transition(to: .preparing))
    }

    func testCancellationFromEveryActiveState() throws {
        let activeStates: [DictationState] = [.preparing, .recording, .stopping, .transcribing, .refining, .inserting]
        for state in activeStates {
            var machine = DictationStateMachine(state: state)
            XCTAssertTrue(machine.isCancellable, "\(state) must be cancellable")
            try machine.transition(to: .cancelled)
            try machine.transition(to: .idle)
            XCTAssertEqual(machine.state, .idle)
        }
    }

    func testErrorFromEveryActiveState() throws {
        for state: DictationState in [.preparing, .recording, .stopping, .transcribing, .refining, .inserting] {
            var machine = DictationStateMachine(state: state)
            try machine.transition(to: .error)
            try machine.transition(to: .idle)
        }
    }

    func testInvalidJumps() {
        var machine = DictationStateMachine()
        XCTAssertThrowsError(try machine.transition(to: .recording))
        XCTAssertThrowsError(try machine.transition(to: .transcribing))
        XCTAssertThrowsError(try machine.transition(to: .completed))

        var recording = DictationStateMachine(state: .recording)
        XCTAssertThrowsError(try recording.transition(to: .inserting))
        XCTAssertThrowsError(try recording.transition(to: .completed))
        XCTAssertThrowsError(try recording.transition(to: .idle))
    }

    func testTerminalStatesOnlyReturnToIdle() {
        for state: DictationState in [.completed, .cancelled, .error] {
            let machine = DictationStateMachine(state: state)
            for target in DictationState.allCases where target != .idle {
                XCTAssertFalse(machine.canTransition(to: target), "\(state) → \(target) must be invalid")
            }
            XCTAssertTrue(machine.canTransition(to: .idle))
            XCTAssertFalse(machine.isCancellable)
        }
    }

    func testIdleIsNotActive() {
        XCTAssertFalse(DictationStateMachine().isActive)
    }
}
