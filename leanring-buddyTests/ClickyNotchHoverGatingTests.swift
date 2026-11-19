import CoreGraphics
import Testing
@testable import Clicky

struct ClickyNotchHoverGatingTests {
    private let hotZoneRect = CGRect(x: 100, y: 900, width: 200, height: 40)

    @Test func skipsRefreshWhenCollapsedAndPointerFarAway() {
        let shouldRefresh = NotchWindowManager.shouldRefreshNotchPassThrough(
            pointerLocation: CGPoint(x: 50, y: 100), hotZoneRect: .null, wasInsideHotZone: false, isPanelExpanded: false)
        #expect(shouldRefresh == false)
    }

    @Test func refreshesWhenPointerInsideHotZone() {
        let shouldRefresh = NotchWindowManager.shouldRefreshNotchPassThrough(
            pointerLocation: CGPoint(x: 150, y: 910), hotZoneRect: hotZoneRect, wasInsideHotZone: false, isPanelExpanded: false)
        #expect(shouldRefresh == true)
    }

    @Test func refreshesOnceWhenPointerJustLeftHotZone() {
        let shouldRefresh = NotchWindowManager.shouldRefreshNotchPassThrough(
            pointerLocation: CGPoint(x: 50, y: 100), hotZoneRect: .null, wasInsideHotZone: true, isPanelExpanded: false)
        #expect(shouldRefresh == true)
    }

    @Test func alwaysRefreshesWhenPanelExpanded() {
        let shouldRefresh = NotchWindowManager.shouldRefreshNotchPassThrough(
            pointerLocation: CGPoint(x: 50, y: 100), hotZoneRect: .null, wasInsideHotZone: false, isPanelExpanded: true)
        #expect(shouldRefresh == true)
    }
}

struct ClickyNotchCanvasGeometryTests {
    private let largestPanelSize = CGSize(width: 800, height: 648)

    private func makeNonNotchGeometry(screenFrame: CGRect) -> NotchScreenGeometry {
        let restingPillRect = CGRect(x: screenFrame.midX - 78, y: screenFrame.maxY - 22, width: 156, height: 22)
        let activityPillRect = CGRect(x: screenFrame.midX - 124, y: screenFrame.maxY - 40, width: 248, height: 34)
        return NotchScreenGeometry(
            displayID: 1,
            screenFrame: screenFrame,
            visibleFrame: screenFrame,
            hasHardwareNotch: false,
            hardwareNotchRect: restingPillRect,
            restingPillRect: restingPillRect,
            activityPillRect: activityPillRect
        )
    }

    @Test func canvasIsCenteredAndFlushWithTopOnLargeScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let canvasRect = NotchScreenGeometry.canvasRect(
            anchorMidX: screenFrame.midX, screenFrame: screenFrame, maximumPanelSize: largestPanelSize)
        #expect(canvasRect == CGRect(x: 528, y: 388, width: 864, height: 692))
        #expect(canvasRect.maxY == screenFrame.maxY)
        #expect(canvasRect.midX == screenFrame.midX)
    }

    @Test func canvasIsClampedInsideTinyScreen() {
        let screenFrame = CGRect(x: 100, y: 50, width: 700, height: 500)
        let canvasRect = NotchScreenGeometry.canvasRect(
            anchorMidX: screenFrame.midX, screenFrame: screenFrame, maximumPanelSize: largestPanelSize)
        #expect(canvasRect == screenFrame)
    }

    @Test func canvasShiftsInsideScreenWhenAnchorIsNearEdge() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let canvasRect = NotchScreenGeometry.canvasRect(
            anchorMidX: 50, screenFrame: screenFrame, maximumPanelSize: largestPanelSize)
        #expect(canvasRect.minX == 0)
        #expect(canvasRect.width == 864)
    }

    @Test func canvasContainsLargestExpandedPanelOnNonNotchDisplay() {
        let geometry = makeNonNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let expandedPanelRect = geometry.expandedPanelRect(for: largestPanelSize)
        #expect(geometry.canvasRect.contains(expandedPanelRect))
    }

    @Test func nonNotchExpandedPanelIsFlushWithTopEdge() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let geometry = makeNonNotchGeometry(screenFrame: screenFrame)
        #expect(geometry.expandedPanelRect(for: CGSize(width: 516, height: 400)).maxY == screenFrame.maxY)
    }

    @Test func interactiveRectFollowsPanelState() {
        let geometry = makeNonNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let expandedContentSize = CGSize(width: 516, height: 400)
        #expect(geometry.interactiveRect(isExpanded: true, isActivityPillVisible: true, expandedContentSize: expandedContentSize)
            == geometry.expandedPanelRect(for: expandedContentSize))
        #expect(geometry.interactiveRect(isExpanded: false, isActivityPillVisible: true, expandedContentSize: expandedContentSize)
            == geometry.activityPillRect)
        #expect(geometry.interactiveRect(isExpanded: false, isActivityPillVisible: false, expandedContentSize: expandedContentSize)
            == geometry.restingPillRect)
    }
}
