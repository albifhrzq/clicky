import CoreGraphics
import Testing
@testable import Clicky

struct ClickyOverlayIdleTests {
    @Test func indicatorAnimatesOnlyWhenStateMatchesAndBuddyIsVisible() {
        #expect(ClickyIdleChurnRules.isIndicatorAnimationActive(isMatchingVoiceState: true, isBuddyVisibleOnThisScreen: true))
        #expect(!ClickyIdleChurnRules.isIndicatorAnimationActive(isMatchingVoiceState: true, isBuddyVisibleOnThisScreen: false))
        #expect(!ClickyIdleChurnRules.isIndicatorAnimationActive(isMatchingVoiceState: false, isBuddyVisibleOnThisScreen: true))
    }

    @Test func spinnerCompletesOneTurnEveryEightTenthsOfASecond() {
        #expect(ClickyIdleChurnRules.spinnerRotationDegrees(timeIntervalSinceReferenceDate: 0.4) == 180.0)
        #expect(ClickyIdleChurnRules.spinnerRotationDegrees(timeIntervalSinceReferenceDate: 0.0) == 0.0)
        let angle = ClickyIdleChurnRules.spinnerRotationDegrees(timeIntervalSinceReferenceDate: 1234.5)
        #expect(angle >= 0 && angle < 360)
    }

    @Test func buddyFollowPositionAppliesOffsetAndFlipsY() {
        let screenFrame = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let position = ClickyIdleChurnRules.buddyFollowPosition(
            mouseLocation: CGPoint(x: 200, y: 850),
            screenFrame: screenFrame
        )
        #expect(position == CGPoint(x: 100 + 35, y: 0 + 25))
    }

    @Test func returnFlightCancelsOnlyBeyondOneHundredPoints() {
        #expect(!ClickyIdleChurnRules.shouldCancelReturnFlight(distanceFromNavigationStart: 100))
        #expect(ClickyIdleChurnRules.shouldCancelReturnFlight(distanceFromNavigationStart: 100.5))
    }
}
