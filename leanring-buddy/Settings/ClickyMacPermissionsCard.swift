//
//  ClickyMacPermissionsCard.swift
//  leanring-buddy
//
//  The macOS permissions list (microphone, accessibility, screen recording,
//  screen content), shown on the Agents page.
//

import AVFoundation
import SwiftUI

struct ClickyMacPermissionsCard: View {
    @ObservedObject var companionManager: CompanionManager
    var title: String = String(localized: "What agents can reach")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClickySettingsSectionCard(title: title) {
                Text("macOS permissions HeyClicky's agents inherit. Tap one to review it in System Settings.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                permissionStatusRow(
                    title: "Microphone",
                    iconName: "mic",
                    isGranted: companionManager.hasMicrophonePermission,
                    subtitle: "Voice push-to-talk and live audio sessions",
                    actionLabel: "Grant",
                    action: requestMicrophonePermission
                )

                ClickySettingsRowDivider()

                permissionStatusRow(
                    title: "Accessibility",
                    iconName: "hand.raised",
                    isGranted: companionManager.hasAccessibilityPermission,
                    subtitle: "Global shortcuts, Type Anywhere dictation, and app control",
                    actionLabel: "Grant",
                    action: { WindowPositionManager.requestAccessibilityPermission() },
                    secondaryActionLabel: "Find App",
                    secondaryAction: {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }
                )

                ClickySettingsRowDivider()

                permissionStatusRow(
                    title: "Screen Recording",
                    iconName: "rectangle.dashed.badge.record",
                    isGranted: companionManager.hasScreenRecordingPermission,
                    subtitle: "Captures active screen context only when triggered",
                    actionLabel: "Grant",
                    action: { WindowPositionManager.requestScreenRecordingPermission() }
                )

                ClickySettingsRowDivider()

                permissionStatusRow(
                    title: "Screen Content",
                    iconName: "eye",
                    isGranted: companionManager.hasScreenContentPermission,
                    subtitle: "ScreenCaptureKit permission for multi-monitor snapshots",
                    actionLabel: "Grant",
                    action: { companionManager.requestScreenContentPermission() }
                )

                HStack {
                    Spacer()
                    Button {
                        companionManager.refreshAllPermissions()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh Status")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    private func permissionStatusRow(
        title: LocalizedStringKey,
        iconName: String,
        isGranted: Bool,
        subtitle: LocalizedStringKey,
        actionLabel: LocalizedStringKey,
        action: @escaping () -> Void,
        secondaryActionLabel: LocalizedStringKey? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isGranted ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isGranted {
                ClickySettingsStatusBadge(label: String(localized: "Granted"), isPositive: true)
            } else {
                HStack(spacing: 6) {
                    Button(actionLabel, action: action)
                        .buttonStyle(ClickyGlossyPillButtonStyle.accent)

                    if let secondaryActionLabel, let secondaryAction {
                        Button(secondaryActionLabel, action: secondaryAction)
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8))
                            .pointerCursor()
                    }
                }
            }
        }
    }

    private func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in
                    companionManager.refreshAllPermissions()
                }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
