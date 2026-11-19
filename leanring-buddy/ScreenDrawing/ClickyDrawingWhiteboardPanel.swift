//
//  ClickyDrawingWhiteboardPanel.swift
//  leanring-buddy
//
//  Opaque white board that sits just below the drawing overlay ("Play on a white board").
//  It takes clicks (so nothing behind it is hit), has a close button, and handles Esc / Space
//  while it is the key window. Closed together with the overlay by ScreenAnnotationManager.
//

import AppKit
import Combine

final class ClickyDrawingWhiteboardPanel: NSPanel {
    private let onCloseRequested: () -> Void
    private let onTogglePauseRequested: () -> Void
    private let pauseHintLabel = NSTextField(labelWithString: "")
    private var pauseObservation: AnyCancellable?

    init(
        screen: NSScreen,
        level boardLevel: NSWindow.Level,
        engine: ScreenDrawingNativeEngine,
        onCloseRequested: @escaping () -> Void,
        onTogglePauseRequested: @escaping () -> Void
    ) {
        self.onCloseRequested = onCloseRequested
        self.onTogglePauseRequested = onTogglePauseRequested
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = .white
        hasShadow = false
        level = boardLevel
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let boardView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        boardView.autoresizingMask = [.width, .height]
        contentView = boardView

        let closeButton = PointingHandButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: #selector(closeButtonPressed)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(white: 0.35, alpha: 1)
        closeButton.toolTip = String(localized: "Take the drawing off the screen (or press Escape)")
        closeButton.setAccessibilityLabel(String(localized: "Take the drawing off the screen (or press Escape)"))
        closeButton.frame = NSRect(x: 16, y: screen.frame.height - 48, width: 32, height: 32)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        boardView.addSubview(closeButton)

        pauseHintLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pauseHintLabel.textColor = NSColor(white: 0.4, alpha: 1)
        pauseHintLabel.frame = NSRect(x: 0, y: 12, width: screen.frame.width, height: 18)
        pauseHintLabel.alignment = .center
        pauseHintLabel.autoresizingMask = [.width, .maxYMargin]
        boardView.addSubview(pauseHintLabel)
        pauseObservation = engine.$isPaused.sink { [weak self] isPaused in
            self?.pauseHintLabel.stringValue = isPaused ? String(localized: "Play (space)") : String(localized: "Pause (space)")
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc private func closeButtonPressed() {
        onCloseRequested()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCloseRequested()          // Esc
        case 49: onTogglePauseRequested()    // Space
        default: super.keyDown(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

/// Button that shows the pointing-hand cursor over its whole frame (the panel itself forces an arrow).
private final class PointingHandButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
