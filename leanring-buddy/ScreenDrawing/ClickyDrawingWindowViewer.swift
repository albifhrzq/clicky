//
//  ClickyDrawingWindowViewer.swift
//  leanring-buddy
//
//  "Play it in a window": a normal, titled, resizable window with its OWN drawing engine and
//  canvas, so it never fights the full-screen overlay singleton. Space pauses / resumes while
//  the window is key. Resizing restarts the drawing at the new size (programs lay out for a fixed canvas).
//

import AppKit
import Combine

private final class ClickyDrawingViewerWindow: NSWindow {
    var onTogglePauseRequested: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // Space, only while this window is focused
            onTogglePauseRequested?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class ClickyDrawingWindowViewer: NSObject, NSWindowDelegate {
    private static var openViewers: [ClickyDrawingWindowViewer] = []

    private let drawingProgram: String
    private let engine = ScreenDrawingNativeEngine()
    private let canvasView: ScreenDrawingCanvasView
    private let window: ClickyDrawingViewerWindow
    private var pauseObservation: AnyCancellable?
    private var relayoutWorkItem: DispatchWorkItem?

    static func open(title: String, code: String) {
        let viewer = ClickyDrawingWindowViewer(title: title, code: code)
        openViewers.append(viewer)
        viewer.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(title: String, code: String) {
        drawingProgram = ScreenAnnotationManager.extractDrawingCode(from: code) ?? code
        let initialSize = CGSize(width: 960, height: 640)
        canvasView = ScreenDrawingCanvasView(frame: NSRect(origin: .zero, size: initialSize))
        canvasView.autoresizingMask = [.width, .height]
        window = ClickyDrawingViewerWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = String(localized: "Drawing: \(title)")
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.contentMinSize = CGSize(width: 480, height: 320)
        window.contentView = canvasView
        window.delegate = self
        window.center()
        window.onTogglePauseRequested = { [weak self] in
            guard let self else { return }
            self.engine.setPaused(!self.engine.isPaused)
        }
        pauseObservation = engine.$isPaused.sink { [weak self] isPaused in
            self?.window.subtitle = isPaused ? String(localized: "Play (space)") : String(localized: "Pause (space)")
        }

        // White window: tell the drawing the background is light so it picks dark ink.
        engine.luminanceSampler = { _ in 1.0 }
        engine.figuresFloat = false
        wireEngine()
        startDrawing()
    }

    private func wireEngine() {
        engine.onRenderOps = { [weak self] ops in
            guard let self else { return }
            self.canvasView.applyRenderOps(ops)
            self.canvasView.syncCards(self.engine.currentCards())
        }
        engine.onButtonReady = { [weak self] event in
            self?.canvasView.showActionButton(for: event)
        }
        canvasView.onCardCloseRequested = { [weak self] card in
            guard let self else { return }
            self.engine.closeCard(marks: card.marks)
            self.canvasView.syncCards(self.engine.currentCards())
        }
        canvasView.onCardMoved = { [weak self] card, delta in
            guard let self else { return }
            self.engine.moveCard(marks: card.marks, dx: Double(delta.x), dy: Double(delta.y))
            self.canvasView.syncCards(self.engine.currentCards())
        }
        canvasView.onTick3DRequested = { [weak self] stageID, ticks, dt in
            self?.engine.tick3D(stageID: stageID, ticks: ticks, dt: dt)
        }
    }

    private func startDrawing() {
        engine.clear()
        canvasView.clearAll()
        let canvasSize = canvasView.bounds.size
        let inkHex = ScreenAnnotationManager.shared.currentInkHex()
        canvasView.configureCanvas(size: canvasSize, inkHex: inkHex)
        engine.beginStream(size: canvasSize, displayWidthPoints: canvasSize.width, subtitles: false, inkHex: inkHex)
        if let analysis = engine.feed(code: drawingProgram, done: true) {
            canvasView.registerActions(analysis.actions)
        }
        engine.finish()
        canvasView.syncCards(engine.currentCards())
    }

    // MARK: - NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        startDrawing()
    }

    /// Zoom / full screen change the size without a live resize, so relayout after a short debounce.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !window.inLiveResize else { return }
        scheduleDebouncedRelayout()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { scheduleDebouncedRelayout() }
    func windowDidExitFullScreen(_ notification: Notification) { scheduleDebouncedRelayout() }

    private func scheduleDebouncedRelayout() {
        relayoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.startDrawing() }
        relayoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func windowWillClose(_ notification: Notification) {
        engine.clear()
        canvasView.clearAll()
        Self.openViewers.removeAll { $0 === self }
    }
}
