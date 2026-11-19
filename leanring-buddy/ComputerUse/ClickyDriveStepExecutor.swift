//
//  ClickyDriveStepExecutor.swift
//  leanring-buddy
//
//  The vision loop behind drive mode: screenshot → ask the model for one action →
//  perform it with ClickyAppDriver → repeat until done.
//

import AppKit
import CoreGraphics
import Foundation

/// One action the model may ask for. Coordinates are screenshot pixels.
nonisolated enum ClickyDriveAction: Equatable, Sendable {
    case click(x: Double, y: Double, button: ClickyMouseButton, count: Int)
    case type(text: String)
    case key(combo: String)
    case scroll(deltaY: Int)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case wait(seconds: Double)
    case done(summary: String)
    case fail(reason: String)
}

nonisolated enum ClickyDriveLimits {
    static let maximumActions = 25
    static let maximumDuration: TimeInterval = 180
    static let maximumConsecutiveInvalidReplies = 2
    static let maximumTypedCharacters = 500
    static let maximumWaitSeconds = 5.0
    static let maximumScrollMagnitude = 30
    static let modelCallTimeoutSeconds: TimeInterval = 30

    static func hasReachedLimit(actionsTaken: Int, elapsedSeconds: TimeInterval) -> Bool {
        actionsTaken >= maximumActions || elapsedSeconds >= maximumDuration
    }
}

nonisolated enum ClickyDriveActionParser {
    /// Tolerant: ignores fences and prose, uses the first balanced {...} object.
    static func parse(_ rawReply: String) -> ClickyDriveAction? {
        guard let jsonText = firstJSONObjectText(in: rawReply),
              let data = jsonText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let actionName = (object["action"] as? String)?.lowercased() else { return nil }

        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        func point(_ value: Any?) -> (Double, Double)? {
            guard let pair = value as? [Any], pair.count == 2,
                  let x = number(pair[0]), let y = number(pair[1]) else { return nil }
            return (x, y)
        }

        switch actionName {
        case "click":
            guard let x = number(object["x"]), let y = number(object["y"]) else { return nil }
            let button: ClickyMouseButton = (object["button"] as? String)?.lowercased() == "right" ? .right : .left
            let count = min(max(Int(number(object["count"]) ?? 1), 1), 3)
            return .click(x: x, y: y, button: button, count: count)
        case "type":
            guard let text = object["text"] as? String, !text.isEmpty else { return nil }
            return .type(text: text)
        case "key":
            guard let combo = object["combo"] as? String, !combo.isEmpty else { return nil }
            return .key(combo: combo)
        case "scroll":
            guard let deltaY = number(object["dy"]) else { return nil }
            return .scroll(deltaY: Int(deltaY))
        case "drag":
            guard let from = point(object["from"]), let to = point(object["to"]) else { return nil }
            return .drag(fromX: from.0, fromY: from.1, toX: to.0, toY: to.1)
        case "wait":
            return .wait(seconds: number(object["seconds"]) ?? 1)
        case "done":
            return .done(summary: (object["summary"] as? String) ?? "")
        case "fail":
            return .fail(reason: (object["reason"] as? String) ?? "")
        default:
            return nil
        }
    }

    /// Optional short narration the model may attach to any action. Missing or blank means silent.
    static func parseSay(_ rawReply: String) -> String? {
        guard let jsonText = firstJSONObjectText(in: rawReply),
              let data = jsonText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let say = (object["say"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !say.isEmpty else { return nil }
        return say
    }

    private static func firstJSONObjectText(in text: String) -> String? {
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var startIndex: String.Index?
        for index in text.indices {
            let character = text[index]
            if isInsideString {
                if isEscaped { isEscaped = false }
                else if character == "\\" { isEscaped = true }
                else if character == "\"" { isInsideString = false }
                continue
            }
            if character == "\"" && depth > 0 { isInsideString = true }
            else if character == "{" {
                if depth == 0 { startIndex = index }
                depth += 1
            } else if character == "}" && depth > 0 {
                depth -= 1
                if depth == 0, let startIndex { return String(text[startIndex...index]) }
            }
        }
        return nil
    }
}

/// Canonical form of a key chord: a set of modifiers plus one primary key.
nonisolated struct ClickyCanonicalKeyCombo: Equatable, Sendable {
    enum Modifier: String, CaseIterable, Sendable { case cmd, opt, ctrl, shift, fn }
    let modifiers: Set<Modifier>
    let key: String

    /// Driver-readable text, modifiers in a fixed order ("cmd+opt+x").
    var canonicalText: String {
        (Modifier.allCases.filter { modifiers.contains($0) }.map(\.rawValue) + [key]).joined(separator: "+")
    }

    private static let modifierAliases: [String: Modifier] = [
        "cmd": .cmd, "command": .cmd, "⌘": .cmd, "super": .cmd,
        "opt": .opt, "option": .opt, "alt": .opt, "⌥": .opt,
        "ctrl": .ctrl, "control": .ctrl, "^": .ctrl, "⌃": .ctrl,
        "shift": .shift, "⇧": .shift,
        "fn": .fn,
    ]
    private static let keyAliases: [String: String] = [
        "enter": "return", "backspace": "delete", "del": "delete", "esc": "escape", "spacebar": "space",
    ]

    /// nil for empty input, unknown modifier words, or a modifier used as the primary key.
    static func parse(_ rawCombo: String) -> ClickyCanonicalKeyCombo? {
        let parts = rawCombo.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard parts.count >= 1, parts.allSatisfy({ !$0.isEmpty }), let rawKey = parts.last else { return nil }
        var modifiers = Set<Modifier>()
        for word in parts.dropLast() {
            guard let modifier = modifierAliases[word] else { return nil }
            modifiers.insert(modifier)
        }
        guard modifierAliases[rawKey] == nil else { return nil }
        return ClickyCanonicalKeyCombo(modifiers: modifiers, key: keyAliases[rawKey] ?? rawKey)
    }

    var isReturnKey: Bool { key == "return" }

    /// Combos that quit apps, delete things, or open Spotlight / launchers. cmd+tab stays allowed.
    var isBlocked: Bool {
        if key == "q" && modifiers.contains(.cmd) { return true }                       // cmd+q, cmd+shift+q, ctrl+cmd+q ...
        if key == "escape" && modifiers.isSuperset(of: [.cmd, .opt]) { return true }    // force quit
        if modifiers.contains(.cmd) && (key == "delete" || key == "forwarddelete") { return true }
        if key == "space" && (modifiers.contains(.cmd) || modifiers.contains(.ctrl)) { return true } // Spotlight, input source, Finder search
        return false
    }
}

nonisolated enum ClickyDriveSafetyPolicy {
    enum KeyVerdict: Equatable, Sendable { case allowed(canonicalCombo: String), rejected }

    /// `requestText` is the user-approved step; Return/Enter is only allowed when it asks for it.
    static func evaluateKey(_ rawCombo: String, requestText: String) -> KeyVerdict {
        guard let combo = ClickyCanonicalKeyCombo.parse(rawCombo), !combo.isBlocked else { return .rejected }
        if combo.isReturnKey && !requestMentionsSubmitting(requestText) { return .rejected }
        return .allowed(canonicalCombo: combo.canonicalText)
    }

    /// Typed text may never contain line breaks (they would submit commands or forms).
    static func isTypedTextAllowed(_ text: String) -> Bool {
        !text.unicodeScalars.contains { "\n\r\u{0B}\u{0C}\u{85}\u{2028}\u{2029}".unicodeScalars.contains($0) }
    }

    static func requestMentionsSubmitting(_ requestText: String) -> Bool {
        let lowered = requestText.lowercased()
        return ["enter", "return", "submit", "send"].contains { lowered.contains($0) }
    }

    static func isSecureField(role: String?, subrole: String?) -> Bool {
        subrole == "AXSecureTextField" || (role?.contains("Secure") ?? false) || (subrole?.contains("Secure") ?? false)
    }

    /// Clicky's own windows are always fine; anything else must be the app the drive started in.
    static func isFrontmostAppAllowed(baselineBundleID: String?, currentBundleID: String?, ownBundleID: String?) -> Bool {
        if let currentBundleID, currentBundleID == ownBundleID { return true }
        return currentBundleID == baselineBundleID
    }
}

nonisolated struct ClickyDriveTimeoutError: Error {}

nonisolated enum ClickyDriveTimeout {
    /// Runs `operation`, throwing ClickyDriveTimeoutError if it takes longer than `seconds`.
    static func run<Value: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ClickyDriveTimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ClickyDriveTimeoutError() }
            return first
        }
    }
}

nonisolated enum ClickyDriveCoordinateMapper {
    /// Screenshot pixel → global CoreGraphics (top-left origin) point.
    /// `displayFrame` is the AppKit (bottom-left origin) frame of the captured screen;
    /// `primaryScreenHeight` is the height of the primary screen (the AppKit/CG flip axis).
    /// Returns nil when the pixel lies outside the screenshot.
    static func globalCoreGraphicsPoint(
        screenshotPixelX: Double,
        screenshotPixelY: Double,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        displayFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGPoint? {
        guard screenshotWidthInPixels > 0, screenshotHeightInPixels > 0,
              screenshotPixelX >= 0, screenshotPixelY >= 0,
              screenshotPixelX < Double(screenshotWidthInPixels),
              screenshotPixelY < Double(screenshotHeightInPixels) else { return nil }
        let appKitX = displayFrame.minX + CGFloat(screenshotPixelX / Double(screenshotWidthInPixels)) * displayFrame.width
        let appKitY = displayFrame.maxY - CGFloat(screenshotPixelY / Double(screenshotHeightInPixels)) * displayFrame.height
        return CGPoint(x: appKitX, y: primaryScreenHeight - appKitY)
    }
}

@MainActor
enum ClickyDriveStepExecutor {
    private static let settleDelayNanoseconds: UInt64 = 400_000_000

    private static let systemPrompt = """
    You control the user's Mac to complete ONE step. You see a screenshot of the screen the cursor is on. \
    Reply with exactly ONE JSON object and no other text:
    {"action":"click","x":..,"y":..,"button":"left","count":1}
    {"action":"type","text":".."}
    {"action":"key","combo":"cmd+t"}
    {"action":"scroll","dy":-5}
    {"action":"drag","from":[x,y],"to":[x,y]}
    {"action":"wait","seconds":1}
    {"action":"done","summary":".."}
    {"action":"fail","reason":".."}
    Any action may also carry an optional "say" string, for example {"action":"click","x":..,"y":..,"say":"Opening the settings."}. \
    It is spoken aloud: at most one short sentence, only once per group of related actions, in the user's language, and never read out ids or coordinates. Omit it otherwise. \
    When the work produced files, name their paths in the done summary.
    Coordinates are pixels in the screenshot. Do one small action at a time and check the result in the next screenshot. \
    Never type passwords or secrets. Never confirm purchases or payments, delete anything, or send messages or emails \
    unless the step explicitly says so; otherwise reply with fail and say why. Reply done as soon as the step is complete.
    """

    /// Speaks a narration line. Defaults to the shared TTS client (unprompted, system voice fallback);
    /// the integrator may replace it. Narration is best effort, so failures are ignored.
    static var narrationSpeaker: (String) -> Void = { narrationText in
        Task { try? await ElevenLabsTTSClient.shared.speakText(narrationText, allowSystemFallback: true, isUnprompted: true) }
    }

    /// Installs the executor on ClickyTakeOverController so `mac_step` and [DRIVE] can run.
    static func install() {
        ClickyTakeOverController.shared.stepExecutor = { request, driver in
            try await runLoop(request: request, driver: driver)
        }
    }

    private static func runLoop(request: TakeOverConsentRequest, driver: ClickyAppDriver) async throws -> AgentDriveOutcome {
        let startDate = Date()
        var actionDescriptions: [String] = []
        var consecutiveInvalidReplies = 0
        let ownBundleID = Bundle.main.bundleIdentifier
        var baselineBundleID = driver.frontmostApplication()?.bundleIdentifier

        func limitOutcome() -> AgentDriveOutcome? {
            guard ClickyDriveLimits.hasReachedLimit(actionsTaken: actionDescriptions.count, elapsedSeconds: Date().timeIntervalSince(startDate)) else { return nil }
            return AgentDriveOutcome(ending: .failed, summary: String(localized: "I hit my limit for one step, so I stopped there."), actions: actionDescriptions.count)
        }
        /// Stops the drive when a different app came to the front (e.g. launched by injected instructions).
        func frontmostChangeOutcome() -> AgentDriveOutcome? {
            let currentBundleID = driver.frontmostApplication()?.bundleIdentifier
            // Before the first action, the drive may start while Clicky itself is frontmost; adopt the first other app.
            if actionDescriptions.isEmpty, baselineBundleID == nil || baselineBundleID == ownBundleID, let currentBundleID, currentBundleID != ownBundleID {
                baselineBundleID = currentBundleID
            }
            guard !ClickyDriveSafetyPolicy.isFrontmostAppAllowed(baselineBundleID: baselineBundleID, currentBundleID: currentBundleID, ownBundleID: ownBundleID) else { return nil }
            return AgentDriveOutcome(ending: .failed, summary: String(localized: "I stopped because another app came to the front."), actions: actionDescriptions.count)
        }

        while true {
            try Task.checkCancellation()
            if let outcome = limitOutcome() { return outcome }
            if let outcome = frontmostChangeOutcome() { return outcome }

            guard let capture = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                .first(where: { $0.isCursorScreen }) else {
                return AgentDriveOutcome(ending: .couldNotSee, summary: String(localized: "I can't see the screen right now."), actions: actionDescriptions.count)
            }
            try Task.checkCancellation()
            if let outcome = limitOutcome() { return outcome }

            let imageData = capture.imageData
            let imageLabel = capture.label
            let promptText = userPrompt(for: request, actionDescriptions: actionDescriptions)
            let reply: String
            do {
                reply = try await ClickyDriveTimeout.run(seconds: ClickyDriveLimits.modelCallTimeoutSeconds) {
                    try await UnifiedLLMClient.shared.analyzeImageStreaming(
                        images: [(data: imageData, label: imageLabel)],
                        systemPrompt: systemPrompt,
                        userPrompt: promptText,
                        onTextChunk: { _ in }
                    ).text
                }
            } catch is ClickyDriveTimeoutError {
                return AgentDriveOutcome(ending: .failed, summary: String(localized: "The model took too long to answer, so I stopped there."), actions: actionDescriptions.count)
            }
            try Task.checkCancellation()
            if let outcome = limitOutcome() { return outcome }
            // The screen may have changed while the model was thinking.
            if let outcome = frontmostChangeOutcome() { return outcome }

            guard let action = ClickyDriveActionParser.parse(reply) else {
                consecutiveInvalidReplies += 1
                if consecutiveInvalidReplies > ClickyDriveLimits.maximumConsecutiveInvalidReplies {
                    return AgentDriveOutcome(ending: .failed, summary: String(localized: "I couldn't work out the next move, so I stopped there."), actions: actionDescriptions.count)
                }
                continue
            }

            if let narrationText = ClickyDriveActionParser.parseSay(reply) {
                narrationSpeaker(narrationText)
            }

            switch action {
            case .done(let summary):
                return AgentDriveOutcome(ending: .finished, summary: summary.isEmpty ? String(localized: "Done.") : summary, actions: actionDescriptions.count)
            case .fail(let reason):
                return AgentDriveOutcome(ending: .failed, summary: reason.isEmpty ? String(localized: "I couldn't finish that step.") : reason, actions: actionDescriptions.count)
            default:
                break
            }

            let performResult = try await perform(action, capture: capture, driver: driver, requestText: request.step)
            try Task.checkCancellation()
            switch performResult {
            case .stop(let outcome):
                return AgentDriveOutcome(ending: outcome.ending, summary: outcome.summary, actions: actionDescriptions.count)
            case .refused:
                consecutiveInvalidReplies += 1
                if consecutiveInvalidReplies > ClickyDriveLimits.maximumConsecutiveInvalidReplies {
                    return AgentDriveOutcome(ending: .failed, summary: String(localized: "I couldn't work out the next move, so I stopped there."), actions: actionDescriptions.count)
                }
            case .performed(let description):
                consecutiveInvalidReplies = 0
                actionDescriptions.append(description)
            }
            try await Task.sleep(nanoseconds: settleDelayNanoseconds)
        }
    }

    private static func userPrompt(for request: TakeOverConsentRequest, actionDescriptions: [String]) -> String {
        var lines = ["Step: \(request.step)", "Title: \(request.shortTitle)"]
        if let reason = request.reason, !reason.isEmpty { lines.append("Why: \(reason)") }
        if actionDescriptions.isEmpty {
            lines.append("Actions taken so far: none")
        } else {
            lines.append("Actions taken so far:")
            lines.append(contentsOf: actionDescriptions.enumerated().map { "\($0.offset + 1). \($0.element)" })
        }
        return lines.joined(separator: "\n")
    }

    private enum PerformResult {
        case performed(String)
        case refused
        case stop(AgentDriveOutcome)
    }

    private static func passwordFieldStop() -> PerformResult {
        .stop(AgentDriveOutcome(ending: .safetyStop, summary: String(localized: "I won't type into a password field."), actions: 0))
    }

    private static func isFocusedElementSecure(driver: ClickyAppDriver) -> Bool {
        guard let element = driver.focusedUIElement() else { return false }
        return ClickyDriveSafetyPolicy.isSecureField(role: driver.elementRole(element), subrole: driver.elementSubrole(element))
    }

    /// Performs one action. `.refused` means invalid/blocked (counts as an invalid reply); `.stop` ends the drive.
    private static func perform(_ action: ClickyDriveAction, capture: CompanionScreenCapture, driver: ClickyAppDriver, requestText: String) async throws -> PerformResult {
        func globalPoint(_ pixelX: Double, _ pixelY: Double) -> CGPoint? {
            ClickyDriveCoordinateMapper.globalCoreGraphicsPoint(
                screenshotPixelX: pixelX,
                screenshotPixelY: pixelY,
                screenshotWidthInPixels: capture.screenshotWidthInPixels,
                screenshotHeightInPixels: capture.screenshotHeightInPixels,
                displayFrame: capture.displayFrame,
                primaryScreenHeight: NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
            )
        }

        switch action {
        case .click(let x, let y, let button, let count):
            guard let point = globalPoint(x, y) else { return .refused }
            try await driver.click(at: point, button: button, clickCount: count)
            return .performed("click \(button.rawValue) x\(count) at (\(Int(x)), \(Int(y)))")
        case .type(let text):
            guard text.count <= ClickyDriveLimits.maximumTypedCharacters,
                  ClickyDriveSafetyPolicy.isTypedTextAllowed(text) else { return .refused }
            if isFocusedElementSecure(driver: driver) { return passwordFieldStop() }
            try await driver.typeText(text)
            return .performed("typed \(text.count) characters")
        case .key(let combo):
            guard case .allowed(let canonicalCombo) = ClickyDriveSafetyPolicy.evaluateKey(combo, requestText: requestText) else { return .refused }
            if isFocusedElementSecure(driver: driver) { return passwordFieldStop() }
            try await driver.pressKeyCombo(canonicalCombo)
            return .performed("pressed \(canonicalCombo)")
        case .scroll(let deltaY):
            let clampedDeltaY = min(max(deltaY, -ClickyDriveLimits.maximumScrollMagnitude), ClickyDriveLimits.maximumScrollMagnitude)
            try await driver.scroll(deltaY: Int32(clampedDeltaY))
            return .performed("scrolled \(clampedDeltaY)")
        case .drag(let fromX, let fromY, let toX, let toY):
            guard let startPoint = globalPoint(fromX, fromY), let endPoint = globalPoint(toX, toY) else { return .refused }
            try await driver.drag(from: startPoint, to: endPoint)
            return .performed("dragged (\(Int(fromX)), \(Int(fromY))) to (\(Int(toX)), \(Int(toY)))")
        case .wait(let seconds):
            let clampedSeconds = min(max(seconds, 0), ClickyDriveLimits.maximumWaitSeconds)
            try await Task.sleep(nanoseconds: UInt64(clampedSeconds * 1_000_000_000))
            return .performed("waited \(clampedSeconds)s")
        case .done, .fail:
            return .refused
        }
    }
}
