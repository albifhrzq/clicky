//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, live connection pill, quick prompt input, model selector,
//  window/settings launchers, permissions UI, and onboarding/quit controls.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager

    @ObservedObject private var configuration = ClickyConfiguration.shared
    @ObservedObject private var openCodexService = OpenCodexService.shared
    @ObservedObject private var oauthManager = AntigravityOAuthManager.shared
    @ObservedObject private var panelStylePreference = ClickyPanelStylePreference.shared
    @ObservedObject private var shortcutMonitor: GlobalPushToTalkShortcutMonitor

    @State private var emailInput: String = ""
    @State private var quickPromptInput: String = ""
    @State private var showingSettingsSheet: Bool = false
    @State private var settingsInitialSection: HomeSpaceSettingsSection = .connection

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self._shortcutMonitor = ObservedObject(wrappedValue: companionManager.globalPushToTalkShortcutMonitor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            liveConnectionStatusPillRow
                .padding(.horizontal, 16)
                .padding(.top, 10)

            permissionsCopySection
                .padding(.top, 12)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 10)

                quickPromptSection
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 10)

                modelPickerRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 10)

                quickLaunchActionsRow
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 14)

                permissionsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 14)

                startButton
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                dmFarzaButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
        .sheet(isPresented: $showingSettingsSheet) {
            compactSettingsSheet
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Clicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button {
                settingsInitialSection = .connection
                showingSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(showingSettingsSheet ? DS.Colors.accent : DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Live Connection Status Pill

    private var liveConnectionStatusPillRow: some View {
        let status = connectionPillState

        return Button {
            settingsInitialSection = .connection
            showingSettingsSheet = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.isReady ? DS.Colors.success : DS.Colors.warning)
                    .frame(width: 7, height: 7)

                Text(status.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(status.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var connectionPillState: (label: String, detail: String, isReady: Bool) {
        switch configuration.mode {
        case .openCodex:
            if openCodexService.isHealthy {
                return ("OpenCodex", "\(openCodexService.latencyMs) ms", true)
            }
            return ("OpenCodex", "Offline", false)
        case .nativeAntigravity:
            if oauthManager.isAuthenticated {
                return ("Antigravity OAuth", oauthManager.userEmail ?? "Connected", true)
            }
            return ("Antigravity OAuth", "Sign In", false)
        case .byok:
            let hasAnyKey = !configuration.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !configuration.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !configuration.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return ("BYOK Direct", hasAnyKey ? "Keys Ready" : "Add Key", hasAnyKey)
        case .cloudflareWorker:
            let isLocal = configuration.isLocalModeWithoutPaywall
            return ("Worker Proxy", isLocal ? "Local" : "Cloud", !configuration.workerBaseURL.isEmpty)
        }
    }

    // MARK: - Quick Prompt Input

    private var quickPromptSection: some View {
        let trimmedPrompt = quickPromptInput.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 6) {
            TextField("Ask Clicky anything...", text: $quickPromptInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .onSubmit {
                    submitQuickPrompt()
                }

            Button {
                submitQuickPrompt()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(trimmedPrompt.isEmpty ? DS.Colors.textTertiary : DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .disabled(trimmedPrompt.isEmpty)
            .pointerCursor(isEnabled: !trimmedPrompt.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.6)
        )
    }

    private func submitQuickPrompt() {
        let trimmedPrompt = quickPromptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        quickPromptInput = ""
        companionManager.submitTextPrompt(trimmedPrompt)
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
    }

    // MARK: - Window & Settings Launchers

    private var quickLaunchActionsRow: some View {
        HStack(spacing: 8) {
            Button {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                HeyClickyWindowController.shared.open(initialTab: .home)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open HeyClicky Window")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                HeyClickyWindowController.shared.open(initialTab: .settings)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                    Text("Open Settings")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.6)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            let voiceBinding = shortcutMonitor.binding(for: .voiceHold)
            let shortcutLabel = voiceBinding.displayText.isEmpty ? "Control+Option" : voiceBinding.displayText
            Text("Hold \(shortcutLabel) to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Clicky.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Farza. This is Clicky.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Clicky will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button {
                        companionManager.submitEmail(emailInput)
                    } label: {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button {
                    companionManager.triggerOnboarding()
                } label: {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow
            accessibilityPermissionRow
            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                grantedBadge
            } else {
                HStack(spacing: 6) {
                    Button {
                        WindowPositionManager.requestAccessibilityPermission()
                    } label: {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    } label: {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                grantedBadge
            } else {
                Button {
                    WindowPositionManager.requestScreenRecordingPermission()
                } label: {
                    Text("Grant")
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
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                grantedBadge
            } else {
                Button {
                    companionManager.requestScreenContentPermission()
                } label: {
                    Text("Grant")
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
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                grantedBadge
            } else {
                Button {
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Grant")
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
        .padding(.vertical, 6)
    }

    private var grantedBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DS.Colors.success)
                .frame(width: 6, height: 6)
            Text("Granted")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.success)
        }
    }

    // MARK: - Model Picker (ClickyConfiguration.shared.selectedModel)

    private var modelPickerRow: some View {
        let modelChoices: [(id: String, label: String)] = {
            if configuration.mode == .openCodex {
                let openCodexPool = openCodexService.visionModels.isEmpty
                    ? openCodexService.availableModels
                    : openCodexService.visionModels
                if !openCodexPool.isEmpty {
                    return openCodexPool.map { ($0.id, $0.displayName) }
                }
            }
            return [
                ("google-antigravity/gemini-3.8-flash", "Gemini 3.8 Flash"),
                ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
                ("claude-opus-4-6", "Claude Opus 4.6"),
                ("gpt-4o", "GPT-4o"),
                ("gemini-2.5-pro", "Gemini 2.5 Pro")
            ]
        }()

        return HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Menu {
                ForEach(modelChoices, id: \.id) { choice in
                    Button {
                        configuration.selectedModel = choice.id
                        companionManager.setSelectedModel(choice.id)
                    } label: {
                        if configuration.selectedModel == choice.id {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(shortModelName(configuration.selectedModel))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .menuStyle(.borderlessButton)
            .pointerCursor()
        }
        .padding(.vertical, 2)
    }

    private func shortModelName(_ fullID: String) -> String {
        if fullID.contains("/") {
            return String(fullID.split(separator: "/").last ?? Substring(fullID))
        }
        return fullID
    }

    // MARK: - Compact Settings Sheet

    private var compactSettingsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clicky Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Button("Pop Out") {
                    showingSettingsSheet = false
                    NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                    HeyClickyWindowController.shared.open(initialTab: .settings)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .pointerCursor()

                Button("Done") {
                    showingSettingsSheet = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .pointerCursor()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(DS.Colors.surface1)

            Divider().background(DS.Colors.borderSubtle)

            HomeSpaceSettingsPage(
                companionManager: companionManager,
                initialSection: settingsInitialSection
            )
        }
        .frame(width: 440, height: 520)
        .background(DS.Colors.background)
    }

    // MARK: - DM Farza Button

    private var dmFarzaButton: some View {
        Button {
            if let url = URL(string: "https://x.com/farzatv") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Got feedback? DM me")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, anything — I read every message.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Clicky")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button {
                    companionManager.replayOnboarding()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Watch Onboarding Again")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        ClickyPanelBackground(
            cornerRadius: 12,
            usesTranslucentMaterial: panelStylePreference.usesTransparentPanes
        )
        .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }
}
