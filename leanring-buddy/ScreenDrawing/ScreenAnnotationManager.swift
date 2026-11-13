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
    @Published public private(set) var lastCompletedTarget: GuidedClickTarget?

    public var onGuidedTargetCompleted: ((GuidedClickTarget) -> Void)?
    public var onAskFollowUp: ((String) -> Void)?
    public var onHandOffRequested: (([String: Any]) -> Void)?
    public var onScreenChangeCancelled: (() -> Void)?

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

    private init() {
        wireEngineCallbacks()
        installWorkspaceObservers()
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
        completedTargetIDs.removeAll()

        let size = targetScreen.frame.size
        canvasView?.configureCanvas(size: size, inkHex: currentInkHex())
        engine.beginStream(size: size, displayWidthPoints: size.width, subtitles: subtitles, inkHex: currentInkHex())

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
        completedTargetIDs.removeAll()

        let size = targetScreen.frame.size
        canvasView?.configureCanvas(size: size, inkHex: currentInkHex())
        engine.beginStream(size: size, displayWidthPoints: size.width, subtitles: subtitles, inkHex: currentInkHex())
        isActive = true
    }

    /// Feeds either raw JS or full/partial markdown LLM response text incrementally.
    @discardableResult
    public func feedStreamingResponse(_ responseText: String, done: Bool) -> ClickyDrawingAnalysis? {
        guard let extracted = Self.extractDrawingCode(from: responseText, allowUnclosedFence: !done) else {
            return nil
        }
        if !isActive {
            beginStreamingProgram()
        }
        if extracted == currentStreamCode && done == currentStreamDone {
            return engine.latestAnalysis
        }
        currentStreamCode = extracted
        currentStreamDone = done

        let analysis = engine.feed(code: extracted, done: done)
        if let analysis {
            handleAnalysisUpdate(analysis)
        }
        if done {
            engine.finish()
            syncCardsToCanvas()
        }
        return analysis
    }

    public func notifySpeechLineStarted(_ lineIndex: Int) {
        engine.markLineStarted(lineIndex)
    }

    public func notifySpeechLineLength(_ lineIndex: Int, seconds: Double) {
        engine.setLineLength(lineIndex, seconds: seconds)
    }

    /// Clears all annotations, 3D stages, interactive buttons, and target rings.
    public func clearAll() {
        engine.clear()
        canvasView?.clearAll()
        clearTargetRings()
        activeTargets = []
        completedTargetIDs.removeAll()
        currentStreamCode = ""
        currentStreamDone = false
        lastCardSyncCount = -1
        isActive = false
        teardownOverlay()
    }

    /// Drops screen-pointing marks when the underlying app/screen changes.
    public func handleScreenChanged() {
        guard isActive else { return }

        if !engine.isFinished {
            let res = engine.dropPointing()
            if (res?.left ?? 0) == 0 {
                clearAll()
                onScreenChangeCancelled?()
                return
            }
        } else {
            let res = engine.keepNotesOnly()
            if (res?.kept ?? 0) == 0 {
                clearAll()
                onScreenChangeCancelled?()
                return
            }
        }

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
        let canvas = ScreenDrawingCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.autoresizingMask = [.width, .height]

        canvas.onActionButtonPressed = { [weak self] payload in
            self?.handleActionButtonPressed(payload)
        }
        canvas.onCardCloseRequested = { [weak self] card in
            guard let self else { return }
            let result = self.engine.closeCard(marks: card.marks)
            self.syncCardsToCanvas()
            if (result?.left ?? 0) == 0 {
                self.clearAll()
            }
        }
        canvas.onCardZoomRequested = { [weak self] card in
            guard let self, let screen = self.activeScreen else { return }
            let isZoomed = card.windowChrome?.isZoomed ?? false
            if isZoomed {
                self.engine.zoomCard(marks: card.marks, to: nil)
            } else {
                let targetW = screen.frame.width * 0.72
                let targetH = screen.frame.height * 0.72
                let scale = min(targetW / max(1, card.box.width), targetH / max(1, card.box.height), 2.2)
                let cx = card.box.midX
                let cy = card.box.midY
                let targetCX = screen.frame.width / 2
                let targetCY = screen.frame.height / 2
                let tx = targetCX - cx * scale
                let ty = targetCY - cy * scale
                self.engine.zoomCard(marks: card.marks, to: [Double(scale), Double(tx), Double(ty)])
            }
            self.syncCardsToCanvas()
        }
        canvas.onCardMoved = { [weak self] card, delta in
            self?.engine.moveCard(marks: card.marks, dx: Double(delta.x), dy: Double(delta.y))
            self?.syncCardsToCanvas()
        }
        canvas.onTick3DRequested = { [weak self] stageID, ticks, dt in
            self?.engine.tick3D(stageID: stageID, ticks: ticks, dt: dt)
        }

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

    private func teardownOverlay() {
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
                    self.handleScreenChanged()
                }
            }
        }
        let spaceObs = nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenChanged()
            }
        }
        workspaceObservers.append(contentsOf: [appObs, spaceObs])
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

    private func syncCardsToCanvas() {
        let cards = engine.currentCards()
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

        for target in activeTargets {
            let ringRect: CGRect
            let cornerRadius: CGFloat
            if let box = target.box {
                ringRect = box.insetBy(dx: -4, dy: -4)
                cornerRadius = min(14, ringRect.height / 2)
            } else {
                let r = target.radius
                ringRect = CGRect(x: target.center.x - r, y: target.center.y - r, width: r * 2, height: r * 2)
                cornerRadius = r
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
            let canvasPoint = CGPoint(x: localInPanel.x, y: screen.frame.height - localInPanel.y)
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
        let canvasPoint = CGPoint(
            x: mouseScreen.x - screen.frame.origin.x,
            y: screen.frame.height - (mouseScreen.y - screen.frame.origin.y)
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

    private func handleActionButtonPressed(_ payload: ClickyActionButtonPayload) {
        if ClickyConfiguration.shared.soundEffectsEnabled {
            ClickySoundEffectPlayer.shared.play(.gelPop)
        }
        ClickyAnalytics.trackDrawingActionTriggered(kind: payload.kind, label: payload.text)

        switch payload.kind {
        case "open":
            if let urlString = payload.value as? String, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
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

    private func currentInkHex() -> String {
        switch UserDefaults.standard.string(forKey: "clicky_cursor_color_name")?.lowercased() {
        case "red": return "#FF4C4C"
        case "yellow": return "#D4A017"
        case "green": return "#26C281"
        default: return "#3380FF"
        }
    }
}
