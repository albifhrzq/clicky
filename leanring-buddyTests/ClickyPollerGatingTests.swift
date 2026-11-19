import Foundation
import Testing
@testable import Clicky

@MainActor
struct ClickyPollerGatingTests {
    @Test func openCodexHealthPollRunsOnlyInOpenCodexMode() {
        for connectionMode in ClickyConnectionMode.allCases {
            let expectedToPoll = connectionMode == .openCodex
            #expect(OpenCodexService.shouldPollHealth(connectionMode: connectionMode) == expectedToPoll)
        }
    }
}
