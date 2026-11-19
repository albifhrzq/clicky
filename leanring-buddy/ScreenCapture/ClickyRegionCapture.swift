//
//  ClickyRegionCapture.swift
//  leanring-buddy
//
//  Region capture: the user drags a box on screen, then sends that region with text
//  or voice, or queues it ("Don't send yet") so it rides along with the next question.
//

import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI
import Combine

/// One captured screen region waiting to be sent with the next question.
nonisolated struct ClickyQueuedRegion: Identifiable, Sendable {
    let id: UUID
    let imageData: Data
    let widthInPixels: Int
    let heightInPixels: Int
    var capturedAt: Date = Date()
}

enum ClickyRegionCaptureAction {
    case text
    case voice
    case queueOnly
}

@MainActor
final class ClickyRegionCaptureController: ObservableObject {
    static let shared = ClickyRegionCaptureController()

    @Published private(set) var queuedRegions: [ClickyQueuedRegion] = [] {
        didSet { refreshQueueChip() }
    }

    private weak var companionManager: CompanionManager?
    private var overlayWindowsByScreenID: [CGDirectDisplayID: ClickyRegionOverlayPanel] = [:]
    private var isOverlayVisible: Bool { !overlayWindowsByScreenID.isEmpty }
    private var isCompletingSuccessfulSelection = false
    private var hudPanel: NSPanel?
    private var voiceChipReturnKeyMonitor: Any?
    private var isRegionVoiceHoldActive = false
    private var queueChipPanel: NSPanel?
    private var queueExpiryTask: Task<Void, Never>?

    /// Called once at app start so the action bar can open text mode or start a voice turn.
    func attach(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    /// Starts the drag-to-capture overlay.
    func begin() {
        guard !isOverlayVisible, !isCompletingSuccessfulSelection else { return }
        guard CGPreflightScreenCaptureAccess() else {
            showScreenRecordingPermissionAlert()
            return
        }
        dismissHudPanel()

        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let overlayPanel = ClickyRegionOverlayPanel(screen: screen)
            overlayPanel.regionView.onRectCapturedWithAction = { [weak self] viewRect, action in
                self?.handleRectCaptured(viewRect: viewRect, screen: screen, action: action)
            }
            overlayPanel.regionView.onCancelled = { [weak self] in self?.closeAllOverlays() }
            overlayPanel.regionView.onSelectionStarted = { [weak self] in
                // Only one screen can own a selection; clear any frozen bar elsewhere.
                self?.overlayWindowsByScreenID.values.forEach { $0.regionView.resetSelection() }
            }
            overlayWindowsByScreenID[displayID] = overlayPanel
            overlayPanel.makeKeyAndOrderFront(nil)
            overlayPanel.makeFirstResponder(overlayPanel.regionView)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Returns the queued regions as labeled images for the LLM and empties the queue.
    func consumeQueuedRegionsAsLabeledImages() -> [(data: Data, label: String)] {
        dropExpiredQueuedRegions()
        guard !queuedRegions.isEmpty else { return [] }
        let labeledImages = queuedRegions.enumerated().map { regionIndex, queuedRegion in
            (
                data: queuedRegion.imageData,
                label: "region the user selected \(regionIndex + 1) (image dimensions: \(queuedRegion.widthInPixels)x\(queuedRegion.heightInPixels) pixels)"
            )
        }
        queuedRegions.removeAll()
        return labeledImages
    }

    // MARK: - Selection completion

    private func handleRectCaptured(viewRect: CGRect, screen: NSScreen, action: ClickyRegionCaptureAction) {
        let globalRect = ClickyRegionGeometry.globalScreenRect(fromFlippedViewRect: viewRect, screenFrame: screen.frame)
        guard !ClickyRegionGeometry.isOutsideScreen(globalRect: globalRect, screenFrame: screen.frame) else {
            overlayWindowsByScreenID.values.forEach {
                $0.regionView.showTransientHint(String(localized: "That region is outside the screen"))
            }
            return
        }
        isCompletingSuccessfulSelection = true
        closeAllOverlays()

        Task { @MainActor in
            defer { self.isCompletingSuccessfulSelection = false }
            // Give the window server a moment to remove the dim before capturing.
            try? await Task.sleep(nanoseconds: 120_000_000)
            do {
                let queuedRegion = try await Self.captureRegion(viewRect: viewRect, screen: screen)
                self.dropExpiredQueuedRegions()
                self.queuedRegions = ClickyRegionGeometry.appendingWithCap(queuedRegion, to: self.queuedRegions)
                self.performAction(action, nearGlobalRect: globalRect)
            } catch {
                print("⚠️ Region capture failed: \(error)")
                self.showHud(text: String(localized: "Couldn't capture that region"), nearGlobalRect: globalRect, duration: 2)
            }
        }
    }

    private func performAction(_ action: ClickyRegionCaptureAction, nearGlobalRect globalRect: CGRect) {
        switch action {
        case .queueOnly:
            showHud(text: ClickyRegionGeometry.queuedCountLabel(count: queuedRegions.count), nearGlobalRect: globalRect, duration: 1.5)
        case .text:
            companionManager?.openTextModeFromExternalTrigger()
        case .voice:
            companionManager?.handleExternalVoiceHold(isPressed: true)
            showVoiceChip(nearGlobalRect: globalRect)
        }
    }

    private static func captureRegion(viewRect: CGRect, screen: NSScreen) async throws -> ClickyQueuedRegion {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw NSError(domain: "ClickyRegionCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "Screen has no display ID"])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "ClickyRegionCapture", code: -2, userInfo: [NSLocalizedDescriptionKey: "Display not shareable"])
        }
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let clampedRect = ClickyRegionGeometry.clampedToBounds(viewRect, boundsSize: screen.frame.size)
        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = clampedRect // display-local points, top-left origin
        configuration.width = max(1, Int(clampedRect.width * scale))
        configuration.height = max(1, Int(clampedRect.height * scale))
        configuration.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "ClickyRegionCapture", code: -3, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"])
        }
        return ClickyQueuedRegion(id: UUID(), imageData: jpegData, widthInPixels: cgImage.width, heightInPixels: cgImage.height)
    }

    private func closeAllOverlays() {
        overlayWindowsByScreenID.values.forEach { $0.orderOut(nil) }
        overlayWindowsByScreenID.removeAll()
    }

    private func showScreenRecordingPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Screen Recording permission needed")
        alert.informativeText = String(localized: "Clicky needs Screen Recording access to capture a region. Turn it on in System Settings > Privacy & Security > Screen Recording.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            WindowPositionManager.openScreenRecordingSettings()
        }
    }

    // MARK: - HUD (toast and voice chip)

    /// Releases a voice hold started by "Send with voice" that was never finished (the orchestrator calls this on interrupt).
    func cancelRegionVoiceHoldIfActive() {
        dismissHudPanel()
    }

    private func dismissHudPanel() {
        if isRegionVoiceHoldActive {
            isRegionVoiceHoldActive = false
            companionManager?.handleExternalVoiceHold(isPressed: false)
        }
        if let voiceChipReturnKeyMonitor {
            NSEvent.removeMonitor(voiceChipReturnKeyMonitor)
            self.voiceChipReturnKeyMonitor = nil
        }
        hudPanel?.orderOut(nil)
        hudPanel = nil
    }

    private func presentHud<Content: View>(_ content: Content, nearGlobalRect globalRect: CGRect) {
        dismissHudPanel()
        let hostingView = NSHostingView(rootView: content)
        let size = hostingView.fittingSize
        let panel = ClickyRegionHudPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        // The default would hide the chip when Clicky deactivates, stranding the voice hold.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.setFrameOrigin(CGPoint(x: globalRect.midX - size.width / 2, y: max(globalRect.minY - size.height - 8, 8)))
        panel.orderFrontRegardless()
        hudPanel = panel
    }

    private func showHud(text: String, nearGlobalRect globalRect: CGRect, duration: TimeInterval) {
        presentHud(ClickyRegionHudChip(text: text, onClick: nil), nearGlobalRect: globalRect)
        let shownPanel = hudPanel
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.hudPanel === shownPanel { self?.dismissHudPanel() }
        }
    }

    private func showVoiceChip(nearGlobalRect globalRect: CGRect) {
        presentHud(
            ClickyRegionHudChip(text: String(localized: "Listening… click to send")) { [weak self] in self?.finishVoiceTurn() },
            nearGlobalRect: globalRect
        )
        isRegionVoiceHoldActive = true
        hudPanel?.makeKey()
        voiceChipReturnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only the chip itself may swallow Return; other Clicky windows keep their Return key.
            guard event.keyCode == 36, let self, event.window === self.hudPanel else { return event }
            self.finishVoiceTurn()
            return nil
        }
    }

    private func finishVoiceTurn() {
        dismissHudPanel() // also releases the voice hold
    }

    // MARK: - Queue chip and expiry

    private func dropExpiredQueuedRegions() {
        let freshRegions = ClickyRegionGeometry.droppingExpired(queuedRegions, capturedAt: \.capturedAt, now: Date())
        if freshRegions.count != queuedRegions.count { queuedRegions = freshRegions }
    }

    /// Keeps a small "N regions queued · Clear" chip on screen while anything is queued.
    private func refreshQueueChip() {
        queueExpiryTask?.cancel()
        guard !queuedRegions.isEmpty else {
            queueChipPanel?.orderOut(nil)
            queueChipPanel = nil
            return
        }
        queueExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((ClickyRegionGeometry.queuedRegionTimeToLiveSeconds + 1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dropExpiredQueuedRegions()
        }
        queueChipPanel?.orderOut(nil)
        let hostingView = NSHostingView(rootView: ClickyRegionQueueChip(
            text: ClickyRegionGeometry.queuedCountLabel(count: queuedRegions.count),
            onClear: { [weak self] in self?.queuedRegions.removeAll() }
        ))
        let size = hostingView.fittingSize
        let panel = ClickyRegionHudPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.minY + 16))
        panel.orderFrontRegardless()
        queueChipPanel = panel
    }
}

/// Borderless panel that may become key so the voice chip can see Return.
private final class ClickyRegionHudPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ClickyRegionQueueChip: View {
    let text: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            Text(verbatim: "·")
            Button(action: onClear) { Text("Clear").underline() }
                .buttonStyle(.plain)
                .pointerCursor()
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .padding(4)
    }
}

private struct ClickyRegionHudChip: View {
    let text: String
    let onClick: (() -> Void)?

    var body: some View {
        let label = Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .padding(4)
        if let onClick {
            Button(action: onClick) { label }.buttonStyle(.plain).pointerCursor()
        } else {
            label
        }
    }
}
