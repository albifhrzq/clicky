import CoreGraphics
import Testing
@testable import Clicky

struct ClickyThreeStageTests {
    @Test func idleStageDoesNotRenderContinuously() {
        let demand = ClickyThreeRenderDemand(hasActiveTicks: false, hasRunningMotions: false, isAutoSpinning: false, isUserInteracting: false, isAnimating: false)
        #expect(!demand.needsContinuousRendering)
    }

    @Test func anyMovementRequestsContinuousRendering() {
        #expect(ClickyThreeRenderDemand(hasActiveTicks: true, hasRunningMotions: false, isAutoSpinning: false, isUserInteracting: false, isAnimating: false).needsContinuousRendering)
        #expect(ClickyThreeRenderDemand(hasActiveTicks: false, hasRunningMotions: false, isAutoSpinning: false, isUserInteracting: true, isAnimating: false).needsContinuousRendering)
        #expect(ClickyThreeRenderDemand(hasActiveTicks: false, hasRunningMotions: false, isAutoSpinning: false, isUserInteracting: false, isAnimating: true).needsContinuousRendering)
    }

    @Test func autoSpinStopsAfterSixSecondsOrWhileDragging() {
        #expect(ClickyThreeRenderDemand.isAutoSpinActive(spinRate: 0.1, secondsSinceAppeared: 2, isDragging: false))
        #expect(!ClickyThreeRenderDemand.isAutoSpinActive(spinRate: 0.1, secondsSinceAppeared: 6.5, isDragging: false))
        #expect(!ClickyThreeRenderDemand.isAutoSpinActive(spinRate: 0.1, secondsSinceAppeared: 1, isDragging: true))
        #expect(!ClickyThreeRenderDemand.isAutoSpinActive(spinRate: 0, secondsSinceAppeared: 1, isDragging: false))
    }

    @Test func zoomIsClamped() {
        #expect(ClickyThreeZoom.clamped(100) == ClickyThreeZoom.maximumUserZoom)
        #expect(ClickyThreeZoom.clamped(0.001) == ClickyThreeZoom.minimumUserZoom)
        #expect(ClickyThreeZoom.clamped(.nan) == 1)
        #expect(ClickyThreeZoom.scrollFactor(deltaY: 5, isPrecise: true) > 1)
        #expect(ClickyThreeZoom.scrollFactor(deltaY: -5, isPrecise: true) < 1)
        #expect(ClickyThreeZoom.magnifyFactor(magnification: 0.2) > 1)
        #expect(ClickyThreeZoom.magnifyFactor(magnification: -5) > 0)
    }

    @Test func labelDeltaIgnoresSubPixelMovement() {
        let first = [ClickyThreeLabelPoint(id: "a", point: CGPoint(x: 10, y: 10))]
        let nudged = [ClickyThreeLabelPoint(id: "a", point: CGPoint(x: 10.3, y: 10.2))]
        let moved = [ClickyThreeLabelPoint(id: "a", point: CGPoint(x: 11, y: 10))]
        #expect(ClickyThreeLabelProjectionDelta.hasMeaningfulChange(previous: nil, current: first))
        #expect(!ClickyThreeLabelProjectionDelta.hasMeaningfulChange(previous: first, current: nudged))
        #expect(ClickyThreeLabelProjectionDelta.hasMeaningfulChange(previous: first, current: moved))
        #expect(ClickyThreeLabelProjectionDelta.hasMeaningfulChange(previous: first, current: []))
    }

    @Test func leftLabelFlipsRightWhenItWouldCrossTheEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let result = ClickyLabelPlacement.place(point: CGPoint(x: 30, y: 100), side: "left", labelSize: CGSize(width: 80, height: 20), visibleBounds: bounds)
        #expect(result.side == "right")
        #expect(result.anchorX >= 6)
    }

    @Test func labelIsClampedInsideBoundsVertically() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let result = ClickyLabelPlacement.place(point: CGPoint(x: 200, y: 400), side: nil, labelSize: CGSize(width: 60, height: 20), visibleBounds: bounds)
        #expect(result.centerY <= 300 - 6 - 10)
    }

    @Test func labelThatFitsIsUnchanged() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let result = ClickyLabelPlacement.place(point: CGPoint(x: 200, y: 150), side: "right", labelSize: CGSize(width: 60, height: 20), visibleBounds: bounds)
        #expect(result.side == "right")
        #expect(result.anchorX == 212)
        #expect(result.centerY == 150)
    }
}
