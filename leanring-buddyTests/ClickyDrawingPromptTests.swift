//
//  ClickyDrawingPromptTests.swift
//  Tests for the drawing prompt reference and the screenshot-pixel canvas size.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

@MainActor
struct ClickyDrawingPromptTests {

    // MARK: canvas size

    @Test func canvasSizeMatchesScreenshotForLandscapeScreen() {
        let size = ScreenAnnotationManager.drawingCanvasSize(forScreenSize: CGSize(width: 1728, height: 1117))
        #expect(size.width == 1280)
        #expect(size.height == CGFloat(Int(1280 / (1728.0 / 1117.0))))
    }

    @Test func canvasSizeCapsLongSideForPortraitScreen() {
        let size = ScreenAnnotationManager.drawingCanvasSize(forScreenSize: CGSize(width: 1000, height: 2000))
        #expect(size.height == 1280)
        #expect(size.width == 640)
    }

    @Test func canvasPointScalesScreenPointsToCanvasUnits() {
        let screenSize = CGSize(width: 2560, height: 1600)
        let canvasPoint = ScreenAnnotationManager.canvasPoint(fromScreenPoint: CGPoint(x: 1280, y: 800), screenSize: screenSize)
        #expect(abs(canvasPoint.x - 640) < 0.01)
        #expect(abs(canvasPoint.y - 400) < 0.01)
    }

    // MARK: prompt content

    @Test func realtimeChannelGetsNoDrawingReference() {
        #expect(ClickyDrawingPromptReference.section(for: .realtime).isEmpty)
    }

    @Test func textAndVoiceChannelsTeachTheCoordinateRule() {
        for channel in [ClickyCompanionChannel.text, .voice] {
            let section = ClickyDrawingPromptReference.section(for: channel)
            #expect(section.contains("PRIMARY FOCUS screenshot"))
            #expect(section.contains("ring(x,y,w,h"))
        }
        #expect(ClickyDrawingPromptReference.section(for: .voice).contains("spoken aloud"))
    }

    // MARK: example smoke test

    private func jsExamples(in section: String) -> [String] {
        section.components(separatedBy: "```js").dropFirst().compactMap { chunk in
            chunk.components(separatedBy: "```").first
        }
    }

    @Test func everyPromptExampleRunsWithoutErrorAndDrawsMarks() {
        let examples = jsExamples(in: ClickyDrawingPromptReference.section(for: .text))
        #expect(examples.count >= 3)

        for example in examples {
            // Arrange
            let engine = ScreenDrawingNativeEngine()
            engine.beginStream(size: CGSize(width: 1280, height: 800), displayWidthPoints: 1440, subtitles: false, inkHex: nil)

            // Act
            let analysis = engine.feed(code: example, done: true)

            // Assert
            #expect(analysis?.error == nil, "example failed: \(example)")
            #expect((analysis?.markCount ?? 0) > 0, "example drew nothing: \(example)")
        }
    }
}

struct ClickyDrawingOpenURLTests {
    @Test func onlyHttpAndHttpsWithHostAreOpenable() {
        #expect(ScreenAnnotationManager.safeOpenableURL(from: "https://example.com/a") != nil)
        #expect(ScreenAnnotationManager.safeOpenableURL(from: "http://example.com") != nil)
        #expect(ScreenAnnotationManager.safeOpenableURL(from: "file:///etc/passwd") == nil)
        #expect(ScreenAnnotationManager.safeOpenableURL(from: "javascript:alert(1)") == nil)
        #expect(ScreenAnnotationManager.safeOpenableURL(from: "https://") == nil)
        #expect(ScreenAnnotationManager.safeOpenableURL(from: "x-apple.systempreferences:") == nil)
    }
}
