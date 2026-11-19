//
//  ScreenDrawingCanvasView.swift
//  leanring-buddy
//
//  Transparent, selectively click-through AppKit NSView / CALayer / CAShapeLayer
//  host rendering __drainRender ops, animations, CoreText PatrickHand text,
//  macOS card chrome, interactive button() pills, card drag handles, and 3D stages.
//

import AppKit
import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Interactive Button & Card Models

public struct ClickyActionButtonPayload: Identifiable {
    public let id: Int
    public let markIndex: Int
    public let text: String
    public let kind: String
    public let value: Any
    public let box: CGRect
}

// MARK: - ScreenDrawingCanvasView

@MainActor
public final class ScreenDrawingCanvasView: NSView {

    // MARK: - Public Callbacks

    public var onActionButtonPressed: ((ClickyActionButtonPayload) -> Void)?
    public var onCardCloseRequested: ((ClickyDrawingCard) -> Void)?
    public var onCardZoomRequested: ((ClickyDrawingCard) -> Void)?
    public var onCardMoved: ((ClickyDrawingCard, CGPoint) -> Void)?
    public var onCardPinRequested: ((ClickyDrawingCard) -> Void)?
public var onCardShowBigRequested: ((ClickyDrawingCard) -> Void)?
    public var onSaveAsVideoRequested: (() -> Void)?
    public var onTick3DRequested: ((_ stageID: String, _ ticks: [(id: String, elapsed: Double)], _ dt: Double) -> [Float]?)?

    // MARK: - Canvas State

    public private(set) var canvasSize: CGSize = CGSize(width: 1280, height: 800)
    public private(set) var activeInkColor: NSColor = NSColor(srgbRed: 0.2, green: 0.5, blue: 1.0, alpha: 1.0)

    private let renderRootLayer = CALayer()
    private let underLayer = CALayer()
    private let mainLayer = CALayer()
    private let highlightLayer = CALayer()
    private let wordsLayer = CALayer()
    /// Clicky's cursor while it draws: the buddy triangle hands off to this layer, which rides each pen stroke.
    private let penFollowerLayer = CAShapeLayer()
    /// True while the pen cursor is out (first stroke until `releasePenCursor()`), so the floating buddy hides.
    public var onPenDrawingChanged: ((Bool) -> Void)?
    private let interactiveOverlayContainer = ClickyFlippedContainerView()

    private var layersByNodeID: [Int: CALayer] = [:]
    private var parentGroupByNodeID: [Int: String] = [:]
    private var maskSpecsByID: [String: MaskSpec] = [:]
    private var maskLayersByID: [String: [CAShapeLayer]] = [:]
    private var maskTargetOpacityByNodeID: [Int: Float] = [:]

    private var stageViewsByID: [String: ClickyThreeStageView] = [:]
    private var stage3DProjectedLabels: [String: [ClickyThreeStageView.LabelProjection]] = [:]
    private var projectedLabelLayers: [String: ClickyCoreTextLayer] = [:]
    private var projectedLabelWidthCache: [String: (text: String, size: Double, width: CGFloat)] = [:]

    private var pendingButtons: [Int: ClickyActionButtonPayload] = [:]
    private var actionButtonViews: [Int: ClickyActionPillButton] = [:]
    private var visibleCards: [ClickyDrawingCard] = []
    private var cardHandleViews: [String: ClickyCardDragHandleView] = [:]
    private var draggingCard: ClickyDrawingCard?
    private var dragStartPointInCanvas: CGPoint = .zero
    private var dragAccumulatedDelta: CGPoint = .zero

    private struct MaskSpec {
        let id: String
        let pathData: String
        let strokeWidth: CGFloat
        let animation: ClickyRenderAnimation?
    }

    // MARK: - Init & Layout

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        renderRootLayer.masksToBounds = false
        underLayer.masksToBounds = false
        mainLayer.masksToBounds = false
        highlightLayer.masksToBounds = false
        wordsLayer.masksToBounds = false

        renderRootLayer.addSublayer(underLayer)
        renderRootLayer.addSublayer(mainLayer)
        renderRootLayer.addSublayer(highlightLayer)
        renderRootLayer.addSublayer(wordsLayer)

        setupPenFollowerLayer()
        renderRootLayer.addSublayer(penFollowerLayer)

        layer?.addSublayer(renderRootLayer)

        interactiveOverlayContainer.frame = bounds
        interactiveOverlayContainer.autoresizingMask = [.width, .height]
        interactiveOverlayContainer.wantsLayer = true
        interactiveOverlayContainer.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(interactiveOverlayContainer)
    }

    private func setupPenFollowerLayer() {
        // Same triangle as the floating buddy, but with its tip pointing along +x: the pen animation uses
        // rotateAuto, which turns +x to the stroke direction, so the tip leads the way like the official pen.
        let triangleSize: CGFloat = 14
        let triangleHeight = triangleSize * sqrt(3.0) / 2.0
        let tipPoint = CGPoint(x: triangleHeight, y: triangleSize / 2)
        let trianglePath = CGMutablePath()
        trianglePath.move(to: tipPoint)
        trianglePath.addLine(to: CGPoint(x: 0, y: 0))
        trianglePath.addLine(to: CGPoint(x: 0, y: triangleSize))
        trianglePath.closeSubpath()
        penFollowerLayer.bounds = CGRect(x: 0, y: 0, width: triangleHeight, height: triangleSize)
        penFollowerLayer.path = trianglePath
        // The tip, not the middle, sits on the stroke; rotating around it keeps it there.
        penFollowerLayer.anchorPoint = CGPoint(x: 1, y: 0.5)
        penFollowerLayer.fillColor = Self.currentCursorColor.cgColor
        penFollowerLayer.shadowColor = Self.currentCursorColor.cgColor
        penFollowerLayer.shadowOpacity = 0.85
        penFollowerLayer.shadowRadius = 8
        penFollowerLayer.shadowOffset = .zero
        penFollowerLayer.opacity = 0
    }

    public func configureCanvas(size: CGSize, inkHex: String? = nil) {
        canvasSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        if let inkHex, let color = NSColor.clickyHex(inkHex) {
            activeInkColor = color
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let scaleX = bounds.width / max(1, canvasSize.width)
        let scaleY = bounds.height / max(1, canvasSize.height)
        renderRootLayer.frame = CGRect(origin: .zero, size: canvasSize)
        renderRootLayer.anchorPoint = .zero
        renderRootLayer.position = .zero
        renderRootLayer.transform = CATransform3DMakeScale(scaleX, scaleY, 1)

        for groupLayer in [underLayer, mainLayer, highlightLayer, wordsLayer] {
            groupLayer.frame = renderRootLayer.bounds
        }

        interactiveOverlayContainer.frame = bounds
        repositionInteractiveElements()
        CATransaction.commit()
    }

    // MARK: - Selective Click-Through Hit Testing

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        // NSView.hitTest expects a point in the receiver's superview, which is the container here.
        let containerPoint = interactiveOverlayContainer.convert(localPoint, from: self)
        for subview in interactiveOverlayContainer.subviews.reversed() {
            guard !subview.isHidden, subview.alphaValue > 0.01 else { continue }
            if let hit = subview.hitTest(containerPoint) {
                return hit
            }
        }
        return nil
    }

    // MARK: - Reset & Render Ops

    public func clearAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for sublayer in underLayer.sublayers ?? [] { sublayer.removeFromSuperlayer() }
        for sublayer in mainLayer.sublayers ?? [] { sublayer.removeFromSuperlayer() }
        for sublayer in highlightLayer.sublayers ?? [] { sublayer.removeFromSuperlayer() }
        for sublayer in wordsLayer.sublayers ?? [] { sublayer.removeFromSuperlayer() }
        for (_, lblLayer) in projectedLabelLayers { lblLayer.removeFromSuperlayer() }

        layersByNodeID.removeAll()
        parentGroupByNodeID.removeAll()
        maskSpecsByID.removeAll()
        maskLayersByID.removeAll()
        maskTargetOpacityByNodeID.removeAll()
        projectedLabelLayers.removeAll()
        projectedLabelWidthCache.removeAll()
        stage3DProjectedLabels.removeAll()

        for (_, stageView) in stageViewsByID {
            stageView.removeFromSuperview()
        }
        stageViewsByID.removeAll()

        for (_, btn) in actionButtonViews {
            btn.removeFromSuperview()
        }
        actionButtonViews.removeAll()
        pendingButtons.removeAll()

        for (_, handle) in cardHandleViews {
            handle.removeFromSuperview()
        }
        cardHandleViews.removeAll()
        visibleCards.removeAll()

        hidePenCursor()
        CATransaction.commit()
    }

    /// The pen cursor uses the user's cursor color (Settings → Cursor), like the floating buddy.
    private static var currentCursorColor: NSColor {
        NSColor(DS.Colors.cursorColor(named: ClickyConfiguration.shared.cursorColorName))
    }

    /// Like the official app, the pen stays out between strokes and parks at the last stroke's end
    /// until Clicky finishes speaking (`releasePenCursor()`), then the floating buddy takes over again.
    private func showPenCursor() {
        penFollowerLayer.fillColor = Self.currentCursorColor.cgColor
        penFollowerLayer.shadowColor = Self.currentCursorColor.cgColor
        penFollowerLayer.opacity = 1
        onPenDrawingChanged?(true)
    }

    public func releasePenCursor() {
        hidePenCursor()
    }

    private func hidePenCursor() {
        penFollowerLayer.opacity = 0
        penFollowerLayer.removeAnimation(forKey: "pen-pos")
        onPenDrawingChanged?(false)
    }

    /// Adds an always-clickable control (e.g. the Clear pill) to the hit-testable overlay container.
    public func addPersistentControl(_ controlView: NSView) {
        interactiveOverlayContainer.addSubview(controlView)
    }

    public func applyRenderOps(_ ops: [ClickyRenderOp]) {
        guard !ops.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for op in ops {
            switch op.op {
            case .remove:
                if let nodeID = op.nodeID {
                    removeNode(id: nodeID)
                }
            case .wrap:
                if let gID = op.wrapperGroupID, let childID = op.childNodeID {
                    wrapNode(childID: childID, inGroupID: gID)
                }
            case .set:
                if let node = op.node {
                    applySetOp(node: node, group: op.group ?? "main", beforeNodeID: op.beforeNodeID)
                }
            case .prop:
                applyPropOp(op)
            case .stop:
                applyStopOp(op)
            case .motion:
                applyMotionOp(op)
            }
        }

        CATransaction.commit()
    }

    // MARK: - Interactive Buttons & Card Chrome

    public func registerActions(_ actions: [ClickyDrawingAction]) {
        for action in actions where action.role == "button" {
            guard let boxArr = action.box, boxArr.count == 4,
                  let payloadStr = action.text,
                  let data = payloadStr.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let text = dict["text"] as? String,
                  let kind = dict["kind"] as? String else { continue }

            let value = dict["value"] ?? ""
            let rect = CGRect(x: boxArr[0], y: boxArr[1], width: boxArr[2], height: boxArr[3])
            pendingButtons[action.markIndex] = ClickyActionButtonPayload(
                id: action.markIndex,
                markIndex: action.markIndex,
                text: text,
                kind: kind,
                value: value,
                box: rect
            )
        }
    }

    public func showActionButton(for event: ClickyButtonReadyEvent) {
        guard let payload = pendingButtons[event.markIndex] else { return }
        let showNow = { [weak self] in
            guard let self, let currentPayload = self.pendingButtons[event.markIndex] else { return }
            self.presentActionButton(currentPayload)
        }
        if event.delaySeconds <= 0.02 {
            showNow()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + event.delaySeconds) {
                showNow()
            }
        }
    }

    private func presentActionButton(_ payload: ClickyActionButtonPayload) {
        if actionButtonViews[payload.markIndex] != nil { return }
        let frameInView = canvasRectToViewRect(payload.box)
        let button = ClickyActionPillButton(payload: payload, inkColor: activeInkColor) { [weak self] pressedPayload in
            self?.onActionButtonPressed?(pressedPayload)
        }
        button.frame = frameInView
        button.alphaValue = 0
        interactiveOverlayContainer.addSubview(button)
        actionButtonViews[payload.markIndex] = button

        if ClickyConfiguration.shared.soundEffectsEnabled {
            ClickySoundEffectPlayer.shared.play(.gelPop)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            button.animator().alphaValue = 1
        }
    }

    public func syncCards(_ cards: [ClickyDrawingCard]) {
        visibleCards = cards
        var activeIDs = Set<String>()

        for card in cards {
            let key = card.id
            activeIDs.insert(key)
            let rectInView = canvasRectToViewRect(card.box)
            let handleRect: CGRect
            if let chrome = card.windowChrome {
                let winRect = canvasRectToViewRect(chrome.box)
                let scaleY = bounds.height / max(1, canvasSize.height)
                let hdrH = max(22, CGFloat(chrome.headerHeight) * scaleY)
                handleRect = CGRect(x: winRect.origin.x, y: winRect.origin.y, width: winRect.width, height: hdrH)
            } else {
                handleRect = CGRect(x: rectInView.origin.x, y: rectInView.origin.y, width: rectInView.width, height: min(32, rectInView.height))
            }

            if let existing = cardHandleViews[key] {
                existing.card = card
                existing.frame = handleRect
                existing.needsLayout = true
            } else {
                let handle = ClickyCardDragHandleView(
                    card: card,
                    frame: handleRect,
                    onClose: { [weak self] targetCard in
                        self?.onCardCloseRequested?(targetCard)
                    },
                    onZoom: { [weak self] targetCard in
                        self?.onCardZoomRequested?(targetCard)
                    },
                    onPin: { [weak self] targetCard in
                        self?.onCardPinRequested?(targetCard)
                    },
                    onSaveAsVideo: { [weak self] in
                        self?.onSaveAsVideoRequested?()
                    },
                    onShowBig: { [weak self] targetCard in
                        self?.onCardShowBigRequested?(targetCard)
                    },
                    onDragDelta: { [weak self] targetCard, deltaInView, isFinished in
                        self?.handleCardDrag(card: targetCard, deltaInView: deltaInView, finished: isFinished)
                    }
                )
                interactiveOverlayContainer.addSubview(handle)
                cardHandleViews[key] = handle
            }
        }

        for (key, handle) in cardHandleViews where !activeIDs.contains(key) {
            handle.removeFromSuperview()
            cardHandleViews.removeValue(forKey: key)
        }
    }

    private func handleCardDrag(card: ClickyDrawingCard, deltaInView: CGPoint, finished: Bool) {
        let scaleX = bounds.width / max(1, canvasSize.width)
        let scaleY = bounds.height / max(1, canvasSize.height)
        let dxCanvas = deltaInView.x / max(0.001, scaleX)
        let dyCanvas = deltaInView.y / max(0.001, scaleY)

        if draggingCard?.id != card.id {
            draggingCard = card
            dragAccumulatedDelta = .zero
        }
        dragAccumulatedDelta.x += dxCanvas
        dragAccumulatedDelta.y += dyCanvas

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for unitID in card.unitNodeIDs {
            if let layer = layersByNodeID[unitID] {
                layer.position = CGPoint(x: layer.position.x + dxCanvas, y: layer.position.y + dyCanvas)
            }
        }
        CATransaction.commit()

        if finished {
            let finalDelta = dragAccumulatedDelta
            draggingCard = nil
            dragAccumulatedDelta = .zero
            onCardMoved?(card, finalDelta)
        }
    }

    // MARK: - Op Application

    private func removeNode(id: Int) {
        if let layer = layersByNodeID.removeValue(forKey: id) {
            layer.removeFromSuperlayer()
        }
        parentGroupByNodeID.removeValue(forKey: id)
        maskTargetOpacityByNodeID.removeValue(forKey: id)
    }

    private func wrapNode(childID: Int, inGroupID groupID: Int) {
        guard let childLayer = layersByNodeID[childID],
              let parent = childLayer.superlayer else { return }

        let wrapper = CALayer()
        wrapper.frame = renderRootLayer.bounds
        wrapper.anchorPoint = .zero
        wrapper.position = .zero
        wrapper.masksToBounds = false

        if let idx = parent.sublayers?.firstIndex(of: childLayer) {
            parent.insertSublayer(wrapper, at: UInt32(idx))
        } else {
            parent.addSublayer(wrapper)
        }
        childLayer.removeFromSuperlayer()
        wrapper.addSublayer(childLayer)

        layersByNodeID[groupID] = wrapper
        if let groupName = parentGroupByNodeID[childID] {
            parentGroupByNodeID[groupID] = groupName
        }
    }

    private func applySetOp(node: ClickyRenderNode, group: String, beforeNodeID: Int?) {
        if group == "defs" {
            registerDefsNode(node)
            return
        }

        // Special 3D stage/part/label/motion/camera/tick marks
        if handleSpecial3DNode(node) {
            return
        }

        let targetParent = groupLayer(for: group)
        let existing = layersByNodeID[node.nodeID]
        let insertionIndex: UInt32?
        if let beforeID = beforeNodeID,
           let beforeLayer = layersByNodeID[beforeID],
           beforeLayer.superlayer === targetParent,
           let idx = targetParent.sublayers?.firstIndex(of: beforeLayer) {
            insertionIndex = UInt32(idx)
        } else if let existing, existing.superlayer === targetParent,
                  let idx = targetParent.sublayers?.firstIndex(of: existing) {
            insertionIndex = UInt32(idx)
        } else {
            insertionIndex = nil
        }

        existing?.removeFromSuperlayer()

        let builtLayer = buildLayer(for: node)
        layersByNodeID[node.nodeID] = builtLayer
        parentGroupByNodeID[node.nodeID] = group

        if let idx = insertionIndex {
            targetParent.insertSublayer(builtLayer, at: idx)
        } else {
            targetParent.addSublayer(builtLayer)
        }

        applyAnimationIfNeeded(node.animation, to: builtLayer, node: node)
    }

    private func registerDefsNode(_ node: ClickyRenderNode) {
        if node.tag == "mask", let maskID = node.attributes["id"] {
            if let pathChild = node.children.first(where: { $0.tag == "path" }) {
                let d = pathChild.attributes["d"] ?? ""
                let sw = CGFloat(Double(pathChild.attributes["stroke-width"] ?? "6") ?? 6)
                maskSpecsByID[maskID] = MaskSpec(
                    id: maskID,
                    pathData: d,
                    strokeWidth: sw,
                    animation: pathChild.animation
                )
            }
        } else {
            for child in node.children {
                registerDefsNode(child)
            }
        }
    }

    private func handleSpecial3DNode(_ node: ClickyRenderNode) -> Bool {
        switch node.tag {
        case "scene3d":
            guard let stageID = node.attributes["id"] else { return true }
            let x = Double(node.attributes["x"] ?? "0") ?? 0
            let y = Double(node.attributes["y"] ?? "0") ?? 0
            let w = Double(node.attributes["width"] ?? "200") ?? 200
            let h = Double(node.attributes["height"] ?? "200") ?? 200
            let canvasRect = CGRect(x: x, y: y, width: w, height: h)
            let viewRect = canvasRectToViewRect(canvasRect)
            let look = node.attributes["data-look"]
            let cameraJSON = node.attributes["data-camera"]

            if let existing = stageViewsByID[stageID] {
                existing.updateStageFrame(viewRect)
            } else {
                let stageView = ClickyThreeStageView(
                    stageID: stageID,
                    frame: viewRect,
                    look: look,
                    cameraJSON: cameraJSON
                )
                stageView.onTickSample = { [weak self] sID, ticks, dt in
                    self?.onTick3DRequested?(sID, ticks, dt)
                }
                stageView.onProjectedLabelsUpdated = { [weak self] projections in
                    self?.updateProjectedLabels(stageID: stageID, projections: projections)
                }
                interactiveOverlayContainer.addSubview(stageView)
                stageViewsByID[stageID] = stageView
            }
            return true

        case "part3d":
            if let stageID = node.attributes["data-stage"],
               let partJSON = node.attributes["data-part"],
               let stageView = stageViewsByID[stageID] {
                stageView.addOrUpdatePart(partJSON: partJSON)
            }
            return true

        case "tick3d":
            if let stageID = node.attributes["data-stage"],
               let tickID = node.attributes["data-tick"],
               let stageView = stageViewsByID[stageID] {
                stageView.addTick(tickID: tickID)
            }
            return true

        case "motion3d":
            if let stageID = node.attributes["data-stage"],
               let opJSON = node.attributes["data-op"],
               let stageView = stageViewsByID[stageID] {
                stageView.applyMotion(opJSON: opJSON)
            }
            return true

        case "camera3d":
            if let stageID = node.attributes["data-stage"],
               let opJSON = node.attributes["data-op"],
               let stageView = stageViewsByID[stageID] {
                stageView.applyCameraConfig(jsonString: opJSON)
            }
            return true

        case "label3d":
            if let stageID = node.attributes["data-stage"],
               let labelJSON = node.attributes["data-label"],
               let stageView = stageViewsByID[stageID] {
                let fillColor = NSColor.clickyHex(node.attributes["fill"] ?? "#FFFFFF") ?? .white
                stageView.addLabel(labelJSON: labelJSON, fallbackColor: fillColor)
            }
            return true

        default:
            return false
        }
    }

    private func updateProjectedLabels(stageID: String, projections: [ClickyThreeStageView.LabelProjection]) {
        // Always use the stage's current frame (cards can be dragged/resized after the closure was created).
        guard let stageFrame = stageViewsByID[stageID]?.frame else { return }
        stage3DProjectedLabels[stageID] = projections
        let scaleX = max(0.001, bounds.width / max(1, canvasSize.width))
        let scaleY = max(0.001, bounds.height / max(1, canvasSize.height))
        let visibleViewRect = stageFrame.intersection(bounds)
        let visibleCanvasRect = CGRect(
            x: visibleViewRect.origin.x / scaleX,
            y: visibleViewRect.origin.y / scaleY,
            width: visibleViewRect.width / scaleX,
            height: visibleViewRect.height / scaleY
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for proj in projections {
            let canvasX = (stageFrame.origin.x + proj.point2D.x) / scaleX
            let canvasY = (stageFrame.origin.y + proj.point2D.y) / scaleY

            let family = "'Patrick Hand', cursive"
            let labelWidth = projectedLabelWidth(id: proj.id, text: proj.text, family: family, size: Double(proj.size))
            let placement = ClickyLabelPlacement.place(
                point: CGPoint(x: canvasX, y: canvasY),
                side: proj.side,
                labelSize: CGSize(width: labelWidth, height: proj.size * 1.3),
                visibleBounds: visibleCanvasRect
            )
            let anchor: String = placement.side == "left" ? "end" : placement.side == "right" ? "start" : "middle"
            let desc = ClickyRenderTextDescription(
                family: family,
                size: Double(proj.size),
                weight: 400,
                anchor: anchor,
                baseline: "middle",
                x: Double(placement.anchorX),
                y: Double(placement.centerY),
                lines: [ClickyRenderTextLine(x: nil, dy: 0, text: proj.text)]
            )

            if let existing = projectedLabelLayers[proj.id] {
                existing.update(text: desc, fillColor: proj.color, knockoutColor: nil, knockoutWidth: 0)
            } else {
                let layer = ClickyCoreTextLayer(text: desc, fillColor: proj.color, knockoutColor: nil, knockoutWidth: 0)
                wordsLayer.addSublayer(layer)
                projectedLabelLayers[proj.id] = layer
            }
        }
        CATransaction.commit()
    }

    /// Text width only changes when the label text/size changes, so it is measured once per label.
    private func projectedLabelWidth(id: String, text: String, family: String, size: Double) -> CGFloat {
        if let cached = projectedLabelWidthCache[id], cached.text == text, cached.size == size {
            return cached.width
        }
        let font = ClickyDrawFontRegistry.ctFont(family: family, size: CGFloat(size), weight: 400)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        projectedLabelWidthCache[id] = (text: text, size: size, width: width)
        return width
    }

    private func applyPropOp(_ op: ClickyRenderOp) {
        if let maskID = op.maskID, op.propKey == "dash" {
            let val = CGFloat((op.propValue as? NSNumber)?.doubleValue ?? 0)
            let strokeEnd = max(0, min(1, 1.0 - val))
            for maskLayer in maskLayersByID[maskID] ?? [] {
                maskLayer.strokeEnd = strokeEnd
            }
            return
        }

        guard let nodeID = op.nodeID, let layer = layersByNodeID[nodeID] else { return }
        switch op.propKey {
        case "opacity":
            let val = Float((op.propValue as? NSNumber)?.doubleValue ?? 1)
            layer.opacity = val
            maskTargetOpacityByNodeID[nodeID] = val
        case "transform":
            if let xfStr = op.propValue as? String {
                layer.transform = parseSVGTransform(xfStr)
            }
        default:
            break
        }
    }

    private func applyStopOp(_ op: ClickyRenderOp) {
        if let maskID = op.maskID {
            for maskLayer in maskLayersByID[maskID] ?? [] {
                maskLayer.removeAllAnimations()
                maskLayer.strokeEnd = 1.0
            }
            return
        }
        guard let nodeID = op.nodeID, let layer = layersByNodeID[nodeID] else { return }
        layer.removeAllAnimations()
        layer.mask?.removeAllAnimations()
        if let targetOpacity = maskTargetOpacityByNodeID[nodeID] {
            layer.opacity = targetOpacity
        } else {
            layer.opacity = 1
        }
    }

    private func applyMotionOp(_ op: ClickyRenderOp) {
        let now = CACurrentMediaTime()
        let begin = max(now, op.motionBegin ?? now)
        let dur = max(0.01, op.motionDuration ?? 0.35)
        let fn = timingFunction(from: op.motionTiming ?? [0.455, 0.03, 0.515, 0.955])
        let timeOffset = begin - now

        for item in op.motionItems {
            if item.key == "dash", let maskID = item.maskID {
                let fromDash = (item.from as? NSNumber)?.doubleValue ?? 0
                let toDash = (item.to as? NSNumber)?.doubleValue ?? 1
                let fromEnd = CGFloat(max(0, min(1, 1.0 - fromDash)))
                let toEnd = CGFloat(max(0, min(1, 1.0 - toDash)))

                for maskLayer in maskLayersByID[maskID] ?? [] {
                    let anim = CABasicAnimation(keyPath: "strokeEnd")
                    anim.fromValue = fromEnd
                    anim.toValue = toEnd
                    anim.duration = dur
                    anim.timingFunction = fn
                    anim.beginTime = CACurrentMediaTime() + timeOffset
                    anim.fillMode = .backwards
                    maskLayer.strokeEnd = toEnd
                    maskLayer.add(anim, forKey: "motion-dash")
                }
                continue
            }

            guard let nodeID = item.nodeID, let layer = layersByNodeID[nodeID] else { continue }
            switch item.key {
            case "opacity":
                let fromVal = Float((item.from as? NSNumber)?.doubleValue ?? Double(layer.opacity))
                let toVal = Float((item.to as? NSNumber)?.doubleValue ?? 1)
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = fromVal
                anim.toValue = toVal
                anim.duration = dur
                anim.timingFunction = fn
                anim.beginTime = CACurrentMediaTime() + timeOffset
                anim.fillMode = .backwards
                layer.opacity = toVal
                maskTargetOpacityByNodeID[nodeID] = toVal
                layer.add(anim, forKey: "motion-opacity")

            case "transform":
                guard let fromArr = (item.from as? [NSNumber])?.map({ $0.doubleValue }),
                      let toArr = (item.to as? [NSNumber])?.map({ $0.doubleValue }),
                      fromArr.count == 3, toArr.count == 3 else { continue }
                let fromXF = makeTransform(scale: fromArr[0], tx: fromArr[1], ty: fromArr[2])
                let toXF = makeTransform(scale: toArr[0], tx: toArr[1], ty: toArr[2])
                let anim = CABasicAnimation(keyPath: "transform")
                anim.fromValue = NSValue(caTransform3D: fromXF)
                anim.toValue = NSValue(caTransform3D: toXF)
                anim.duration = dur
                anim.timingFunction = fn
                anim.beginTime = CACurrentMediaTime() + timeOffset
                anim.fillMode = .backwards
                layer.transform = toXF
                layer.add(anim, forKey: "motion-transform")

            default:
                break
            }
        }
    }

    // MARK: - Layer Construction

    private func buildLayer(for node: ClickyRenderNode) -> CALayer {
        switch node.tag {
        case "path":
            return buildPathLayer(for: node)
        case "circle":
            return buildCircleLayer(for: node)
        case "text":
            return buildTextLayer(for: node)
        case "window":
            return buildWindowLayer(for: node)
        case "photo":
            return buildPhotoLayer(for: node)
        case "g", "svg", "div":
            let container = CALayer()
            container.frame = renderRootLayer.bounds
            container.anchorPoint = .zero
            container.position = .zero
            container.masksToBounds = false
            if let xfStr = node.attributes["transform"] {
                container.transform = parseSVGTransform(xfStr)
            }
            for child in node.children {
                let childLayer = buildLayer(for: child)
                layersByNodeID[child.nodeID] = childLayer
                container.addSublayer(childLayer)
                applyAnimationIfNeeded(child.animation, to: childLayer, node: child)
            }
            return container
        default:
            let fallback = CALayer()
            fallback.frame = .zero
            return fallback
        }
    }

    private func buildPathLayer(for node: ClickyRenderNode) -> CALayer {
        let shape = CAShapeLayer()
        shape.frame = renderRootLayer.bounds
        shape.anchorPoint = .zero
        shape.position = .zero
        shape.masksToBounds = false

        let d = node.attributes["d"] ?? ""
        shape.path = ClickySVGPathParser.cgPath(from: d)

        if let fillStr = node.attributes["fill"], let fillColor = NSColor.clickyHex(fillStr) {
            let alpha = CGFloat(Double(node.attributes["fill-opacity"] ?? "1") ?? 1)
            shape.fillColor = fillColor.withAlphaComponent(alpha).cgColor
        } else {
            shape.fillColor = nil
        }

        if let strokeStr = node.attributes["stroke"], let strokeColor = NSColor.clickyHex(strokeStr) {
            let alpha = CGFloat(Double(node.attributes["stroke-opacity"] ?? "1") ?? 1)
            shape.strokeColor = strokeColor.withAlphaComponent(alpha).cgColor
            shape.lineWidth = CGFloat(Double(node.attributes["stroke-width"] ?? "2") ?? 2)
            shape.lineCap = node.attributes["stroke-linecap"] == "round" ? .round : .butt
            shape.lineJoin = node.attributes["stroke-linejoin"] == "round" ? .round : .miter
            if let dash = node.attributes["stroke-dasharray"] {
                let parts = dash.split(separator: " ").compactMap { Double($0) }.map { NSNumber(value: $0) }
                if !parts.isEmpty {
                    shape.lineDashPattern = parts
                }
            }
        } else {
            shape.strokeColor = nil
        }

        if let xf = node.attributes["transform"] {
            shape.transform = parseSVGTransform(xf)
        }

        // Glow shadow from Clicky's screen pen (`data-glow="0.650 12.00"`)
        if let glowAttr = node.attributes["data-glow"] {
            let parts = glowAttr.split(separator: " ").compactMap { Double($0) }
            if parts.count == 2 {
                let shadowColor = NSColor.clickyHex(node.attributes["fill"] ?? "") ?? activeInkColor
                shape.shadowColor = shadowColor.cgColor
                shape.shadowOpacity = Float(parts[0])
                shape.shadowRadius = CGFloat(parts[1])
                shape.shadowOffset = .zero
            }
        }

        // Attach pen-reveal mask if referenced (`mask="url(#cd1_m0)"`)
        if let maskAttr = node.attributes["mask"],
           let maskID = extractMaskID(from: maskAttr),
           let spec = maskSpecsByID[maskID] {
            let maskShape = CAShapeLayer()
            maskShape.frame = renderRootLayer.bounds
            maskShape.path = ClickySVGPathParser.cgPath(from: spec.pathData)
            maskShape.fillColor = nil
            maskShape.strokeColor = NSColor.white.cgColor
            maskShape.lineWidth = spec.strokeWidth
            maskShape.lineCap = .round
            maskShape.lineJoin = .round
            maskShape.strokeStart = 0
            maskShape.strokeEnd = 1

            shape.mask = maskShape
            maskLayersByID[maskID, default: []].append(maskShape)

            if let penAnim = spec.animation {
                applyPenRevealAnimation(penAnim, to: maskShape, pathData: spec.pathData)
            }
        }

        return shape
    }

    private func buildCircleLayer(for node: ClickyRenderNode) -> CALayer {
        let cx = CGFloat(Double(node.attributes["cx"] ?? "0") ?? 0)
        let cy = CGFloat(Double(node.attributes["cy"] ?? "0") ?? 0)
        let r = CGFloat(Double(node.attributes["r"] ?? "3") ?? 3)

        let shape = CAShapeLayer()
        shape.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        shape.position = CGPoint(x: cx, y: cy)
        shape.path = CGPath(ellipseIn: shape.bounds, transform: nil)
        if let fillStr = node.attributes["fill"], let fillColor = NSColor.clickyHex(fillStr) {
            let alpha = CGFloat(Double(node.attributes["fill-opacity"] ?? "1") ?? 1)
            shape.fillColor = fillColor.withAlphaComponent(alpha).cgColor
        } else {
            shape.fillColor = nil
        }
        return shape
    }

    private func buildTextLayer(for node: ClickyRenderNode) -> CALayer {
        guard let textDesc = node.text else { return CALayer() }
        let fillColor = NSColor.clickyHex(node.attributes["fill"] ?? "#30333A") ?? .white
        let knockoutColor = node.attributes["data-knockout"].flatMap { NSColor.clickyHex($0) }
        let knockoutWidth = CGFloat(Double(node.attributes["data-knockout-width"] ?? "0") ?? 0)

        let textLayer = ClickyCoreTextLayer(
            text: textDesc,
            fillColor: fillColor,
            knockoutColor: knockoutColor,
            knockoutWidth: knockoutWidth
        )
        if let xf = node.attributes["transform"] {
            textLayer.transform = parseSVGTransform(xf)
        }
        return textLayer
    }

    private func buildWindowLayer(for node: ClickyRenderNode) -> CALayer {
        let x = CGFloat(Double(node.attributes["x"] ?? "0") ?? 0)
        let y = CGFloat(Double(node.attributes["y"] ?? "0") ?? 0)
        let w = CGFloat(Double(node.attributes["width"] ?? "300") ?? 300)
        let h = CGFloat(Double(node.attributes["height"] ?? "200") ?? 200)
        let headerH = CGFloat(Double(node.attributes["data-header"] ?? "28") ?? 28)
        let title = node.attributes["data-title"] ?? ""
        let board = node.attributes["data-board"] ?? "grid"
        let bgColor = NSColor.clickyHex(node.attributes["data-bg"] ?? "#EFF2F6") ?? NSColor(white: 0.95, alpha: 1)
        let tintColor = NSColor.clickyHex(node.attributes["data-tint"] ?? "#0F7FFF") ?? activeInkColor
        let tintAlpha = CGFloat(Double(node.attributes["data-tint-alpha"] ?? "0.08") ?? 0.08)

        let container = CALayer()
        container.frame = CGRect(x: x, y: y, width: w, height: h)
        container.cornerRadius = 10
        container.backgroundColor = bgColor.cgColor
        container.borderWidth = 1.0
        container.borderColor = NSColor(white: 0.16, alpha: 0.45).cgColor
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.16
        container.shadowRadius = 14
        container.shadowOffset = CGSize(width: 0, height: 6)

        // Board grid/dots pattern layer
        if board == "grid" || board == "dots" {
            let patternLayer = ClickyWindowBoardLayer(board: board, frame: CGRect(x: 0, y: headerH, width: w, height: max(0, h - headerH)))
            patternLayer.cornerRadius = 10
            patternLayer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            patternLayer.masksToBounds = true
            container.addSublayer(patternLayer)
        }

        // Title bar
        let titleBar = CALayer()
        titleBar.frame = CGRect(x: 0, y: 0, width: w, height: headerH)
        titleBar.cornerRadius = 10
        titleBar.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        titleBar.backgroundColor = NSColor(srgbRed: 0.89, green: 0.89, blue: 0.90, alpha: 1.0).cgColor
        container.addSublayer(titleBar)

        let tintOverlay = CALayer()
        tintOverlay.frame = titleBar.bounds
        tintOverlay.cornerRadius = 10
        tintOverlay.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        tintOverlay.backgroundColor = tintColor.withAlphaComponent(tintAlpha).cgColor
        titleBar.addSublayer(tintOverlay)

        let divider = CALayer()
        divider.frame = CGRect(x: 0, y: headerH - 0.5, width: w, height: 0.5)
        divider.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
        titleBar.addSublayer(divider)

        // Traffic light dots (red close + green zoom + yellow pin-to-side)
        let dotColors = [
            NSColor(srgbRed: 1.0, green: 0.45, blue: 0.42, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.76, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 1.0, green: 0.80, blue: 0.20, alpha: 1)
        ]
        for (idx, dotColor) in dotColors.enumerated() {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 11, height: 11)
            dot.cornerRadius = 5.5
            dot.position = CGPoint(x: 16 + CGFloat(idx) * 20, y: headerH / 2)
            dot.backgroundColor = dotColor.cgColor
            titleBar.addSublayer(dot)
        }

        if !title.isEmpty {
            let titleDesc = ClickyRenderTextDescription(
                family: "system-ui, sans-serif",
                size: 13,
                weight: 600,
                anchor: "middle",
                baseline: "middle",
                x: Double(w / 2),
                y: Double(headerH / 2),
                lines: [ClickyRenderTextLine(x: nil, dy: 0, text: title.lowercased())]
            )
            let titleLayer = ClickyCoreTextLayer(
                text: titleDesc,
                fillColor: NSColor(srgbRed: 0.49, green: 0.51, blue: 0.55, alpha: 1),
                knockoutColor: nil,
                knockoutWidth: 0
            )
            titleBar.addSublayer(titleLayer)
        }

        return container
    }

    private func buildPhotoLayer(for node: ClickyRenderNode) -> CALayer {
        let x = CGFloat(Double(node.attributes["x"] ?? "0") ?? 0)
        let y = CGFloat(Double(node.attributes["y"] ?? "0") ?? 0)
        let w = CGFloat(Double(node.attributes["width"] ?? "120") ?? 120)
        let h = CGFloat(Double(node.attributes["height"] ?? "120") ?? 120)
        let radius = CGFloat(Double(node.attributes["data-radius"] ?? "2") ?? 2)
        let rotDeg = CGFloat(Double(node.attributes["data-rotate"] ?? "0") ?? 0)
        let query = node.attributes["data-query"] ?? ""

        let photoLayer = CALayer()
        photoLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        photoLayer.position = CGPoint(x: x + w / 2, y: y + h / 2)
        photoLayer.cornerRadius = radius
        photoLayer.masksToBounds = true
        photoLayer.backgroundColor = NSColor(white: 0.88, alpha: 1.0).cgColor
        photoLayer.contentsGravity = .resizeAspectFill
        if rotDeg != 0 {
            photoLayer.transform = CATransform3DMakeRotation(rotDeg * .pi / 180.0, 0, 0, 1)
        }

        // Load favicon for source credits (`favicon: host`)
        if query.hasPrefix("favicon:") {
            let host = query.replacingOccurrences(of: "favicon:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let faviconURL = URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(host)") {
                Task { @MainActor in
                    if let (data, _) = try? await URLSession.shared.data(from: faviconURL),
                       let img = NSImage(data: data) {
                        photoLayer.backgroundColor = NSColor.clear.cgColor
                        photoLayer.contents = img
                    }
                }
            }
        }
        return photoLayer
    }

    // MARK: - Animations

    private func applyPenRevealAnimation(_ anim: ClickyRenderAnimation, to maskLayer: CAShapeLayer, pathData: String) {
        let now = CACurrentMediaTime()
        let beginOffset = max(0, (anim.startedAt + anim.delay) - now)
        let dur = max(0.05, anim.duration)

        let strokeAnim = CABasicAnimation(keyPath: "strokeEnd")
        strokeAnim.fromValue = 0.0
        strokeAnim.toValue = 1.0
        strokeAnim.duration = dur
        strokeAnim.timingFunction = timingFunction(from: anim.timing)
        strokeAnim.beginTime = now + beginOffset
        strokeAnim.fillMode = .backwards
        maskLayer.strokeEnd = 1.0
        maskLayer.add(strokeAnim, forKey: "pen-reveal")

        // Move pen follower along the path while drawing
        let cgPath = ClickySVGPathParser.cgPath(from: pathData)
        if !cgPath.boundingBoxOfPath.isEmpty {
            let posAnim = CAKeyframeAnimation(keyPath: "position")
            posAnim.path = cgPath
            posAnim.duration = dur
            posAnim.timingFunction = timingFunction(from: anim.timing)
            posAnim.beginTime = now + beginOffset
            // Hold the stroke's start before it begins and its end after, so the cursor waits in place.
            posAnim.fillMode = .both
            posAnim.isRemovedOnCompletion = false
            posAnim.rotationMode = .rotateAuto
            penFollowerLayer.add(posAnim, forKey: "pen-pos")
            showPenCursor()
        }
    }

    private func applyAnimationIfNeeded(_ anim: ClickyRenderAnimation?, to layer: CALayer, node: ClickyRenderNode) {
        guard let anim else { return }
        let now = CACurrentMediaTime()
        let beginOffset = max(0, (anim.startedAt + anim.delay) - now)
        let dur = max(0.05, anim.duration)
        let fn = timingFunction(from: anim.timing)

        switch anim.name {
        case "fadein":
            let targetOpacity = layer.opacity
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = targetOpacity
            fade.duration = dur
            fade.timingFunction = fn
            fade.beginTime = now + beginOffset
            fade.fillMode = .backwards
            layer.add(fade, forKey: "anim-fadein")

        case "write":
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = layer.opacity
            fade.duration = min(0.25, dur * 0.5)
            fade.timingFunction = fn
            fade.beginTime = now + beginOffset
            fade.fillMode = .backwards
            layer.add(fade, forKey: "anim-write")

        case "pop":
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.2, 1.12, 1.0]
            scale.keyTimes = [0.0, 0.7, 1.0]
            scale.duration = dur
            scale.timingFunction = fn
            scale.beginTime = now + beginOffset
            scale.fillMode = .backwards
            layer.add(scale, forKey: "anim-pop")

        case "swipe":
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = layer.opacity
            fade.duration = dur
            fade.timingFunction = fn
            fade.beginTime = now + beginOffset
            fade.fillMode = .backwards
            layer.add(fade, forKey: "anim-swipe")

        case "marquee":
            if let marqueeAttr = node.attributes["data-marquee"] {
                let parts = marqueeAttr.split(separator: " ").compactMap { Double($0) }
                if parts.count == 4 {
                    let box = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                    let mask = CALayer()
                    mask.backgroundColor = NSColor.white.cgColor
                    mask.anchorPoint = .zero
                    mask.position = box.origin
                    mask.bounds = CGRect(origin: .zero, size: box.size)
                    layer.mask = mask

                    let boundsAnim = CABasicAnimation(keyPath: "bounds.size")
                    boundsAnim.fromValue = NSValue(size: .zero)
                    boundsAnim.toValue = NSValue(size: box.size)
                    boundsAnim.duration = dur
                    boundsAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    boundsAnim.beginTime = now + beginOffset
                    boundsAnim.fillMode = .backwards
                    mask.add(boundsAnim, forKey: "anim-marquee")
                }
            }

        default:
            break
        }
    }

    // MARK: - Helpers

    private func groupLayer(for groupName: String) -> CALayer {
        switch groupName {
        case "under": return underLayer
        case "hl": return highlightLayer
        case "words": return wordsLayer
        default: return mainLayer
        }
    }

    private func canvasRectToViewRect(_ rect: CGRect) -> CGRect {
        let scaleX = bounds.width / max(1, canvasSize.width)
        let scaleY = bounds.height / max(1, canvasSize.height)
        return CGRect(
            x: rect.origin.x * scaleX,
            y: rect.origin.y * scaleY,
            width: rect.size.width * scaleX,
            height: rect.size.height * scaleY
        )
    }

    private func repositionInteractiveElements() {
        for (markIndex, button) in actionButtonViews {
            if let payload = pendingButtons[markIndex] {
                button.frame = canvasRectToViewRect(payload.box)
            }
        }
        syncCards(visibleCards)
    }

    private func extractMaskID(from attr: String) -> String? {
        guard let start = attr.range(of: "url(#"),
              let end = attr.range(of: ")", range: start.upperBound..<attr.endIndex) else {
            return nil
        }
        return String(attr[start.upperBound..<end.lowerBound])
    }

    private func timingFunction(from points: [Double]) -> CAMediaTimingFunction {
        guard points.count == 4 else { return CAMediaTimingFunction(name: .easeInEaseOut) }
        return CAMediaTimingFunction(
            controlPoints: Float(points[0]), Float(points[1]), Float(points[2]), Float(points[3])
        )
    }

    private func makeTransform(scale: Double, tx: Double, ty: Double) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, CGFloat(tx), CGFloat(ty), 0)
        t = CATransform3DScale(t, CGFloat(scale), CGFloat(scale), 1)
        return t
    }

    private func parseSVGTransform(_ raw: String) -> CATransform3D {
        var result = CATransform3DIdentity
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let pattern = #"([a-zA-Z]+)\(([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))

        for match in matches {
            guard match.numberOfRanges == 3,
                  let fnRange = Range(match.range(at: 1), in: trimmed),
                  let argsRange = Range(match.range(at: 2), in: trimmed) else { continue }
            let fnName = String(trimmed[fnRange])
            let args = String(trimmed[argsRange])
                .replacingOccurrences(of: ",", with: " ")
                .split(separator: " ")
                .compactMap { Double($0) }

            switch fnName {
            case "translate":
                let tx = args.count > 0 ? args[0] : 0
                let ty = args.count > 1 ? args[1] : 0
                result = CATransform3DTranslate(result, CGFloat(tx), CGFloat(ty), 0)
            case "scale":
                let sx = args.count > 0 ? args[0] : 1
                let sy = args.count > 1 ? args[1] : sx
                result = CATransform3DScale(result, CGFloat(sx), CGFloat(sy), 1)
            case "rotate":
                let deg = args.count > 0 ? args[0] : 0
                let rad = CGFloat(deg * .pi / 180.0)
                if args.count >= 3 {
                    let cx = CGFloat(args[1]), cy = CGFloat(args[2])
                    result = CATransform3DTranslate(result, cx, cy, 0)
                    result = CATransform3DRotate(result, rad, 0, 0, 1)
                    result = CATransform3DTranslate(result, -cx, -cy, 0)
                } else {
                    result = CATransform3DRotate(result, rad, 0, 0, 1)
                }
            case "matrix":
                if args.count == 6 {
                    let m = CGAffineTransform(
                        a: CGFloat(args[0]), b: CGFloat(args[1]),
                        c: CGFloat(args[2]), d: CGFloat(args[3]),
                        tx: CGFloat(args[4]), ty: CGFloat(args[5])
                    )
                    result = CATransform3DConcat(CATransform3DMakeAffineTransform(m), result)
                }
            default:
                break
            }
        }
        return result
    }
}

// MARK: - Flipped Interactive Container

private final class ClickyFlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - CoreText Text Layer

private final class ClickyCoreTextLayer: CALayer {
    private nonisolated(unsafe) var textDesc: ClickyRenderTextDescription
    private nonisolated(unsafe) var fillColor: NSColor
    private nonisolated(unsafe) var knockoutColor: NSColor?
    private nonisolated(unsafe) var knockoutWidth: CGFloat

    init(text: ClickyRenderTextDescription, fillColor: NSColor, knockoutColor: NSColor?, knockoutWidth: CGFloat) {
        self.textDesc = text
        self.fillColor = fillColor
        self.knockoutColor = knockoutColor
        self.knockoutWidth = knockoutWidth
        super.init()
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        masksToBounds = false
        recomputeGeometry()
    }

    nonisolated override init(layer: Any) {
        let other = layer as! ClickyCoreTextLayer
        self.textDesc = other.textDesc
        self.fillColor = other.fillColor
        self.knockoutColor = other.knockoutColor
        self.knockoutWidth = other.knockoutWidth
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(text: ClickyRenderTextDescription, fillColor: NSColor, knockoutColor: NSColor?, knockoutWidth: CGFloat) {
        let isSameDrawing = Self.isSameDrawing(
            old: textDesc, new: text,
            oldFill: self.fillColor, newFill: fillColor,
            oldKnockout: self.knockoutColor, newKnockout: knockoutColor,
            oldKnockoutWidth: self.knockoutWidth, newKnockoutWidth: knockoutWidth
        )
        if isSameDrawing {
            // Only the position changed: glyphs are drawn relative to the layer origin, so just slide the layer.
            let deltaX = CGFloat(text.x - textDesc.x)
            let deltaY = CGFloat(text.y - textDesc.y)
            self.textDesc = text
            if deltaX != 0 || deltaY != 0 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                frame = frame.offsetBy(dx: deltaX, dy: deltaY)
                CATransaction.commit()
            }
            return
        }
        self.textDesc = text
        self.fillColor = fillColor
        self.knockoutColor = knockoutColor
        self.knockoutWidth = knockoutWidth
        recomputeGeometry()
    }

    private static func isSameDrawing(
        old: ClickyRenderTextDescription, new: ClickyRenderTextDescription,
        oldFill: NSColor, newFill: NSColor,
        oldKnockout: NSColor?, newKnockout: NSColor?,
        oldKnockoutWidth: CGFloat, newKnockoutWidth: CGFloat
    ) -> Bool {
        guard old.family == new.family, old.size == new.size, old.weight == new.weight,
              old.anchor == new.anchor, old.baseline == new.baseline,
              old.lines.count == new.lines.count,
              oldKnockoutWidth == newKnockoutWidth,
              oldFill == newFill, oldKnockout == newKnockout else { return false }
        return zip(old.lines, new.lines).allSatisfy { $0.text == $1.text && $0.dy == $1.dy && ($0.x == nil) == ($1.x == nil) }
    }

    private func recomputeGeometry() {
        let font = ClickyDrawFontRegistry.ctFont(
            family: textDesc.family,
            size: CGFloat(textDesc.size),
            weight: textDesc.weight
        )
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)

        var curX = CGFloat(textDesc.x)
        var curY = CGFloat(textDesc.y)
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for line in textDesc.lines {
            if let lx = line.x { curX = CGFloat(lx) }
            curY += CGFloat(line.dy)
            let attr = NSAttributedString(string: line.text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))

            let startX: CGFloat
            switch textDesc.anchor {
            case "middle": startX = curX - width / 2
            case "end": startX = curX - width
            default: startX = curX
            }

            let topY: CGFloat
            switch textDesc.baseline {
            case "middle", "central": topY = curY - (ascent + descent) / 2
            case "hanging": topY = curY
            default: topY = curY - ascent
            }

            minX = min(minX, startX)
            maxX = max(maxX, startX + width)
            minY = min(minY, topY)
            maxY = max(maxY, topY + ascent + descent)
        }

        let pad = max(4, knockoutWidth)
        if minX == .greatestFiniteMagnitude {
            frame = .zero
        } else {
            frame = CGRect(x: minX - pad, y: minY - pad, width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2)
        }
        setNeedsDisplay()
    }

    nonisolated override func draw(in ctx: CGContext) {
        let font = ClickyDrawFontRegistry.ctFont(
            family: textDesc.family,
            size: CGFloat(textDesc.size),
            weight: textDesc.weight
        )
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)

        // Flip CoreText context so glyphs draw upright inside our flipped layer tree.
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: -bounds.origin.x, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        var curX = CGFloat(textDesc.x) - frame.origin.x
        var curY = CGFloat(textDesc.y) - frame.origin.y

        for line in textDesc.lines {
            if let lx = line.x { curX = CGFloat(lx) - frame.origin.x }
            curY += CGFloat(line.dy)

            let baselineFromTop: CGFloat
            switch textDesc.baseline {
            case "middle", "central": baselineFromTop = curY + (ascent - descent) / 2
            case "hanging": baselineFromTop = curY + ascent
            default: baselineFromTop = curY
            }

            let attrMeasure = NSAttributedString(string: line.text, attributes: [.font: font])
            let measureLine = CTLineCreateWithAttributedString(attrMeasure)
            let width = CGFloat(CTLineGetTypographicBounds(measureLine, nil, nil, nil))

            let drawX: CGFloat
            switch textDesc.anchor {
            case "middle": drawX = curX - width / 2
            case "end": drawX = curX - width
            default: drawX = curX
            }
            let drawY = bounds.height - baselineFromTop

            if let knockoutColor, knockoutWidth > 0 {
                let strokeAttr: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .strokeColor: knockoutColor,
                    .strokeWidth: NSNumber(value: Float(knockoutWidth * 2)),
                    .foregroundColor: knockoutColor
                ]
                let haloLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: strokeAttr))
                ctx.textPosition = CGPoint(x: drawX, y: drawY)
                CTLineDraw(haloLine, ctx)
            }

            let fillAttr: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fillColor
            ]
            let fillLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: fillAttr))
            ctx.textPosition = CGPoint(x: drawX, y: drawY)
            CTLineDraw(fillLine, ctx)
        }

        ctx.restoreGState()
    }
}

// MARK: - Window Board Grid/Dots Layer

private final class ClickyWindowBoardLayer: CALayer {
    private nonisolated let boardStyle: String

    init(board: String, frame: CGRect) {
        self.boardStyle = board
        super.init()
        self.frame = frame
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        setNeedsDisplay()
    }

    nonisolated override init(layer: Any) {
        let other = layer as! ClickyWindowBoardLayer
        self.boardStyle = other.boardStyle
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override func draw(in ctx: CGContext) {
        let step: CGFloat = 24
        if boardStyle == "grid" {
            ctx.setStrokeColor(NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 0.85).cgColor)
            ctx.setLineWidth(0.75)
            var x: CGFloat = step
            while x < bounds.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
                x += step
            }
            var y: CGFloat = step
            while y < bounds.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
                y += step
            }
            ctx.strokePath()
        } else if boardStyle == "dots" {
            ctx.setFillColor(NSColor(srgbRed: 0.78, green: 0.80, blue: 0.84, alpha: 0.75).cgColor)
            var y: CGFloat = step
            while y < bounds.height {
                var x: CGFloat = step
                while x < bounds.width {
                    ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += step
                }
                y += step
            }
        }
    }
}

// MARK: - Interactive Action Pill Button

private final class ClickyActionPillButton: NSButton {
    let payload: ClickyActionButtonPayload
    private let onPress: (ClickyActionButtonPayload) -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(payload: ClickyActionButtonPayload, inkColor: NSColor, onPress: @escaping (ClickyActionButtonPayload) -> Void) {
        self.payload = payload
        self.onPress = onPress
        super.init(frame: payload.box)

        isBordered = false
        wantsLayer = true
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)

        let labelText = payload.kind == "open" ? "\(payload.text)  ↗" : payload.text
        let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let labelColor = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        title = labelText
        font = labelFont
        // Show what will actually happen/be sent, since the label may differ.
        if payload.kind == "ask", let promptText = payload.value as? String {
            toolTip = promptText
        } else if payload.kind == "open", let urlText = payload.value as? String {
            toolTip = urlText
        }
        attributedTitle = NSAttributedString(
            string: labelText,
            attributes: [
                .font: labelFont,
                .foregroundColor: labelColor
            ]
        )

        layer?.cornerRadius = payload.box.height / 2
        layer?.backgroundColor = NSColor(srgbRed: 0.93, green: 0.96, blue: 1.0, alpha: 0.96).cgColor
        layer?.borderWidth = 1.25
        layer?.borderColor = inkColor.withAlphaComponent(0.75).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: 2)

        target = self
        action = #selector(handleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleClick() {
        onPress(payload)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
        layer?.backgroundColor = NSColor.white.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
        layer?.backgroundColor = NSColor(srgbRed: 0.93, green: 0.96, blue: 1.0, alpha: 0.96).cgColor
    }
}

// MARK: - Interactive Card Drag Handle & Traffic Light Buttons

private final class ClickyCardDragHandleView: NSView {
    var card: ClickyDrawingCard
    private let onClose: (ClickyDrawingCard) -> Void
    private let onZoom: (ClickyDrawingCard) -> Void
    private let onPin: (ClickyDrawingCard) -> Void
    private let onSaveAsVideo: () -> Void
    private let onShowBig: (ClickyDrawingCard) -> Void
    private let onDragDelta: (ClickyDrawingCard, CGPoint, Bool) -> Void

    private let closeButton = NSButton()
    private let zoomButton = NSButton()
    private let pinButton = NSButton()
    private var lastDragScreenPoint: NSPoint?
    private var trackingArea: NSTrackingArea?

    init(
        card: ClickyDrawingCard,
        frame: CGRect,
        onClose: @escaping (ClickyDrawingCard) -> Void,
        onZoom: @escaping (ClickyDrawingCard) -> Void,
        onPin: @escaping (ClickyDrawingCard) -> Void,
        onSaveAsVideo: @escaping () -> Void,
        onShowBig: @escaping (ClickyDrawingCard) -> Void,
        onDragDelta: @escaping (ClickyDrawingCard, CGPoint, Bool) -> Void
    ) {
        self.card = card
        self.onClose = onClose
        self.onZoom = onZoom
        self.onPin = onPin
        self.onSaveAsVideo = onSaveAsVideo
        self.onShowBig = onShowBig
        self.onDragDelta = onDragDelta
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        if card.windowChrome != nil {
            setupWindowButtons()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hit-button frame for the dot at `dotIndex`. The dots are drawn inside the card, so their
    /// position and size scale with the card's chrome scale (zoomed or pinned cards).
    private func dotHitFrame(dotIndex: Int) -> CGRect {
        let chromeScale = CGFloat(card.windowChrome?.scale ?? 1.0)
        let hitSize = 14 * chromeScale
        let centerX = (16 + CGFloat(dotIndex) * 20) * chromeScale
        return CGRect(x: centerX - hitSize / 2, y: (bounds.height - hitSize) / 2, width: hitSize, height: hitSize)
    }

    private func configureInvisibleHitButton(_ button: NSButton, dotIndex: Int, action: Selector) {
        button.frame = dotHitFrame(dotIndex: dotIndex)
        button.isBordered = false
        button.title = ""
        button.wantsLayer = true
        button.layer?.cornerRadius = button.frame.width / 2
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func setupWindowButtons() {
        configureInvisibleHitButton(closeButton, dotIndex: 0, action: #selector(handleClose))
        if !(card.windowChrome?.has3D ?? false) {
            configureInvisibleHitButton(zoomButton, dotIndex: 1, action: #selector(handleZoom))
            configureInvisibleHitButton(pinButton, dotIndex: 2, action: #selector(handlePin))
        }
    }

    /// Frames depend on the card's chrome scale, which changes on zoom/pin without the handle always being recreated.
    override func layout() {
        super.layout()
        guard card.windowChrome != nil else { return }
        closeButton.frame = dotHitFrame(dotIndex: 0)
        zoomButton.frame = dotHitFrame(dotIndex: 1)
        pinButton.frame = dotHitFrame(dotIndex: 2)
        updatePinnedAccessibility()
    }

    /// A card parked at the side by the pin button (zoomed down to the pinned scale).
    private var isPinnedToSide: Bool {
        guard let chrome = card.windowChrome else { return false }
        return chrome.isZoomed && abs(chrome.scale - Double(ScreenAnnotationManager.pinnedCardScale)) < 0.05
    }

    private func updatePinnedAccessibility() {
        pinButton.toolTip = String(localized: "Pin to the side of the screen")
        pinButton.setAccessibilityLabel(String(localized: "Pin to the side of the screen"))
        if isPinnedToSide, let title = card.windowChrome?.title {
            let pinnedLabel = String(localized: "Pinned card: \(title)")
            setAccessibilityLabel(pinnedLabel)
            toolTip = pinnedLabel
        } else {
            setAccessibilityLabel(nil)
            toolTip = nil
        }
    }

    @objc private func handlePin() {
        onPin(card)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard card.windowChrome != nil else { return nil }
        let menu = NSMenu()
        if isPinnedToSide {
            let showBigItem = NSMenuItem(title: String(localized: "Show Big"), action: #selector(handleShowBig), keyEquivalent: "")
            showBigItem.target = self
            menu.addItem(showBigItem)
        }
        let saveItem = NSMenuItem(title: "Save as Video", action: #selector(handleSaveAsVideo), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)
        return menu
    }

    @objc private func handleShowBig() {
        onShowBig(card)
    }

    @objc private func handleSaveAsVideo() {
        onSaveAsVideo()
    }

    @objc private func handleClose() {
        onClose(card)
    }

    @objc private func handleZoom() {
        onZoom(card)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let isOverZoomButton = zoomButton.superview != nil && zoomButton.frame.contains(local)
        let isOverPinButton = pinButton.superview != nil && pinButton.frame.contains(local)
        if closeButton.frame.contains(local) || isOverZoomButton || isOverPinButton {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        lastDragScreenPoint = NSEvent.mouseLocation
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let prev = lastDragScreenPoint else { return }
        let cur = NSEvent.mouseLocation
        // NSEvent.mouseLocation has bottom-left origin; negate dy for flipped view coordinates
        let delta = CGPoint(x: cur.x - prev.x, y: -(cur.y - prev.y))
        lastDragScreenPoint = cur
        onDragDelta(card, delta, false)
    }

    override func mouseUp(with event: NSEvent) {
        lastDragScreenPoint = nil
        NSCursor.openHand.set()
        onDragDelta(card, .zero, true)
    }
}
