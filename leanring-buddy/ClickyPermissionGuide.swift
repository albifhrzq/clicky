//
//  ClickyPermissionGuide.swift
//  leanring-buddy
//
//  Step-by-step guidance shown under the permissions rows: which permission to fix
//  next, the drag-into-list hint, the Quit & Reopen relaunch and a test-screenshot check.
//

import AppKit
import SwiftUI

enum ClickyPermissionGuideStep: Equatable {
    case accessibility
    case screenRecording
    case screenContent

    /// Missing steps in the order the user should complete them.
    static func remainingSteps(
        hasAccessibility: Bool,
        hasScreenRecording: Bool,
        hasScreenContent: Bool
    ) -> [ClickyPermissionGuideStep] {
        var steps: [ClickyPermissionGuideStep] = []
        if !hasAccessibility { steps.append(.accessibility) }
        if !hasScreenRecording { steps.append(.screenRecording) }
        if !hasScreenContent { steps.append(.screenContent) }
        return steps
    }

    var title: String {
        switch self {
        case .accessibility: return String(localized: "Accessibility")
        case .screenRecording: return String(localized: "Screen Recording")
        case .screenContent: return String(localized: "Screen Content")
        }
    }

    /// "{i} of {n} · {title}"
    static func progressLabel(index: Int, total: Int, title: String) -> String {
        String(localized: "\(index) of \(total) · \(title)")
    }
}

enum ClickyScreenCaptureVerificationState: Equatable {
    case idle
    case checking
    case succeeded
    case failed
}

struct ClickyPermissionGuideView: View {
    let hasAccessibility: Bool
    let hasScreenRecording: Bool
    let hasScreenContent: Bool
    let requestScreenContent: () -> Void

    @State private var verificationState: ClickyScreenCaptureVerificationState = .idle

    var body: some View {
        let remainingSteps = ClickyPermissionGuideStep.remainingSteps(
            hasAccessibility: hasAccessibility,
            hasScreenRecording: hasScreenRecording,
            hasScreenContent: hasScreenContent
        )
        if let currentStep = remainingSteps.first {
            VStack(alignment: .leading, spacing: 6) {
                Text(ClickyPermissionGuideStep.progressLabel(
                    index: 1,
                    total: remainingSteps.count,
                    title: currentStep.title
                ))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

                stepBody(for: currentStep)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func stepBody(for step: ClickyPermissionGuideStep) -> some View {
        switch step {
        case .accessibility:
            guideText("Drag Clicky into the Accessibility list.", isHeadline: true)
            guideText("The guide will stay attached to System Settings while you drag Clicky into the list above. If the app does not show up automatically, reveal it in Finder and drag from there.")
            guideText("If macOS asks you to Quit & Reopen after enabling access, follow that prompt.")
            guideButton("Find App") {
                WindowPositionManager.revealAppInFinder()
                WindowPositionManager.openAccessibilitySettings()
            }

        case .screenRecording:
            guideText("Drag me into Screen Recording.", isHeadline: true)
            guideText("Drag into “Screen & System Audio Recording”, not the audio-only list.")
            guideText("Add and enable Clicky in Screen & System Audio Recording, not System Audio Recording Only. If you used the audio-only list, add it to the screen-recording list too.")
            guideText("Mac can require a relaunch after you toggle Screen Recording on.")
            HStack(spacing: 6) {
                guideButton("Find App") {
                    WindowPositionManager.revealAppInFinder()
                    WindowPositionManager.openScreenRecordingSettings()
                }
                guideButton("Quit & Reopen Clicky") {
                    WindowPositionManager.quitAndReopenApp()
                }
            }

        case .screenContent:
            guideText("Click Grant Access to verify screen capture. Mac may ask you to allow it.", isHeadline: true)
            switch verificationState {
            case .idle:
                guideText("Let Clicky take one test screenshot.")
            case .checking:
                guideText("Checking that Clicky can see your screen…")
            case .succeeded:
                guideText("Screen content is ready.")
            case .failed:
                guideText("I couldn't take a test screenshot. Try again.")
            }
            guideButton("Grant Access") {
                runTestScreenshot()
            }
        }
    }

    private func runTestScreenshot() {
        guard verificationState != .checking else { return }
        verificationState = .checking
        Task { @MainActor in
            let didCapture = await WindowPositionManager.canTakeTestScreenshot()
            verificationState = didCapture ? .succeeded : .failed
            if didCapture { requestScreenContent() }
        }
    }

    private func guideText(_ text: LocalizedStringKey, isHeadline: Bool = false) -> some View {
        Text(text)
            .font(.system(size: isHeadline ? 12 : 11, weight: isHeadline ? .semibold : .regular))
            .foregroundColor(isHeadline ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func guideButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(DS.Colors.accent))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
