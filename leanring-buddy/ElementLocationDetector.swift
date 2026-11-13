//
//  ElementLocationDetector.swift
//  leanring-buddy
//
//  Uses UnifiedLLMClient to identify the screen location of UI elements
//  in screenshots across OpenCodex, Antigravity OAuth, BYOK, and Worker modes.
//

import AppKit
import Foundation

/// Detects the screen location of UI elements in screenshots using `UnifiedLLMClient`.
///
/// **Aspect ratio matching**: Instead of always resizing to 1024x768 (4:3), we pick the
/// resolution closest to the display's actual aspect ratio. Most Macs are 16:10 -> 1280x800.
/// This avoids distorting the image the model sees, which improves X-axis coordinate accuracy.
@MainActor
final class ElementLocationDetector {
    private let llmClient: UnifiedLLMClient
    private let modelOverride: String?

    /// Supported downscaled resolutions paired with their aspect ratios.
    private static let supportedComputerUseResolutions: [(width: Int, height: Int, aspectRatio: Double)] = [
        (1024, 768,  1024.0 / 768.0),
        (1280, 800,  1280.0 / 800.0),
        (1366, 768,  1366.0 / 768.0)
    ]

    init(
        apiKey: String = "",
        model: String? = nil,
        llmClient: UnifiedLLMClient = .shared
    ) {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelOverride = (trimmedModel?.isEmpty == false) ? trimmedModel : nil
        self.llmClient = llmClient
    }

    /// Detects the screen location of a UI element the user is asking about.
    ///
    /// - Parameters:
    ///   - screenshotData: JPEG or PNG screenshot data from ScreenCaptureKit
    ///   - userQuestion: The user's voice transcript (e.g., "How do I add a project?")
    ///   - displayWidthInPoints: The captured display's width in screen points
    ///   - displayHeightInPoints: The captured display's height in screen points
    ///
    /// - Returns: A `CGPoint` in display-local macOS coordinates (bottom-left origin) if an
    ///   element was identified, or `nil` if no element was found or detection failed.
    func detectElementLocation(
        screenshotData: Data,
        userQuestion: String,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) async -> CGPoint? {
        // Pick the Computer Use resolution that best matches this display's aspect ratio.
        // This avoids stretching the screenshot (e.g., squishing a 16:10 Mac display
        // into 4:3), which would distort the image Claude sees and degrade X-axis accuracy.
        let computerUseResolution = bestComputerUseResolution(
            forDisplayWidth: displayWidthInPoints,
            displayHeight: displayHeightInPoints
        )

        print("🎯 ElementLocationDetector: display is \(displayWidthInPoints)x\(displayHeightInPoints) " +
              "(ratio \(String(format: "%.3f", Double(displayWidthInPoints) / Double(displayHeightInPoints)))), " +
              "using Computer Use resolution \(computerUseResolution.width)x\(computerUseResolution.height)")

        // Resize the screenshot to the chosen Computer Use resolution
        guard let resizedScreenshotData = resizeScreenshotForComputerUse(
            originalImageData: screenshotData,
            targetWidth: computerUseResolution.width,
            targetHeight: computerUseResolution.height
        ) else {
            print("⚠️ ElementLocationDetector: failed to resize screenshot")
            return nil
        }

        // Make the Computer Use API call with the matching resolution declared
        guard let computerUseCoordinate = await callComputerUseAPI(
            resizedScreenshotData: resizedScreenshotData,
            userQuestion: userQuestion,
            declaredDisplayWidth: computerUseResolution.width,
            declaredDisplayHeight: computerUseResolution.height
        ) else {
            return nil
        }

        // Clamp coordinates to the valid range — Claude occasionally returns
        // values slightly outside the declared display dimensions, which would
        // map to off-screen positions after scaling.
        let clampedX = max(0, min(computerUseCoordinate.x, CGFloat(computerUseResolution.width)))
        let clampedY = max(0, min(computerUseCoordinate.y, CGFloat(computerUseResolution.height)))

        // Scale coordinates from the Computer Use resolution back to actual display point dimensions
        let scaledX = (clampedX / CGFloat(computerUseResolution.width)) * CGFloat(displayWidthInPoints)
        let scaledYTopLeftOrigin = (clampedY / CGFloat(computerUseResolution.height)) * CGFloat(displayHeightInPoints)

        // Convert from top-left origin (Computer Use / CoreGraphics) to bottom-left origin (AppKit)
        let scaledYBottomLeftOrigin = CGFloat(displayHeightInPoints) - scaledYTopLeftOrigin

        print("🎯 ElementLocationDetector: mapped (\(Int(clampedX)), \(Int(clampedY))) in " +
              "\(computerUseResolution.width)x\(computerUseResolution.height) → " +
              "(\(Int(scaledX)), \(Int(scaledYBottomLeftOrigin))) in " +
              "\(displayWidthInPoints)x\(displayHeightInPoints) display-local AppKit coords")

        return CGPoint(x: scaledX, y: scaledYBottomLeftOrigin)
    }

    // MARK: - Private Helpers

    /// Picks the Anthropic-recommended Computer Use resolution whose aspect ratio
    /// is closest to the actual display, minimizing image distortion.
    private func bestComputerUseResolution(
        forDisplayWidth displayWidth: Int,
        displayHeight: Int
    ) -> (width: Int, height: Int) {
        let displayAspectRatio = Double(displayWidth) / Double(max(1, displayHeight))

        var bestWidth = 1280
        var bestHeight = 800
        var smallestAspectRatioDifference = Double.greatestFiniteMagnitude

        for resolution in Self.supportedComputerUseResolutions {
            let difference = abs(displayAspectRatio - resolution.aspectRatio)
            if difference < smallestAspectRatioDifference {
                smallestAspectRatioDifference = difference
                bestWidth = resolution.width
                bestHeight = resolution.height
            }
        }

        return (width: bestWidth, height: bestHeight)
    }

    /// Calls `UnifiedLLMClient` with a resized screenshot and user question.
    /// Returns the raw coordinate from the model's response in the declared resolution space, or nil.
    private func callComputerUseAPI(
        resizedScreenshotData: Data,
        userQuestion: String,
        declaredDisplayWidth: Int,
        declaredDisplayHeight: Int
    ) async -> CGPoint? {
        let systemPrompt = """
        You are a precise UI element coordinate detector.
        The attached screenshot has exact pixel dimensions \(declaredDisplayWidth)x\(declaredDisplayHeight).
        Coordinate origin (0, 0) is the top-left corner; x increases rightward (0 to \(declaredDisplayWidth)), y increases downward (0 to \(declaredDisplayHeight)).
        If the user's question refers to a specific visible UI element (button, link, menu item, text field, icon, tab, etc.), return ONLY a JSON object with its exact center pixel coordinates:
        {"x": 123, "y": 456}
        If the question is purely conceptual (e.g., "what does HTML mean?") and has no specific UI element to point at, return ONLY:
        {"x": null, "y": null}
        Do not include markdown code fences or extra explanation.
        """

        let userPrompt = """
        The user asked this question while looking at their screen: "\(userQuestion)"
        Return the target UI element center coordinate in the \(declaredDisplayWidth)x\(declaredDisplayHeight) image as JSON {"x": int, "y": int}, or {"x": null, "y": null} if there is no specific element.
        """

        let label = "Screen capture (image dimensions: \(declaredDisplayWidth)x\(declaredDisplayHeight) pixels)"

        do {
            let (responseText, _) = try await llmClient.analyzeImageStreaming(
                images: [(data: resizedScreenshotData, label: label)],
                systemPrompt: systemPrompt,
                conversationHistory: [],
                userPrompt: userPrompt,
                modelOverride: modelOverride,
                onTextChunk: { _ in }
            )
            return parseCoordinateFromResponse(text: responseText)
        } catch {
            print("⚠️ ElementLocationDetector: UnifiedLLMClient request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func parseCoordinateFromResponse(text: String) -> CGPoint? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let cleaned = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let jsonStart = cleaned.firstIndex(of: "{"),
           let jsonEnd = cleaned.lastIndex(of: "}"),
           jsonStart <= jsonEnd {
            let jsonSubstring = String(cleaned[jsonStart...jsonEnd])
            if let data = jsonSubstring.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let xNumber = obj["x"] as? NSNumber,
                   let yNumber = obj["y"] as? NSNumber {
                    let point = CGPoint(x: xNumber.doubleValue, y: yNumber.doubleValue)
                    print("🎯 ElementLocationDetector: raw coordinate (\(Int(point.x)), \(Int(point.y)))")
                    return point
                }
                if let coordinateArray = obj["coordinate"] as? [NSNumber],
                   coordinateArray.count == 2 {
                    let point = CGPoint(x: coordinateArray[0].doubleValue, y: coordinateArray[1].doubleValue)
                    print("🎯 ElementLocationDetector: raw coordinate (\(Int(point.x)), \(Int(point.y)))")
                    return point
                }
                if obj["x"] is NSNull || obj["y"] is NSNull {
                    print("🎯 ElementLocationDetector: no specific element detected (conceptual question)")
                    return nil
                }
            }
        }

        let pointPattern = #"\[POINT:(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)(?::[^\]]*)?\]"#
        if let regex = try? NSRegularExpression(pattern: pointPattern),
           let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
           let xRange = Range(match.range(at: 1), in: cleaned),
           let yRange = Range(match.range(at: 2), in: cleaned),
           let x = Double(cleaned[xRange]),
           let y = Double(cleaned[yRange]) {
            print("🎯 ElementLocationDetector: raw [POINT] coordinate (\(Int(x)), \(Int(y)))")
            return CGPoint(x: x, y: y)
        }

        print("🎯 ElementLocationDetector: no specific element detected")
        return nil
    }

    /// Resizes screenshot data to the specified Computer Use resolution.
    /// The target resolution should match the display's aspect ratio to avoid
    /// distortion that degrades coordinate accuracy.
    ///
    /// **Critical Retina fix**: Uses `NSBitmapImageRep` directly instead of
    /// `NSImage.lockFocus()`. On Retina displays (2x backing scale), lockFocus
    /// creates a bitmap at 2× the declared size (e.g., 2560×1600 for a 1280×800
    /// NSImage). This means the JPEG sent to Claude would be 2× larger than the
    /// resolution declared in the Computer Use tool definition, causing Claude's
    /// pixel-counting to return coordinates in the wrong scale.
    private func resizeScreenshotForComputerUse(
        originalImageData: Data,
        targetWidth: Int,
        targetHeight: Int
    ) -> Data? {
        guard let originalImage = NSImage(data: originalImageData) else { return nil }

        // Create a bitmap representation with exact pixel dimensions.
        // This bypasses NSImage's Retina-aware coordinate system which would
        // otherwise double the actual pixel count on 2x displays.
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        // Set the point size to match pixel dimensions (1:1, no Retina scaling).
        bitmapRep.size = NSSize(width: targetWidth, height: targetHeight)

        // Draw the original image into the exact-pixel-dimension bitmap
        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep)
        NSGraphicsContext.current = graphicsContext
        graphicsContext?.imageInterpolation = .high
        originalImage.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: originalImage.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }

        return jpegData
    }
}
