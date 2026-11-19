//
//  ClickyDrawingSaveOfferView.swift
//  leanring-buddy
//
//  The small card shown near the bottom-right of the drawing's screen after a drawing finishes:
//  "Save drawing" (records it as a video), recording progress, and "Show the video in Finder".
//  Drawings are already kept in Home → Drawings automatically, so "Keep" simply confirms and dismisses.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Recording state

public enum ClickyDrawingRecordingState: Equatable {
    case idle
    case recording(elapsedSeconds: TimeInterval, totalSeconds: TimeInterval)
    case saving
    case saved(URL)
    case failed(String)

    /// "m:ss" for a number of seconds (negative and NaN clamp to 0:00).
    nonisolated public static func formattedClock(_ seconds: TimeInterval) -> String {
        let wholeSeconds = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }

    /// "m:ss / m:ss"; the total never reads smaller than the elapsed time.
    nonisolated public static func formattedProgress(elapsedSeconds: TimeInterval, totalSeconds: TimeInterval) -> String {
        let clampedTotal = max(totalSeconds, elapsedSeconds)
        return "\(formattedClock(elapsedSeconds)) / \(formattedClock(clampedTotal))"
    }
}

// MARK: - Panel controller

@MainActor
final class ClickyDrawingSaveOfferController {
    static let shared = ClickyDrawingSaveOfferController()

    private static let autoHideSeconds: TimeInterval = 8
    private static let panelSize = CGSize(width: 340, height: 132)
    private static let screenMargin: CGFloat = 20

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var stateObservation: AnyCancellable?

    func present(on screen: NSScreen, drawingTitle: String, manager: ScreenAnnotationManager) {
        dismissPanelOnly()

        let offerPanel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        offerPanel.isOpaque = false
        offerPanel.backgroundColor = .clear
        offerPanel.hasShadow = true
        offerPanel.level = .screenSaver
        offerPanel.hidesOnDeactivate = false
        offerPanel.isReleasedWhenClosed = false
        offerPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        offerPanel.contentView = NSHostingView(rootView: ClickyDrawingSaveOfferView(
            drawingTitle: drawingTitle,
            manager: manager,
            onKeepRequested: { [weak self] in self?.dismiss() }
        ))
        offerPanel.setFrameOrigin(CGPoint(
            x: screen.frame.maxX - Self.panelSize.width - Self.screenMargin,
            y: screen.frame.minY + Self.screenMargin
        ))
        offerPanel.orderFrontRegardless()
        panel = offerPanel

        // Observe Esc without consuming it: the panel never takes focus.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.dismiss() }
        }
        // Every state change (recording started, saved, ...) restarts the auto-hide countdown.
        stateObservation = manager.$recordingState.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.armAutoHide() }
        }
        armAutoHide()
    }

    func dismiss() {
        dismissPanelOnly()
        ScreenAnnotationManager.shared.resetRecordingState()
    }

    private func dismissPanelOnly() {
        hideTask?.cancel()
        hideTask = nil
        stateObservation = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func armAutoHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoHideSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            switch ScreenAnnotationManager.shared.recordingState {
            case .recording, .saving:
                self.armAutoHide() // never hide while a video is being written
            default:
                self.dismiss()
            }
        }
    }
}

// MARK: - View

struct ClickyDrawingSaveOfferView: View {
    let drawingTitle: String
    @ObservedObject var manager: ScreenAnnotationManager
    let onKeepRequested: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(width: 340, height: 132, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch manager.recordingState {
        case .idle:
            offerButtons
        case .recording(let elapsedSeconds, let totalSeconds):
            statusLines(
                headline: Text("Recording it as it plays…"),
                detail: Text(String(
                    localized: "Recording \(ClickyDrawingRecordingState.formattedProgress(elapsedSeconds: elapsedSeconds, totalSeconds: totalSeconds))"
                ))
            )
        case .saving:
            statusLines(headline: Text("Saving the video…"), detail: nil)
        case .saved:
            statusLines(headline: Text("In Downloads"), detail: nil)
            offerButton(title: Text("Show the video in Finder")) { manager.revealSavedVideoInFinder() }
        case .failed(let message):
            statusLines(headline: Text("Could not save the drawing as video"), detail: Text(message))
        }
    }

    private var offerButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            offerButton(title: Text("Save drawing")) { manager.saveCurrentDrawingAsVideo() }
                .help(Text("Save this drawing as a video in your Downloads folder (it plays through once while it records)"))
            offerButton(title: Text("Keep “\(drawingTitle)” in Home → Drawings")) { onKeepRequested() }
        }
    }

    private func statusLines(headline: Text, detail: Text?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            headline.font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            if let detail {
                detail.font(.system(size: 12)).foregroundColor(.white.opacity(0.7)).lineLimit(2)
            }
        }
    }

    private func offerButton(title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .pointerCursor()
    }
}
