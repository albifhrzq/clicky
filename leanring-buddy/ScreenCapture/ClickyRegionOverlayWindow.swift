//
//  ClickyRegionOverlayWindow.swift
//  leanring-buddy
//
//  Full-screen overlay panel and drag-selection view used by region capture.
//

import AppKit
import SwiftUI

final class ClickyRegionOverlayPanel: NSPanel {
    let regionView: ClickyRegionSelectionView

    init(screen: NSScreen) {
        regionView = ClickyRegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = regionView
        setFrame(screen.frame, display: true)
    }

    // Borderless panels refuse key status by default; we need it for Esc.
    override var canBecomeKey: Bool { true }

    // Make sure Esc reaches the selection view whichever screen's panel is key.
    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(regionView)
    }

    override func cancelOperation(_ sender: Any?) { regionView.onCancelled?() }
}

final class ClickyRegionSelectionView: NSView {
    var onRectCapturedWithAction: ((CGRect, ClickyRegionCaptureAction) -> Void)?
    var onCancelled: (() -> Void)?
    var onSelectionStarted: (() -> Void)?
    var shouldHideQueueOnlyActionButton = false

    private var dragStartPointInViewCoords: CGPoint?
    private var currentDragEndPointInViewCoords: CGPoint?
    private var frozenRectInViewCoords: CGRect?
    private var postDragActionBarHostingView: NSView?
    private let coreAnimationDimLayer = CAShapeLayer()
    private let selectionBorderLayer = CAShapeLayer()
    private let hintLabel = NSTextField(labelWithString: "")

    // Top-left origin so drag coordinates match ScreenCaptureKit's sourceRect.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        coreAnimationDimLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        coreAnimationDimLayer.fillRule = .evenOdd
        selectionBorderLayer.fillColor = nil
        selectionBorderLayer.strokeColor = NSColor.white.cgColor
        selectionBorderLayer.lineWidth = 1.5
        layer?.addSublayer(coreAnimationDimLayer)
        layer?.addSublayer(selectionBorderLayer)

        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.alignment = .center
        hintLabel.wantsLayer = true
        hintLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        hintLabel.layer?.cornerRadius = 8
        addSubview(hintLabel)
        setHint(dragHintText)
        updateLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var dragHintText: String { String(localized: "Drag to capture screenshot  •  Esc or right-click to cancel") }

    override func layout() {
        super.layout()
        updateLayers()
        layoutHint()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Hint

    private func setHint(_ text: String) {
        hintLabel.stringValue = "  \(text)  "
        layoutHint()
    }

    private func layoutHint() {
        let size = hintLabel.intrinsicContentSize
        hintLabel.frame = CGRect(x: (bounds.width - size.width) / 2, y: 40, width: size.width, height: size.height + 8)
    }

    func showTransientHint(_ text: String) {
        setHint(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.setHint(self.frozenRectInViewCoords == nil ? self.dragHintText : String(localized: "Pick an action below  •  Esc or right-click to cancel"))
        }
    }

    // MARK: Drawing

    private var activeRect: CGRect? {
        if let frozenRectInViewCoords { return frozenRectInViewCoords }
        guard let start = dragStartPointInViewCoords, let end = currentDragEndPointInViewCoords else { return nil }
        return ClickyRegionGeometry.normalizedRect(from: start, to: end)
    }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        if let rect = activeRect {
            path.addRect(rect)
            selectionBorderLayer.path = CGPath(rect: rect, transform: nil)
        } else {
            selectionBorderLayer.path = nil
        }
        coreAnimationDimLayer.frame = bounds
        coreAnimationDimLayer.path = path
        CATransaction.commit()
    }

    func resetSelection() {
        dragStartPointInViewCoords = nil
        currentDragEndPointInViewCoords = nil
        frozenRectInViewCoords = nil
        postDragActionBarHostingView?.removeFromSuperview()
        postDragActionBarHostingView = nil
        setHint(dragHintText)
        updateLayers()
    }

    // MARK: Mouse and keys

    override func mouseDown(with event: NSEvent) {
        guard frozenRectInViewCoords == nil else { return }
        onSelectionStarted?()
        dragStartPointInViewCoords = convert(event.locationInWindow, from: nil)
        currentDragEndPointInViewCoords = dragStartPointInViewCoords
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStartPointInViewCoords != nil, frozenRectInViewCoords == nil else { return }
        currentDragEndPointInViewCoords = convert(event.locationInWindow, from: nil)
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        guard frozenRectInViewCoords == nil, let rect = activeRect else { return }
        let clampedRect = ClickyRegionGeometry.clampedToBounds(rect, boundsSize: bounds.size)
        guard ClickyRegionGeometry.isLargeEnough(clampedRect) else {
            resetSelection()
            return
        }
        frozenRectInViewCoords = clampedRect
        setHint(String(localized: "Pick an action below  •  Esc or right-click to cancel"))
        showActionBar(below: clampedRect)
        updateLayers()
    }

    override func rightMouseDown(with event: NSEvent) { onCancelled?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancelled?() } else { super.keyDown(with: event) }
    }

    // MARK: Action bar

    private func showActionBar(below rect: CGRect) {
        let bar = NSHostingView(rootView: ClickyRegionActionBar(shouldHideQueueOnlyActionButton: shouldHideQueueOnlyActionButton) { [weak self] action in
            guard let self, let rect = self.frozenRectInViewCoords else { return }
            self.onRectCapturedWithAction?(rect, action)
        })
        let size = bar.fittingSize
        let gap: CGFloat = 8
        // View is flipped: "below" means larger y. Fall back to above when there's no room.
        let belowY = rect.maxY + gap
        let originY = belowY + size.height <= bounds.height ? belowY : max(rect.minY - gap - size.height, 0)
        let originX = min(max(rect.midX - size.width / 2, 8), bounds.width - size.width - 8)
        bar.frame = CGRect(x: originX, y: originY, width: size.width, height: size.height)
        addSubview(bar)
        postDragActionBarHostingView = bar
    }
}

private struct ClickyRegionActionBar: View {
    let shouldHideQueueOnlyActionButton: Bool
    let onAction: (ClickyRegionCaptureAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            actionButton("Send with text", .text)
            actionButton("Send with voice", .voice)
            if !shouldHideQueueOnlyActionButton {
                actionButton("Don't send yet", .queueOnly)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.88)))
        .padding(4)
    }

    private func actionButton(_ title: LocalizedStringKey, _ action: ClickyRegionCaptureAction) -> some View {
        Button { onAction(action) } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
