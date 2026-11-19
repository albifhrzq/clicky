import Testing
import CoreGraphics
import Foundation
@testable import Clicky

struct ClickyRegionCaptureTests {
    @Test func normalizesReverseDrag() {
        let rect = ClickyRegionGeometry.normalizedRect(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 40, y: 20))
        #expect(rect == CGRect(x: 40, y: 20, width: 60, height: 60))
    }

    @Test func rejectsTinyRects() {
        #expect(!ClickyRegionGeometry.isLargeEnough(CGRect(x: 0, y: 0, width: 7, height: 50)))
        #expect(ClickyRegionGeometry.isLargeEnough(CGRect(x: 0, y: 0, width: 8, height: 8)))
    }

    @Test func flippedViewRectMapsToGlobalOnSecondaryScreen() {
        // Secondary screen left of primary, shifted up.
        let screenFrame = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let global = ClickyRegionGeometry.globalScreenRect(
            fromFlippedViewRect: CGRect(x: 10, y: 20, width: 100, height: 50), screenFrame: screenFrame)
        #expect(global == CGRect(x: -1430, y: 1030, width: 100, height: 50))
    }

    @Test func detectsRectOutsideScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(ClickyRegionGeometry.isOutsideScreen(globalRect: CGRect(x: 200, y: 0, width: 20, height: 20), screenFrame: screenFrame))
        #expect(!ClickyRegionGeometry.isOutsideScreen(globalRect: CGRect(x: 90, y: 90, width: 50, height: 50), screenFrame: screenFrame))
    }

    @Test func queueDropsOldestBeyondCap() {
        var queue: [Int] = []
        for value in 1...6 { queue = ClickyRegionGeometry.appendingWithCap(value, to: queue) }
        #expect(queue == [3, 4, 5, 6])
    }

    @Test func dropsRegionsOlderThanTimeToLive() {
        let now = Date()
        let captureDates = [now.addingTimeInterval(-700), now.addingTimeInterval(-599), now]
        let kept = ClickyRegionGeometry.droppingExpired(captureDates, capturedAt: { $0 }, now: now)
        #expect(kept == [captureDates[1], captureDates[2]])
    }
}
