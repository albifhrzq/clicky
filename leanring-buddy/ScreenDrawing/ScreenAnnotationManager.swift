//
//  ScreenAnnotationManager.swift
//  leanring-buddy
//
//  Manages the full-screen transparent annotation overlay window, extracts JS
//  drawing code blocks from LLM responses, feeds ScreenDrawingNativeEngine,
//  renders GuidedClickTarget rings, detects click/hover completion, and
//  handles screen-change cancellation.
//

import AppKit
import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Guided Click Target

public struct GuidedClickTarget: Identifiable, Sendable {
    public let id: String
    public let markIndex: Int
    public let role: String // "target" | "hover"
    public let center: CGPoint // canvas coordinates
    public let radius: CGFloat
    public let box: CGRect?
    public let label: String?
    public let lineIndex: Int
}

// MARK: - Transparent Overlay Panel

private final class ScreenDrawingOverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - ScreenAnnotationManager

@MainActor
public final class ScreenAnnotationManager: ObservableObject {
    public static let shared = ScreenAnnotationManager()

    @Published public private(set) var isActive: Bool = false
    @Published public private(set) var activeTargets: [GuidedClickTarget] = []
    @Published public private(set) var latestCaption: ClickyCaptionState?
    /// True while the drawing's pen cursor is moving; the floating buddy hides so only one cursor shows.
    @Published public private(set) var isPenDrawing: Bool = false
    /// Set by CompanionManager: true while Clicky is listening, thinking or speaking.
    @Published public private(set) var isCompanionBusy: Bool = false
    private weak var clearButtonHost: NSView?
    private var clearButtonVisibilityCancellable: AnyCancellable?
    @Published public private(set) var lastCompletedTarget: GuidedClickTarget?

    /// Progress of "Save as Video", shown by the save-offer card.
    @Published public private(set) var recordingState: ClickyDrawingRecordingState = .idle

    public var onGuidedTargetCompleted: ((GuidedClickTarget) -> Void)?
    public var onAskFollowUp: ((String) -> Void)?
    public var onHandOffRequested: (([String: Any]) -> Void)?
    public var onScreenChangeCancelled: (() -> Void)?

    /// When the drawing last finished animating; nil if it has not finished yet.
    private var drawingFinishedAtMediaTime: CFTimeInterval?

    public let engine = ScreenDrawingNativeEngine()

    private var overlayPanel: ScreenDrawingOverlayPanel?
    private var canvasView: ScreenDrawingCanvasView?
    private var targetRingContainerLayer: CALayer?
    private var activeScreen: NSScreen?

    private var globalClickMonitor: Any?
    private var globalMouseMoveMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    private var currentStreamCode: String = ""
    private var currentStreamDone: Bool = false
    private var targetShowTimestamp: CFTimeInterval = 0
    private var completedTargetIDs = Set<String>()
    private var lastCardSyncCount: Int = -1

    /// Program of earlier turns kept on the cards by `continueStream`; replay code is this + current turn.
    private var earlierTurnsReplayCode: String = ""

    /// Full program on screen now (earlier continued turns + current turn). Stored in Home → Drawings for replay.
    public var currentReplayProgram: String {
        earlierTurnsReplayCode.isEmpty ? currentStreamCode : earlierTurnsReplayCode + "\n" + currentStreamCode
    }

    /// Title of the first window card on screen, when the drawing has one.
    public var currentDrawingTitle: String? {
        engine.currentCards().compactMap { $0.windowChrome?.title }.first { !$0.isEmpty }
    }

    /// Window number of the drawing overlay while a drawing is on screen, so screenshots can keep it
    /// (the model must see what it drew) while still hiding Clicky's other windows.
    public var drawingOverlayWindowNumber: Int? {
        guard isActive, let overlayPanel, overlayPanel.isVisible else { return nil }
        return overlayPanel.windowNumber
    }

    /// The drawing on screen right now (title + program), for the model's context. Nil when nothing is drawn.
    public var currentDrawingSummary: (title: String, code: String)? {
        guard isActive else { return nil }
        let program = currentReplayProgram.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !program.isEmpty else { return nil }
        return (title: currentDrawingTitle ?? String(localized: "Drawing"), code: program)
    }

    /// Height reserved in the pinned stack per pinned card, keyed by `card.marks.first`
    /// (`card.id` changes whenever the card moves, so it cannot be the key). Insertion order is stack order.
    private var pinnedStackHeightsByCardMark: [(cardMark: Int, stackHeight: CGFloat)] = []

    private let videoRecorder = ClickyDrawingVideoRecorder()
    private var isSavingVideo = false

    /// Set when the engine starts drawing so the next "finished" edge means a real drawing ended (not a clear()).
    private var hasSeenDrawingStart = false
    private var drawingStartedAtMediaTime: CFTimeInterval = 0
    private var lastObservedDrawingDurationSeconds: TimeInterval = 0
    private var whiteboardPanel: ClickyDrawingWhiteboardPanel?

    // MARK: - Pin Layout (pure, unit-tested)

    nonisolated public static let pinnedCardScale: CGFloat = 0.35
    nonisolated public static let pinnedCardScreenMargin: CGFloat = 16
    nonisolated public static let pinnedCardStackGap: CGFloat = 12

    /// Transform `[scale, tx, ty]` (as `zoomCard(marks:to:)` expects) that parks a card in the top-right corner,
    /// below `stackOffsetY` of already pinned cards. `box` is the card's box BEFORE zoom, in canvas coordinates
    /// (top-left origin, y down); the engine scales around the canvas origin, so the box's own offset is compensated.
    nonisolated public static func pinnedCardTransform(
        box: CGRect,
        canvasWidth: CGFloat,
        stackOffsetY: CGFloat,
        scale: CGFloat = pinnedCardScale,
        margin: CGFloat = pinnedCardScreenMargin
    ) -> [Double] {
        let translationX = canvasWidth - margin - box.width * scale - box.minX * scale
        let translationY = margin + stackOffsetY - box.minY * scale
        return [Double(scale), Double(translationX), Double(translationY)]
    }

    private init() {
        // Full-screen overlay: a 3D figure stands on its own draggable window card instead of floating over the
        // screen. The screen is not sampled, so report it as busy so the engine always gives figures a card.
        engine.figuresFloat = false
        engine.busynessSampler = { _ in 1.0 }
        wireEngineCallbacks()
        observeDrawingCompletion()
        installWorkspaceObservers()
    }

    // MARK: - Canvas Units (screenshot pixels)

    /// Longest side of the screenshots sent to the model (CompanionScreenCaptureUtility's maxDimension).
    nonisolated public static let screenshotMaxDimension: CGFloat = 1280

    /// Size of the drawing canvas for a screen: the same pixel size as that screen's screenshot (same aspect,
    /// long side capped at 1280), so coordinates the model reads off the screenshot can be drawn directly.
    nonisolated public static func drawingCanvasSize(forScreenSize screenSize: CGSize) -> CGSize {
        guard screenSize.width > 0, screenSize.height > 0 else {
            return CGSize(width: screenshotMaxDimension, height: screenshotMaxDimension * 0.625)
        }
        let aspectRatio = screenSize.width / screenSize.height
        if screenSize.width >= screenSize.height {
            return CGSize(width: screenshotMaxDimension, height: CGFloat(Int(screenshotMaxDimension / aspectRatio)))
        }
        return CGSize(width: CGFloat(Int(screenshotMaxDimension * aspectRatio)), height: screenshotMaxDimension)
    }

    /// Converts a point in screen points (top-left origin, y down) to canvas units.
    nonisolated public static func canvasPoint(fromScreenPoint screenPoint: CGPoint, screenSize: CGSize) -> CGPoint {
        let canvasSize = drawingCanvasSize(forScreenSize: screenSize)
        return CGPoint(
            x: screenPoint.x * canvasSize.width / max(1, screenSize.width),
            y: screenPoint.y * canvasSize.height / max(1, screenSize.height)
        )
    }

    private func activeCanvasSize(for screen: NSScreen) -> CGSize {
        Self.drawingCanvasSize(forScreenSize: screen.frame.size)
    }

    // MARK: - Public Execution & Streaming API

    /// Executes a complete JS drawing program immediately on the target (or main) screen.
    public func executeDrawingProgram(_ script: String, on screen: NSScreen? = nil, subtitles: Bool = false) {
        let extracted = Self.extractDrawingCode(from: script) ?? script
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else { return }

        ensureOverlay(for: targetScreen)
        currentStreamCode = trimmed
        currentStreamDone = true
        earlierTurnsReplayCode = ""
        completedTargetIDs.removeAll()
        // The canvas may be reconfigured for a different screen/size: drop stale pins and rings.
        pinnedStackHeightsByCardMark.removeAll()
        activeTargets = []
        clearTargetRings()

        let size = activeCanvasSize(for: targetScreen)
        canvasView?.configureCanvas(size: size, inkHex: currentInkHex())
        engine.beginStream(size: size, displayWidthPoints: targetScreen.frame.width, subtitles: subtitles, inkHex: currentInkHex())

        if let analysis = engine.feed(code: trimmed, done: true) {
            handleAnalysisUpdate(analysis)
        }
        engine.finish()
        syncCardsToCanvas()
        isActive = true
    }

    /// Starts an incremental streaming drawing session (for live LLM token chunks).
    public func beginStreamingProgram(on screen: NSScreen? = nil, subtitles: Bool = false) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else { return }

        ensureOverlay(for: targetScreen)
        currentStreamCode = ""
        currentStreamDone = false
        earlierTurnsReplayCode = ""
        completedTargetIDs.removeAll()
        // The canvas may be reconfigured for a different screen/size: drop stale pins and rings.
        pinnedStackHeightsByCardMark.removeAll()
        activeTargets = []
        clearTargetRings()

        let size = activeCanvasSize(for: targetScreen)
        canvasView?.configureCanvas(size: size, inkHex: currentInkHex())
        engine.beginStream(size: size, displayWidthPoints: targetScreen.frame.width, subtitles: subtitles, inkHex: currentInkHex())
        isActive = true
    }

    /// Feeds either raw JS or full/partial markdown LLM response text incrementally.
    @discardableResult
    public func feedStreamingResponse(_ responseText: String, done: Bool) -> ClickyDrawingAnalysis? {
        guard let extracted = Self.extractDrawingCode(from: responseText, allowUnclosedFence: !done) else {
            return nil
        }
        if !isActive {
            print("🎨 Drawing: the reply contains a drawing, starting it")
            beginStreamingProgram()
        }
        if extracted == currentStreamCode && done == currentStreamDone {
            return engine.latestAnalysis
        }
        // Chunks of one response only ever extend the same code, and the response ends with done == true. So once the
        // previous stream is done, any different code is a NEW response. The finished JS session would drop it
        // (`if (doneSeen) return []`), so continue the session: cards stay, the new turn draws on top.
        if currentStreamDone && extracted != currentStreamCode {
            continueFinishedStreamForNewResponse()
        }
        currentStreamCode = extracted
        currentStreamDone = done

        let analysis = engine.feed(code: extracted, done: done)
        if let drawingEngineError = engine.latestError {
            print("🎨 Drawing: engine error after feed: \(drawingEngineError)")
        }
        if let analysis {
            handleAnalysisUpdate(analysis)
        }
        if done {
            engine.finish()
            syncCardsToCanvas()
        }
        return analysis
    }

    private func continueFinishedStreamForNewResponse() {
        let screenSubtitles = false
        guard let continuation = engine.continueStream(subtitles: screenSubtitles) else {
            // The JS session is gone (nothing to continue): start a fresh one instead of silently dropping the drawing.
            beginStreamingProgram(on: activeScreen)
            return
        }
        earlierTurnsReplayCode = continuation.code
        currentStreamCode = ""
        currentStreamDone = false
        completedTargetIDs.removeAll()
        activeTargets = []
        clearTargetRings()
    }

    public func notifySpeechLineStarted(_ lineIndex: Int) {
        engine.markLineStarted(lineIndex)
    }

    public func notifySpeechLineLength(_ lineIndex: Int, seconds: Double) {
        engine.setLineLength(lineIndex, seconds: seconds)
    }

    /// Clears all annotations, 3D stages, interactive buttons, and target rings.
    public func clearAll() {
        hasSeenDrawingStart = false
        engine.clear()
        canvasView?.clearAll()
        clearTargetRings()
        activeTargets = []
        completedTargetIDs.removeAll()
        currentStreamCode = ""
        currentStreamDone = false
        earlierTurnsReplayCode = ""
        pinnedStackHeightsByCardMark.removeAll()
        lastCardSyncCount = -1
        isActive = false
        teardownOverlay()
    }

    /// Like `clearAll()` but keeps the overlay panel alive (used before replaying a drawing for recording).
    private func clearKeepingOverlay() {
        hasSeenDrawingStart = false
        engine.clear()
        canvasView?.clearAll()
        clearTargetRings()
        activeTargets = []
        completedTargetIDs.removeAll()
        currentStreamCode = ""
        currentStreamDone = false
        earlierTurnsReplayCode = ""
        pinnedStackHeightsByCardMark.removeAll()
        lastCardSyncCount = -1
    }

    // MARK: - Save as Video

    /// Replays the current drawing on a cleared overlay while recording the screen, then saves an .mp4 to Downloads.
    /// The saved file is not revealed automatically; the save-offer card offers "Show the video in Finder".
    public func saveCurrentDrawingAsVideo() {
        guard !isSavingVideo else { return }
        let replayProgram = currentReplayProgram
        guard !replayProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let screen = activeScreen, let overlayPanel else { return }

        isSavingVideo = true
        recordingState = .recording(elapsedSeconds: 0, totalSeconds: lastObservedDrawingDurationSeconds)
        let overlayWindowID = CGWindowID(overlayPanel.windowNumber)
        let outputURL = Self.videoOutputURL()

        Task { @MainActor in
            defer { self.isSavingVideo = false }
            var hasClearedDrawing = false
            do {
                // Start the recorder BEFORE clearing: if it throws (e.g. missing screen-recording
                // permission) the user's drawing must stay intact.
                try await self.videoRecorder.start(recording: screen, overlayWindowID: overlayWindowID, to: outputURL)
                self.clearKeepingOverlay()
                hasClearedDrawing = true
                self.executeDrawingProgram(replayProgram, on: screen)
                await self.waitForReplayToFinish()
                self.recordingState = .saving
                let savedURL = try await self.videoRecorder.stop()
                self.recordingState = .saved(savedURL)
            } catch {
                print("⚠️ ScreenAnnotationManager: save as video failed: \(error)")
                if self.videoRecorder.isRecording {
                    _ = try? await self.videoRecorder.stop()
                }
                if hasClearedDrawing {
                    // The replay was interrupted; bring the user's drawing back.
                    self.clearKeepingOverlay()
                    self.executeDrawingProgram(replayProgram, on: screen)
                }
                self.recordingState = .failed(error.localizedDescription)
                Self.showVideoErrorAlert(error)
            }
        }
    }

    /// Reveals the video saved by the last "Save drawing" in Finder.
    public func revealSavedVideoInFinder() {
        guard case .saved(let savedURL) = recordingState else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    /// Back to idle once the save-offer card is dismissed.
    public func resetRecordingState() {
        guard !isSavingVideo else { return }
        recordingState = .idle
    }

    private static let videoReplayHardCapSeconds: TimeInterval = 60
    private static let videoReplayTailSeconds: TimeInterval = 1.5
    private static let videoReplayStartGraceSeconds: TimeInterval = 1.0

    /// Waits for `engine.isFinished` to go false -> true (drawing animation done), plus a short tail, capped at 60s.
    private func waitForReplayToFinish() async {
        let startTime = CACurrentMediaTime()
        var hasSeenDrawing = false
        while CACurrentMediaTime() - startTime < Self.videoReplayHardCapSeconds {
            if !engine.isFinished {
                hasSeenDrawing = true
            } else if hasSeenDrawing || CACurrentMediaTime() - startTime > Self.videoReplayStartGraceSeconds {
                // Finished after drawing, or a drawing so short it never showed as unfinished.
                break
            }
            let elapsedSeconds = CACurrentMediaTime() - startTime
            recordingState = .recording(
                elapsedSeconds: elapsedSeconds,
                totalSeconds: max(elapsedSeconds, lastObservedDrawingDurationSeconds + Self.videoReplayTailSeconds)
            )
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.videoReplayTailSeconds * 1_000_000_000))
    }

    private static func videoOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloadsDirectory.appendingPathComponent("Clicky drawing \(formatter.string(from: Date())).mp4")
    }

    private static func showVideoErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not save the drawing as video"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Drops screen-pointing marks when the underlying app/screen changes.
    public func handleScreenChanged(reason: String = "app") {
        guard isActive, !isSavingVideo else { return }

        let secondsSinceFinished = drawingFinishedAtMediaTime.map { CACurrentMediaTime() - $0 }
        guard ScreenDrawingClearPolicy.shouldClearOnScreenChange(
            isStreaming: engine.isStreaming,
            secondsSinceFinished: secondsSinceFinished,
            isVoiceTurnActive: isCompanionBusy
        ) else {
            print("🎨 Drawing: ignored \(reason) change while drawing")
            return
        }

        if !engine.isFinished {
            let res = engine.dropPointing()
            if (res?.left ?? 0) == 0 {
                print("🎨 Drawing: cleared because the \(reason) changed")
                clearAll()
                onScreenChangeCancelled?()
                return
            }
        } else {
            let res = engine.keepNotesOnly()
            if (res?.kept ?? 0) == 0 {
                print("🎨 Drawing: cleared because the \(reason) changed")
                clearAll()
                onScreenChangeCancelled?()
                return
            }
        }

        print("🎨 Drawing: cleared guided targets because the \(reason) changed")
        // Clear guided targets tied to the previous screen
        activeTargets.removeAll()
        clearTargetRings()
        syncCardsToCanvas()
        onScreenChangeCancelled?()
    }

    // MARK: - Code Block Extraction

    /// Extracts the drawing JavaScript code block from an LLM response (` ```js ... ``` `).
    public static func extractDrawingCode(from response: String, allowUnclosedFence: Bool = true) -> String? {
        let patterns = [
            "```(?:js|javascript|draw)\\s*\\n([\\s\\S]*?)```",
            "```\\s*\\n([\\s\\S]*?)```"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: response) {
                return String(response[range])
            }
        }

        if allowUnclosedFence,
           let openRegex = try? NSRegularExpression(pattern: "```(?:js|javascript|draw)?\\s*\\n([\\s\\S]*)$", options: [.caseInsensitive]),
           let match = openRegex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: response) {
            return String(response[range])
        }
        return nil
    }

    // MARK: - Overlay Lifecycle & Monitors

    private func ensureOverlay(for screen: NSScreen) {
        if let overlayPanel, activeScreen?.frame == screen.frame {
            overlayPanel.orderFrontRegardless()
            installEventMonitorsIfNeeded()
            return
        }

        teardownOverlay()
        activeScreen = screen

        let panel = ScreenDrawingOverlayPanel(screen: screen)
        // Lets the cursor buddy keep following while the pointer is over an interactive drawing card.
        panel.acceptsMouseMovedEvents = true
        let canvas = ScreenDrawingCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.configureCanvas(size: activeCanvasSize(for: screen))
        canvas.autoresizingMask = [.width, .height]

        canvas.onActionButtonPressed = { [weak self] payload in
            self?.handleActionButtonPressed(payload)
        }
        canvas.onCardCloseRequested = { [weak self] card in
            guard let self else { return }
            let result = self.engine.closeCard(marks: card.marks)
            self.syncCardsToCanvas()
            self.pinnedStackHeightsByCardMark.removeAll { $0.cardMark == card.marks.first }
            if (result?.left ?? 0) == 0 {
                self.clearAll()
            }
        }
        canvas.onCardZoomRequested = { [weak self] card in
            guard let self, let screen = self.activeScreen else { return }
            let isZoomed = card.windowChrome?.isZoomed ?? false
            if isZoomed {
                // Green button doubles as unpin for pinned cards.
                self.pinnedStackHeightsByCardMark.removeAll { $0.cardMark == card.marks.first }
                self.engine.zoomCard(marks: card.marks, to: nil)
            } else {
                self.engine.zoomCard(marks: card.marks, to: Self.bigCardTransform(box: card.box, screenSize: activeCanvasSize(for: screen)))
            }
            self.syncCardsToCanvas()
        }
        canvas.onCardPinRequested = { [weak self] card in
            // The handle view that fired this may be removed when cards re-sync, so act on the next turn.
            DispatchQueue.main.async { [weak self] in
                self?.pinCardToSide(card)
            }
        }
        canvas.onCardShowBigRequested = { [weak self] card in
            DispatchQueue.main.async { [weak self] in
                self?.showPinnedCardBig(card)
            }
        }
        canvas.onSaveAsVideoRequested = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.saveCurrentDrawingAsVideo()
            }
        }
        canvas.onCardMoved = { [weak self] card, delta in
            self?.engine.moveCard(marks: card.marks, dx: Double(delta.x), dy: Double(delta.y))
            self?.syncCardsToCanvas()
        }
        canvas.onTick3DRequested = { [weak self] stageID, ticks, dt in
            self?.engine.tick3D(stageID: stageID, ticks: ticks, dt: dt)
        }
        canvas.onPenDrawingChanged = { [weak self] isPenDrawing in
            if self?.isPenDrawing != isPenDrawing { self?.isPenDrawing = isPenDrawing }
        }
        let clearButtonHost = makeClearButtonHost(canvasBounds: canvas.bounds)
        canvas.addPersistentControl(clearButtonHost)
        self.clearButtonHost = clearButtonHost
        bindClearButtonVisibility()

        let ringLayer = CALayer()
        ringLayer.frame = canvas.bounds
        ringLayer.masksToBounds = false
        canvas.layer?.addSublayer(ringLayer)

        panel.contentView = canvas
        panel.orderFrontRegardless()

        self.overlayPanel = panel
        self.canvasView = canvas
        self.targetRingContainerLayer = ringLayer

        installEventMonitorsIfNeeded()
    }

    public func setCompanionBusy(_ isBusy: Bool) {
        if isCompanionBusy != isBusy { isCompanionBusy = isBusy }
    }

    /// Top-center "Clear" pill under the menu bar, as in the official app. Starts invisible.
    private func makeClearButtonHost(canvasBounds: CGRect) -> NSView {
        let hostSize = CGSize(width: 110, height: 36)
        let distanceFromTopOfScreen: CGFloat = 44
        let host = NSHostingView(rootView: ClickyDrawingClearButton(manager: self))
        // The canvas is flipped (y grows down), so the top edge is minY.
        host.frame = CGRect(
            x: canvasBounds.midX - hostSize.width / 2,
            y: canvasBounds.minY + distanceFromTopOfScreen,
            width: hostSize.width,
            height: hostSize.height
        )
        // alphaValue (not SwiftUI opacity) so the canvas hit test ignores it while invisible.
        host.alphaValue = 0
        return host
    }

    /// The pill appears once the drawing is finished and Clicky has stopped speaking; at that moment
    /// the pen cursor also hands back to the floating buddy.
    private func bindClearButtonVisibility() {
        clearButtonVisibilityCancellable = engine.$isFinished
            .combineLatest(engine.$isStreaming, $isCompanionBusy, $recordingState)
            .map { isFinished, isStreaming, isCompanionBusy, recordingState in
                isFinished && !isStreaming && !isCompanionBusy && recordingState == .idle
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isClearButtonVisible in
                guard let self, let clearButtonHost = self.clearButtonHost else { return }
                if isClearButtonVisible { self.canvasView?.releasePenCursor() }
                NSAnimationContext.runAnimationGroup { animationContext in
                    animationContext.duration = 0.25
                    clearButtonHost.animator().alphaValue = isClearButtonVisible ? 1 : 0
                }
            }
    }

    private func teardownOverlay() {
        isPenDrawing = false
        clearButtonVisibilityCancellable = nil
        whiteboardPanel?.close()
        whiteboardPanel = nil
        ClickyDrawingSaveOfferController.shared.dismiss()
        removeEventMonitors()
        overlayPanel?.orderOut(nil)
        overlayPanel?.contentView = nil
        overlayPanel = nil
        canvasView = nil
        targetRingContainerLayer = nil
        activeScreen = nil
    }

    private func installEventMonitorsIfNeeded() {
        if globalMouseMoveMonitor == nil {
            globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleGlobalMouseMoved()
                }
            }
        }
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleGlobalMouseClick()
                }
            }
        }
    }

    private func removeEventMonitors() {
        if let monitor = globalMouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMoveMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let appObs = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                let activatedApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if activatedApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self.handleScreenChanged(reason: "app")
                }
            }
        }
        let spaceObs = nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenChanged(reason: "space")
            }
        }
        workspaceObservers.append(contentsOf: [appObs, spaceObs])
    }

    // MARK: - Pause, White Board, Show Big, Save Offer

    /// Space during a replay: freezes or resumes the drawing clock.
    public func toggleReplayPause() {
        engine.setPaused(!engine.isPaused)
    }

    /// Puts an opaque white board behind the drawing on the drawing's screen (closes together with the overlay).
    public func showWhiteboardBehindDrawing() {
        guard let screen = activeScreen, let overlayPanel else { return }
        whiteboardPanel?.close()
        let board = ClickyDrawingWhiteboardPanel(
            screen: screen,
            level: NSWindow.Level(rawValue: overlayPanel.level.rawValue - 1),
            engine: engine,
            onCloseRequested: { [weak self] in self?.clearAll() },
            onTogglePauseRequested: { [weak self] in self?.toggleReplayPause() }
        )
        whiteboardPanel = board
        board.makeKeyAndOrderFront(nil)
        overlayPanel.orderFrontRegardless()
    }

    /// Context menu on a pinned card: unpin it and zoom it to the big size.
    private func showPinnedCardBig(_ card: ClickyDrawingCard) {
        guard let screen = activeScreen else { return }
        pinnedStackHeightsByCardMark.removeAll { $0.cardMark == card.marks.first }
        engine.zoomCard(marks: card.marks, to: nil)
        // The pinned card's box is the shrunken one; take the restored card's box before zooming it big.
        let restoredCard = engine.currentCards().first { $0.marks.first == card.marks.first } ?? card
        let transform = Self.bigCardTransform(box: restoredCard.box, screenSize: activeCanvasSize(for: screen))
        engine.zoomCard(marks: card.marks, to: transform)
        syncCardsToCanvas()
    }

    /// `[scale, tx, ty]` that centres a card at up to 72% of the screen (shared by the green button and "Show Big").
    nonisolated public static func bigCardTransform(box: CGRect, screenSize: CGSize) -> [Double] {
        let scale = min(screenSize.width * 0.72 / max(1, box.width), screenSize.height * 0.72 / max(1, box.height), 2.2)
        let translationX = screenSize.width / 2 - box.midX * scale
        let translationY = screenSize.height / 2 - box.midY * scale
        return [Double(scale), Double(translationX), Double(translationY)]
    }

    /// Watches the engine for "a drawing just finished" and offers to save it.
    private func observeDrawingCompletion() {
        engine.$isFinished
            .removeDuplicates()
            .sink { [weak self] isFinishedNow in
                guard let self else { return }
                if !isFinishedNow {
                    self.drawingFinishedAtMediaTime = nil
                    self.hasSeenDrawingStart = true
                    self.drawingStartedAtMediaTime = CACurrentMediaTime()
                    return
                }
                guard self.hasSeenDrawingStart else { return }
                self.hasSeenDrawingStart = false
                self.drawingFinishedAtMediaTime = CACurrentMediaTime()
                self.lastObservedDrawingDurationSeconds = CACurrentMediaTime() - self.drawingStartedAtMediaTime
                self.presentSaveOfferShortlyIfStillFinished()
            }
            .store(in: &cancellables)
    }

    private func presentSaveOfferShortlyIfStillFinished() {
        Task { @MainActor [weak self] in
            // Streaming answers flip "finished" between chunks; give the stream a moment to prove it is really done.
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, self.isActive, self.currentStreamDone, self.engine.isFinished,
                  !self.isSavingVideo,
                  !self.currentReplayProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let screen = self.activeScreen else { return }
            ClickyDrawingSaveOfferController.shared.present(
                on: screen,
                drawingTitle: self.currentDrawingTitle ?? String(localized: "Drawing"),
                manager: self
            )
        }
    }

    // MARK: - Engine Integration

    private func wireEngineCallbacks() {
        engine.onRenderOps = { [weak self] ops in
            guard let self else { return }
            self.canvasView?.applyRenderOps(ops)
            self.syncCardsToCanvas()
        }

        engine.onButtonReady = { [weak self] event in
            self?.canvasView?.showActionButton(for: event)
        }

        engine.$captionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.latestCaption = state
            }
            .store(in: &cancellables)
    }

    private func handleAnalysisUpdate(_ analysis: ClickyDrawingAnalysis) {
        canvasView?.registerActions(analysis.actions)

        let targets = analysis.actions.compactMap { action -> GuidedClickTarget? in
            guard action.isGuidedTarget else { return nil }
            let rect: CGRect?
            if let arr = action.box, arr.count == 4 {
                rect = CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
            } else {
                rect = nil
            }
            let target = GuidedClickTarget(
                id: "\(action.markIndex)-\(action.role)",
                markIndex: action.markIndex,
                role: action.role,
                center: CGPoint(x: action.x, y: action.y),
                radius: max(18, CGFloat(action.radius)),
                box: rect,
                label: action.label,
                lineIndex: action.lineIndex
            )
            return completedTargetIDs.contains(target.id) ? nil : target
        }

        activeTargets = targets
        if !targets.isEmpty {
            targetShowTimestamp = CACurrentMediaTime()
        }
        renderTargetRings()
    }

    /// Parks a window card (only when not zoomed/pinned already) in a stack at the top-right of the screen.
    private func pinCardToSide(_ card: ClickyDrawingCard) {
        guard let screen = activeScreen,
              let cardMark = card.marks.first,
              let chrome = card.windowChrome, !chrome.isZoomed,
              !pinnedStackHeightsByCardMark.contains(where: { $0.cardMark == cardMark }) else { return }

        let stackOffsetY = pinnedStackHeightsByCardMark.reduce(CGFloat(0)) { $0 + $1.stackHeight }
        let transform = Self.pinnedCardTransform(
            box: card.box,
            canvasWidth: activeCanvasSize(for: screen).width,
            stackOffsetY: stackOffsetY
        )
        let pinnedCount = engine.zoomCard(marks: card.marks, to: transform)
        guard pinnedCount > 0 else { return }
        pinnedStackHeightsByCardMark.append((cardMark, card.box.height * Self.pinnedCardScale + Self.pinnedCardStackGap))
        syncCardsToCanvas()
    }

    private func syncCardsToCanvas() {
        let cards = engine.currentCards()
        // Forget pinned entries whose card is gone or no longer zoomed (closed, reset by the engine) so the stack closes up.
        pinnedStackHeightsByCardMark.removeAll { pinned in
            !cards.contains { $0.marks.first == pinned.cardMark && ($0.windowChrome?.isZoomed ?? false) }
        }
        if cards.count != lastCardSyncCount || !cards.isEmpty {
            lastCardSyncCount = cards.count
            canvasView?.syncCards(cards)
        }
    }

    // MARK: - Guided Click Target Rendering & Detection

    private func renderTargetRings() {
        guard let container = targetRingContainerLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sub in container.sublayers ?? [] { sub.removeFromSuperlayer() }

        let inkColor = canvasView?.activeInkColor ?? NSColor(srgbRed: 0.2, green: 0.5, blue: 1.0, alpha: 1)
        // Targets are in canvas units; this container lives in view points.
        let canvasUnitsToViewScaleX = container.bounds.width / max(1, canvasView?.canvasSize.width ?? 1)
        let canvasUnitsToViewScaleY = container.bounds.height / max(1, canvasView?.canvasSize.height ?? 1)

        for target in activeTargets {
            let ringRect: CGRect
            let cornerRadius: CGFloat
            if let box = target.box {
                let canvasRingRect = box.insetBy(dx: -4, dy: -4)
                ringRect = CGRect(
                    x: canvasRingRect.minX * canvasUnitsToViewScaleX,
                    y: canvasRingRect.minY * canvasUnitsToViewScaleY,
                    width: canvasRingRect.width * canvasUnitsToViewScaleX,
                    height: canvasRingRect.height * canvasUnitsToViewScaleY
                )
                cornerRadius = min(14, ringRect.height / 2)
            } else {
                let radiusInViewPoints = target.radius * canvasUnitsToViewScaleX
                ringRect = CGRect(
                    x: (target.center.x - target.radius) * canvasUnitsToViewScaleX,
                    y: (target.center.y - target.radius) * canvasUnitsToViewScaleY,
                    width: radiusInViewPoints * 2,
                    height: target.radius * 2 * canvasUnitsToViewScaleY
                )
                cornerRadius = radiusInViewPoints
            }

            let ringLayer = CAShapeLayer()
            ringLayer.path = CGPath(roundedRect: ringRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ringLayer.fillColor = inkColor.withAlphaComponent(0.08).cgColor
            ringLayer.strokeColor = inkColor.cgColor
            ringLayer.lineWidth = 3.0
            ringLayer.lineDashPattern = [8, 5]
            ringLayer.shadowColor = inkColor.cgColor
            ringLayer.shadowOpacity = 0.65
            ringLayer.shadowRadius = 10
            ringLayer.shadowOffset = .zero

            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.45
            pulse.duration = 0.85
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            ringLayer.add(pulse, forKey: "target-pulse")

            container.addSublayer(ringLayer)
        }
        CATransaction.commit()
    }

    private func clearTargetRings() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sub in targetRingContainerLayer?.sublayers ?? [] {
            sub.removeFromSuperlayer()
        }
        CATransaction.commit()
    }

    private func handleGlobalMouseMoved() {
        guard let panel = overlayPanel, let canvas = canvasView, let screen = activeScreen else { return }

        let mouseScreen = NSEvent.mouseLocation
        if screen.frame.contains(mouseScreen) {
            let localInPanel = CGPoint(
                x: mouseScreen.x - screen.frame.origin.x,
                y: mouseScreen.y - screen.frame.origin.y
            )
            let isOverInteractive = canvas.hitTest(localInPanel) != nil
            if panel.ignoresMouseEvents == isOverInteractive {
                panel.ignoresMouseEvents = !isOverInteractive
            }

            // Check hover-type guided targets
            let canvasPoint = Self.canvasPoint(
                fromScreenPoint: CGPoint(x: localInPanel.x, y: screen.frame.height - localInPanel.y),
                screenSize: screen.frame.size
            )
            checkGuidedTargets(at: canvasPoint, roleFilter: "hover")
        } else if !panel.ignoresMouseEvents {
            panel.ignoresMouseEvents = true
        }
    }

    private func handleGlobalMouseClick() {
        guard let screen = activeScreen, !activeTargets.isEmpty else { return }
        // Ignore clicks within 150ms of target appearance to prevent accidental immediate triggers
        if CACurrentMediaTime() - targetShowTimestamp < 0.15 { return }

        let mouseScreen = NSEvent.mouseLocation
        guard screen.frame.contains(mouseScreen) else { return }
        let canvasPoint = Self.canvasPoint(
            fromScreenPoint: CGPoint(
                x: mouseScreen.x - screen.frame.origin.x,
                y: screen.frame.height - (mouseScreen.y - screen.frame.origin.y)
            ),
            screenSize: screen.frame.size
        )
        checkGuidedTargets(at: canvasPoint, roleFilter: "target")
    }

    private func checkGuidedTargets(at canvasPoint: CGPoint, roleFilter: String) {
        var completedAny = false
        var remaining: [GuidedClickTarget] = []

        for target in activeTargets {
            guard target.role == roleFilter else {
                remaining.append(target)
                continue
            }
            let hit: Bool
            if let box = target.box {
                hit = box.insetBy(dx: -12, dy: -12).contains(canvasPoint)
            } else {
                let distance = hypot(canvasPoint.x - target.center.x, canvasPoint.y - target.center.y)
                hit = distance <= (target.radius + 14)
            }

            if hit {
                completedAny = true
                completedTargetIDs.insert(target.id)
                lastCompletedTarget = target
                if ClickyConfiguration.shared.soundEffectsEnabled {
                    ClickySoundEffectPlayer.shared.play(.ding)
                }
                ClickyAnalytics.trackGuidedTargetCompleted(role: target.role, label: target.label)
                onGuidedTargetCompleted?(target)
            } else {
                remaining.append(target)
            }
        }

        if completedAny {
            activeTargets = remaining
            renderTargetRings()
        }
    }

    // MARK: - Action Button Handling

    /// Only http(s) URLs with a non-empty host may be opened from a drawing button.
    nonisolated static func safeOpenableURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func handleActionButtonPressed(_ payload: ClickyActionButtonPayload) {
        if ClickyConfiguration.shared.soundEffectsEnabled {
            ClickySoundEffectPlayer.shared.play(.gelPop)
        }
        ClickyAnalytics.trackDrawingActionTriggered(kind: payload.kind, label: payload.text)

        switch payload.kind {
        case "open":
            if let urlString = payload.value as? String, let url = Self.safeOpenableURL(from: urlString) {
                NSWorkspace.shared.open(url)
            } else {
                print("⚠️ Drawing button open ignored: not an http(s) URL with a host")
            }
        case "copy":
            if let text = payload.value as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "ask":
            if let prompt = payload.value as? String {
                onAskFollowUp?(prompt)
            }
        case "handoff":
            if let dict = payload.value as? [String: Any] {
                onHandOffRequested?(dict)
            }
        default:
            break
        }
    }

    func currentInkHex() -> String {
        switch UserDefaults.standard.string(forKey: "clicky_cursor_color_name")?.lowercased() {
        case "red": return "#FF4C4C"
        case "yellow": return "#D4A017"
        case "green": return "#26C281"
        default: return "#3380FF"
        }
    }
}

/// The drawing's "Clear" pill (white capsule, top center). Visibility is driven by `bindClearButtonVisibility`.
struct ClickyDrawingClearButton: View {
    @ObservedObject var manager: ScreenAnnotationManager

    var body: some View {
        Button {
            manager.clearAll()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                Text("Clear")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(Text("Take the drawing off the screen (or press Escape)"))
        .accessibilityLabel(Text("Take the drawing off the screen (or press Escape)"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
