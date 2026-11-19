import CoreGraphics
import Testing
@testable import Clicky

struct ClickyDrawingPinTests {

    @Test func pinnedTransformPlacesCardTopRightWithMargin() {
        // Arrange
        let box = CGRect(x: 200, y: 100, width: 400, height: 300)
        let scale: CGFloat = 0.35

        // Act
        let transform = ScreenAnnotationManager.pinnedCardTransform(box: box, canvasWidth: 1440, stackOffsetY: 0)

        // Assert: the scaled box's right edge sits 16pt from the canvas edge, top edge 16pt from the top.
        let scaledRight = box.maxX * scale + CGFloat(transform[1])
        let scaledTop = box.minY * scale + CGFloat(transform[2])
        #expect(transform[0] == Double(scale))
        #expect(abs(scaledRight - (1440 - 16)) < 0.001)
        #expect(abs(scaledTop - 16) < 0.001)
    }

    @Test func pinnedTransformStacksBelowEarlierPinnedCards() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)

        let first = ScreenAnnotationManager.pinnedCardTransform(box: box, canvasWidth: 1000, stackOffsetY: 0)
        let second = ScreenAnnotationManager.pinnedCardTransform(box: box, canvasWidth: 1000, stackOffsetY: 47)

        #expect(abs((second[2] - first[2]) - 47) < 0.001)
        #expect(second[1] == first[1])
    }
}
