import Testing
@testable import Clicky

struct ScreenDrawingClearPolicyTests {
    private func shouldClear(isStreaming: Bool = false, secondsSinceFinished: Double? = nil, isVoiceTurnActive: Bool = false) -> Bool {
        ScreenDrawingClearPolicy.shouldClearOnScreenChange(
            isStreaming: isStreaming,
            secondsSinceFinished: secondsSinceFinished,
            isVoiceTurnActive: isVoiceTurnActive
        )
    }

    @Test func doesNotClearWhileStreaming() {
        #expect(!shouldClear(isStreaming: true, secondsSinceFinished: 100))
    }

    @Test func doesNotClearDuringVoiceTurn() {
        #expect(!shouldClear(secondsSinceFinished: 100, isVoiceTurnActive: true))
    }

    @Test func doesNotClearInsideGracePeriod() {
        #expect(!shouldClear(secondsSinceFinished: 1))
    }

    @Test func clearsAfterGracePeriod() {
        #expect(shouldClear(secondsSinceFinished: ScreenDrawingClearPolicy.gracePeriodAfterFinishSeconds + 1))
    }

    @Test func clearsWhenNeverFinishedAndIdle() {
        #expect(shouldClear(secondsSinceFinished: nil))
    }
}
