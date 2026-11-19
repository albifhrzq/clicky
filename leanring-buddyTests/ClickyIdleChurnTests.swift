import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct ClickyIdleChurnTests {
    @Test func pollsSlowlyOnlyWhenAllPermissionsGranted() {
        #expect(ClickyIdleChurnRules.permissionPollInterval(allPermissionsGranted: true) == 3.0)
        #expect(ClickyIdleChurnRules.permissionPollInterval(allPermissionsGranted: false) == 1.5)
    }

    @Test func ignoresAudioLevelChangesWithinThreshold() {
        #expect(!ClickyIdleChurnRules.shouldPublishAudioLevel(current: 0.5, next: 0.505))
        #expect(ClickyIdleChurnRules.shouldPublishAudioLevel(current: 0.5, next: 0.52))
    }

    @Test func settlesToExactlyZeroOnceThenStopsPublishing() {
        let settled = ClickyIdleChurnRules.settledAudioLevel(0.005)
        #expect(settled == 0)
        #expect(ClickyIdleChurnRules.shouldPublishAudioLevel(current: 0.008, next: settled))
        #expect(!ClickyIdleChurnRules.shouldPublishAudioLevel(current: 0, next: 0))
    }
}
