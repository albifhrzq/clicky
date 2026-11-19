import Testing
@testable import Clicky

struct ClickyNotchCardsTests {
    @Test func countdownDoesNotAdvanceWhilePaused() {
        let countdown = NotchAutoDismissCountdown(totalSeconds: 20)
        let afterPausedTick = countdown.advanced(by: 5, isPaused: true)
        #expect(afterPausedTick.remainingSeconds == 20)
    }

    @Test func countdownExpiresAfterTotalDuration() {
        var countdown = NotchAutoDismissCountdown(totalSeconds: 2)
        countdown = countdown.advanced(by: 1, isPaused: false)
        #expect(!countdown.isExpired)
        #expect(countdown.fractionRemaining == 0.5)
        countdown = countdown.advanced(by: 5, isPaused: false)
        #expect(countdown.isExpired)
        #expect(countdown.fractionRemaining == 0)
    }

    @Test func suggestionPagingWrapsInBothDirections() {
        #expect(NotchSuggestionPaging.index(from: 2, offset: 1, count: 3) == 0)
        #expect(NotchSuggestionPaging.index(from: 0, offset: -1, count: 3) == 2)
        #expect(NotchSuggestionPaging.index(from: 0, offset: 1, count: 0) == 0)
    }
}
