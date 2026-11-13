//
//  HomeSpaceSettingsPage.swift
//  leanring-buddy
//
//  Unified settings experience supporting both compact (menu bar popover / notch)
//  and full (window sidebar + detail pane) layouts.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import ServiceManagement
import SwiftUI

enum HomeSpaceSettingsSection: String, CaseIterable, Identifiable {
    case connection
    case general
    case voice
    case dictation
    case shortcuts
    case cursor
    case browser
    case routines
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "Connection & AI"
        case .general: return "General"
        case .voice: return "Voice & Languages"
        case .dictation: return "Dictation"
        case .shortcuts: return "Shortcuts"
        case .cursor: return "Cursor"
        case .browser: return "Browser & Security"
        case .routines: return "Routines"
        case .memory: return "Memory"
        }
    }

    var shortTitle: String {
        switch self {
        case .connection: return "AI"
        case .general: return "General"
        case .voice: return "Voice"
        case .dictation: return "Dictation"
        case .shortcuts: return "Shortcuts"
        case .cursor: return "Cursor"
        case .browser: return "Browser"
        case .routines: return "Routines"
        case .memory: return "Memory"
        }
    }

    var iconName: String {
        switch self {
        case .connection: return "network"
        case .general: return "slider.horizontal.3"
        case .voice: return "waveform.circle"
        case .dictation: return "mic.fill"
        case .shortcuts: return "command"
        case .cursor: return "cursorarrow"
        case .browser: return "globe"
        case .routines: return "clock.arrow.2.circlepath"
        case .memory: return "brain"
        }
    }
}

struct HomeSpaceSettingsPage: View {
    @ObservedObject var companionManager: CompanionManager
    let initialSection: HomeSpaceSettingsSection

    @State private var selectedSection: HomeSpaceSettingsSection

    @ObservedObject private var configuration = ClickyConfiguration.shared
    @ObservedObject private var openCodexService = OpenCodexService.shared
    @ObservedObject private var oauthManager = AntigravityOAuthManager.shared
    @ObservedObject private var panelStylePreference = ClickyPanelStylePreference.shared
    @ObservedObject private var voicePreviewPlayer = VoicePreviewPlayer.shared
    @ObservedObject private var elevenLabsTTSClient = ElevenLabsTTSClient.shared
    @ObservedObject private var wakeWordListener = HeyClickyWakeWordListener.shared
    @ObservedObject private var realtimeVoiceController = RealtimeVoiceController.shared
    @ObservedObject private var shortcutMonitor: GlobalPushToTalkShortcutMonitor
    @ObservedObject private var browserBridge = ClickyBrowserBridge.shared
    @ObservedObject private var chromeSetupFlow = ClickyChromeSetupFlow.shared
    @ObservedObject private var routineScheduler = ClickyRoutineScheduler.shared
    @ObservedObject private var userMemoryStore = UserMemoryStore.shared
    @ObservedObject private var learnedHowTosStore = ClickyLearnedHowTos.shared

    // Voice & Language search
    @State private var voiceLanguageSearchQuery: String = ""
    @State private var dictationLanguageSearchQuery: String = ""

    // OAuth feedback
    @State private var isStartingOAuthSignIn: Bool = false

    // Shortcut key-capture state
    @State private var recordingKeySlot: ClickyShortcutSlot?
    @State private var keyCaptureMonitor: Any?

    // Memory editor draft
    @State private var memoryMarkdownDraft: String = ""
    @State private var newPreferenceDraft: String = ""
    @State private var didSaveMemoryRecently: Bool = false

    // Login item refresh trigger
    @State private var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    @State private var loginItemErrorMessage: String?

    // Browser repair feedback
    @State private var browserHostStatusNote: String?

    init(
        companionManager: CompanionManager,
        initialSection: HomeSpaceSettingsSection = .connection
    ) {
        self.companionManager = companionManager
        self.initialSection = initialSection
        self._selectedSection = State(initialValue: initialSection)
        self._shortcutMonitor = ObservedObject(wrappedValue: companionManager.globalPushToTalkShortcutMonitor)
    }

    var body: some View {
        GeometryReader { geometry in
            let isCompactLayout = geometry.size.width < 560

            Group {
                if isCompactLayout {
                    compactLayout
                } else {
                    fullWindowLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            memoryMarkdownDraft = userMemoryStore.markdown
            loginItemStatus = SMAppService.mainApp.status
            chromeSetupFlow.refreshSetupState()
        }
        .onChange(of: userMemoryStore.markdown) { _, updatedMarkdown in
            if memoryMarkdownDraft.isEmpty && !updatedMarkdown.isEmpty {
                memoryMarkdownDraft = updatedMarkdown
            }
        }
        .onDisappear {
            stopRecordingShortcutKey()
            voicePreviewPlayer.stopPreview()
        }
    }

    // MARK: - Responsive Layouts

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(HomeSpaceSettingsSection.allCases) { section in
                        compactSectionChip(for: section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(DS.Colors.surface1.opacity(0.85))

            Divider()
                .background(DS.Colors.borderSubtle)

            ScrollView {
                sectionContent(isCompact: true)
                    .padding(14)
            }
        }
        .background(ClickyPanelBackground(cornerRadius: 12, usesTranslucentMaterial: panelStylePreference.usesTransparentPanes))
    }

    private var fullWindowLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SETTINGS")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                ForEach(HomeSpaceSettingsSection.allCases) { section in
                    sidebarSectionButton(for: section)
                }

                Spacer()
            }
            .frame(width: 196)
            .background(DS.Colors.surface1.opacity(0.75))

            Divider()
                .background(DS.Colors.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Image(systemName: selectedSection.iconName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(DS.Colors.accentText)
                        Text(selectedSection.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                    }

                    sectionContent(isCompact: false)
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(ClickyPanelBackground(cornerRadius: 14, usesTranslucentMaterial: panelStylePreference.usesTransparentPanes))
    }

    private func compactSectionChip(for section: HomeSpaceSettingsSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 5) {
                Image(systemName: section.iconName)
                    .font(.system(size: 11, weight: .medium))
                Text(section.shortTitle)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? DS.Colors.accent : DS.Colors.surface2)
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func sidebarSectionButton(for section: HomeSpaceSettingsSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .frame(width: 18)

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accent.opacity(0.35) : Color.clear, lineWidth: 0.75)
            )
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private func sectionContent(isCompact: Bool) -> some View {
        switch selectedSection {
        case .connection:
            connectionSectionView(isCompact: isCompact)
        case .general:
            generalSectionView
        case .voice:
            voiceSectionView(isCompact: isCompact)
        case .dictation:
            dictationSectionView
        case .shortcuts:
            shortcutsSectionView
        case .cursor:
            cursorSectionView
        case .browser:
            browserSectionView
        case .routines:
            routinesSectionView
        case .memory:
            memorySectionView
        }
    }

    // MARK: - 1. Connection & AI Models

    private func connectionSectionView(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "CONNECTION MODE") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Connection Mode", selection: $configuration.mode) {
                        ForEach(ClickyConnectionMode.allCases) { connectionMode in
                            Text(connectionMode.displayName).tag(connectionMode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Text(connectionModeSummary(configuration.mode))
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if configuration.mode == .openCodex {
                openCodexSettingsCard
            }

            if configuration.mode == .nativeAntigravity {
                antigravityOAuthCard
            }

            if configuration.mode == .byok {
                byokKeysCard
            }

            if configuration.mode == .cloudflareWorker {
                workerProxyCard
            }

            // Always show quick access to model & media/search keys when not already shown above
            if configuration.mode != .byok {
                additionalServiceKeysCard
            }
        }
    }

    private var openCodexSettingsCard: some View {
        settingsCard(title: "OPENCODEX LOCAL PROXY") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(openCodexService.isHealthy ? DS.Colors.success : DS.Colors.warning)
                        .frame(width: 8, height: 8)

                    Text(
                        openCodexService.isHealthy
                            ? "Online · \(openCodexService.latencyMs) ms"
                            : "Offline"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(openCodexService.isHealthy ? DS.Colors.success : DS.Colors.warning)

                    if !openCodexService.visionModels.isEmpty {
                        Text("\(openCodexService.visionModels.count) vision · \(openCodexService.availableModels.count) total")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    Spacer()

                    Button {
                        Task { await openCodexService.refresh() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(DS.Colors.surface3)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                if let lastError = openCodexService.lastError, !lastError.isEmpty, !openCodexService.isHealthy {
                    Text(lastError)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                labeledInputRow(label: "Proxy URL") {
                    TextField("http://127.0.0.1:10100/v1", text: $configuration.openCodexBaseURL)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "API Key") {
                    SecureField("Optional Bearer Token", text: $configuration.openCodexAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                Divider().background(DS.Colors.borderSubtle)

                // Vision-filtered model picker for screen & voice turns
                let visionModelCandidates = openCodexService.visionModels.isEmpty
                    ? openCodexService.availableModels
                    : openCodexService.visionModels

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vision & Companion Model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    if visionModelCandidates.isEmpty {
                        TextField("Enter model ID", text: $configuration.selectedModel)
                            .textFieldStyle(.plain)
                            .settingsInputChrome()
                    } else {
                        Picker("Vision Model", selection: $configuration.selectedModel) {
                            ForEach(visionModelCandidates) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }

                // Agent / tool-use model picker
                let agentModelCandidates = openCodexService.agentModels.isEmpty
                    ? openCodexService.availableModels
                    : openCodexService.agentModels

                VStack(alignment: .leading, spacing: 4) {
                    Text("Background Agent Model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    if agentModelCandidates.isEmpty {
                        TextField("Enter agent model ID", text: $configuration.selectedAgentModel)
                            .textFieldStyle(.plain)
                            .settingsInputChrome()
                    } else {
                        Picker("Agent Model", selection: $configuration.selectedAgentModel) {
                            ForEach(agentModelCandidates) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }
        }
    }

    private var antigravityOAuthCard: some View {
        settingsCard(title: "GOOGLE ANTIGRAVITY OAUTH") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(oauthManager.isAuthenticated ? DS.Colors.success : DS.Colors.warning)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(oauthManager.isAuthenticated ? "Signed In" : "Not Signed In")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(oauthManager.isAuthenticated ? DS.Colors.success : DS.Colors.textPrimary)

                        if let userEmail = oauthManager.userEmail, !userEmail.isEmpty {
                            Text("Account: \(userEmail)")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                        }

                        if let projectNumber = oauthManager.currentProjectNumber, !projectNumber.isEmpty {
                            Text("Project: \(projectNumber)")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }

                    Spacer()

                    if oauthManager.isAuthenticated {
                        Button("Sign Out") {
                            oauthManager.signOut()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.destructiveText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(DS.Colors.destructive.opacity(0.16))
                        )
                        .pointerCursor()
                    } else {
                        Button {
                            guard !isStartingOAuthSignIn && !oauthManager.isAuthenticating else { return }
                            isStartingOAuthSignIn = true
                            Task {
                                defer { isStartingOAuthSignIn = false }
                                try? await oauthManager.signIn()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if oauthManager.isAuthenticating || isStartingOAuthSignIn {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(oauthManager.isAuthenticating ? "Signing In..." : "Sign In with Google")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(DS.Colors.accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(oauthManager.isAuthenticating || isStartingOAuthSignIn)
                        .pointerCursor(isEnabled: !(oauthManager.isAuthenticating || isStartingOAuthSignIn))
                    }
                }

                if let authError = oauthManager.authError, !authError.isEmpty {
                    Text(authError)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().background(DS.Colors.borderSubtle)

                labeledInputRow(label: "Client ID") {
                    TextField("Enter Google OAuth Client ID", text: $configuration.antigravityClientID)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "Client Secret") {
                    SecureField("Enter Google OAuth Client Secret", text: $configuration.antigravityClientSecret)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "Model ID") {
                    TextField("google-antigravity/gemini-3.8-flash", text: $configuration.selectedModel)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }
            }
        }
    }

    private var byokKeysCard: some View {
        settingsCard(title: "DIRECT API KEYS (KEYCHAIN)") {
            VStack(alignment: .leading, spacing: 8) {
                labeledInputRow(label: "Anthropic") {
                    SecureField("Enter Anthropic API key", text: $configuration.anthropicAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "OpenAI") {
                    SecureField("Enter OpenAI API key", text: $configuration.openaiAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "Gemini") {
                    SecureField("Enter Gemini API key", text: $configuration.geminiAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "ElevenLabs") {
                    SecureField("Enter ElevenLabs API key", text: $configuration.elevenLabsAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "ElevenLabs Voice") {
                    TextField("ElevenLabs Voice ID", text: $configuration.elevenLabsVoiceID)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                elevenLabsTestRow

                labeledInputRow(label: "AssemblyAI") {
                    SecureField("Enter AssemblyAI API key", text: $configuration.assemblyAIAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "Brave Search") {
                    SecureField("Enter Brave Search API key", text: $configuration.braveAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "OpenCodex Key") {
                    SecureField("Enter OpenCodex Bearer Token", text: $configuration.openCodexAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                Divider().background(DS.Colors.borderSubtle)

                labeledInputRow(label: "Model ID") {
                    TextField("claude-sonnet-4-6", text: $configuration.selectedModel)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "Agent Model") {
                    TextField("claude-sonnet-4-6", text: $configuration.selectedAgentModel)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }
            }
        }
    }

    private var workerProxyCard: some View {
        settingsCard(title: "CLOUDFLARE WORKER PROXY") {
            VStack(alignment: .leading, spacing: 8) {
                labeledInputRow(label: "Worker URL") {
                    TextField("https://api.heyclicky.com", text: $configuration.workerBaseURL)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "Model ID") {
                    TextField("claude-sonnet-4-6", text: $configuration.selectedModel)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "ElevenLabs Voice") {
                    TextField("Voice ID", text: $configuration.elevenLabsVoiceID)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }
            }
        }
    }

    private var additionalServiceKeysCard: some View {
        settingsCard(title: "MEDIA, VOICE & SEARCH KEYS") {
            VStack(alignment: .leading, spacing: 8) {
                labeledInputRow(label: "ElevenLabs Key") {
                    SecureField("Enter ElevenLabs API key", text: $configuration.elevenLabsAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "Voice ID") {
                    TextField("ElevenLabs Voice ID", text: $configuration.elevenLabsVoiceID)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                elevenLabsTestRow

                labeledInputRow(label: "AssemblyAI Key") {
                    SecureField("Enter AssemblyAI API key", text: $configuration.assemblyAIAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                labeledInputRow(label: "Brave Key") {
                    SecureField("Enter Brave Search API key", text: $configuration.braveAPIKey)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                if configuration.mode != .cloudflareWorker {
                    labeledInputRow(label: "Worker URL") {
                        TextField("https://api.heyclicky.com", text: $configuration.workerBaseURL)
                            .textFieldStyle(.plain)
                            .settingsInputChrome()
                    }
                }
            }
        }
    }

    // MARK: - 2. General

    private var generalSectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "APPEARANCE & FEEDBACK") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $panelStylePreference.usesTransparentPanes) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Translucent Frosted Panes")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Use translucent macOS vibrancy material on notch, settings, and companion panels.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)

                    Divider().background(DS.Colors.borderSubtle)

                    Toggle(isOn: Binding(
                        get: { configuration.soundEffectsEnabled },
                        set: { enabled in
                            configuration.soundEffectsEnabled = enabled
                            if enabled {
                                ClickySoundEffectPlayer.shared.play(.gelPop)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tactile Sound Effects")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Play subtle acoustic chimes on agent launch, completion, and button feedback.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                }
            }

            settingsCard(title: "STARTUP") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(loginItemStatusDescription)
                                .font(.system(size: 11))
                                .foregroundColor(loginItemStatus == .enabled ? DS.Colors.success : DS.Colors.textTertiary)
                        }

                        Spacer()

                        Button(loginItemStatus == .enabled ? "Disable" : "Enable") {
                            toggleLoginItemRegistration()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.surface3))
                        .pointerCursor()
                    }

                    if let loginItemErrorMessage {
                        Text(loginItemErrorMessage)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.warningText)
                    }
                }
            }

            settingsCard(title: "MACOS PERMISSIONS") {
                VStack(alignment: .leading, spacing: 10) {
                    permissionStatusRow(
                        title: "Microphone",
                        iconName: "mic",
                        isGranted: companionManager.hasMicrophonePermission,
                        subtitle: "Voice push-to-talk and live audio sessions",
                        actionLabel: "Grant",
                        action: requestMicrophonePermission
                    )

                    Divider().background(DS.Colors.borderSubtle)

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

                    Divider().background(DS.Colors.borderSubtle)

                    permissionStatusRow(
                        title: "Screen Recording",
                        iconName: "rectangle.dashed.badge.record",
                        isGranted: companionManager.hasScreenRecordingPermission,
                        subtitle: "Captures active screen context only when triggered",
                        actionLabel: "Grant",
                        action: { WindowPositionManager.requestScreenRecordingPermission() }
                    )

                    Divider().background(DS.Colors.borderSubtle)

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
                            loginItemStatus = SMAppService.mainApp.status
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
    }

    private var elevenLabsTestRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task {
                        await elevenLabsTTSClient.testVoice()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if elevenLabsTTSClient.isTestingVoice {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        Text(elevenLabsTTSClient.isTestingVoice ? "Testing Voice..." : "Test ElevenLabs Voice")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.surface3))
                }
                .buttonStyle(.plain)
                .disabled(elevenLabsTTSClient.isTestingVoice)
                .pointerCursor(isEnabled: !elevenLabsTTSClient.isTestingVoice)

                if elevenLabsTTSClient.isPlaying {
                    Button("Stop") {
                        elevenLabsTTSClient.stopPlayback()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.destructiveText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.Colors.destructive.opacity(0.14)))
                    .pointerCursor()
                }

                Spacer()
            }

            if let errorMessage = elevenLabsTTSClient.lastErrorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let statusMessage = elevenLabsTTSClient.lastStatusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 3. Voice & 133 Languages

    private func voiceSectionView(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            voiceWakeCallCard

            settingsCard(title: "VOICE PIPELINE") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Voice Pipeline", selection: $configuration.voicePipelineMode) {
                        ForEach(ClickyVoicePipelineMode.allCases) { pipelineMode in
                            Text(pipelineMode.displayName).tag(pipelineMode)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack {
                        Text("Speech Speed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)

                        Spacer()

                        Picker("Speech Speed", selection: $realtimeVoiceController.speechSpeed) {
                            ForEach(VoiceLanguageCatalog.speechSpeeds) { option in
                                Text(option.label).tag(option.rate)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }
            }

            settingsCard(title: "OPENAI REALTIME VOICES (\(VoiceLanguageCatalog.openAIVoices.count))") {
                voiceSelectionGrid(voices: VoiceLanguageCatalog.openAIVoices, isCompact: isCompact)
            }

            settingsCard(title: "GEMINI LIVE VOICES (\(VoiceLanguageCatalog.geminiVoices.count))") {
                voiceSelectionGrid(voices: VoiceLanguageCatalog.geminiVoices, isCompact: isCompact)
            }

            settingsCard(title: "VOICE LANGUAGE (\(VoiceLanguageCatalog.supportedLanguages.count) LANGUAGES)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                        TextField("Filter 133 languages...", text: $voiceLanguageSearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )

                    if let currentLanguage = VoiceLanguageCatalog.language(forCode: configuration.selectedVoiceLanguage) {
                        HStack(spacing: 8) {
                            Text("Selected: \(currentLanguage.displayLabel) [\(currentLanguage.bcp47Locale)]")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DS.Colors.accentText)

                            Spacer()

                            if configuration.dictationLanguageCode != configuration.selectedVoiceLanguage
                                || (!configuration.dictationAutoDetect && configuration.selectedVoiceLanguage == "auto") {
                                Button("Apply to Dictation too") {
                                    if configuration.selectedVoiceLanguage == "auto" {
                                        configuration.dictationAutoDetect = true
                                        configuration.dictationLanguageCode = "auto"
                                    } else {
                                        configuration.dictationAutoDetect = false
                                        configuration.dictationLanguageCode = configuration.selectedVoiceLanguage
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(DS.Colors.surface3))
                                .pointerCursor()
                            }
                        }
                    }

                    Text("Applies to Clicky AI replies, ElevenLabs TTS, and voice input recognition.")
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textTertiary)

                    let filteredLanguages = filterLanguages(query: voiceLanguageSearchQuery)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(filteredLanguages) { language in
                                languageSelectionRow(
                                    language: language,
                                    isSelected: configuration.selectedVoiceLanguage == language.code
                                ) {
                                    configuration.selectedVoiceLanguage = language.code
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
        }
    }

    private func voiceSelectionGrid(voices: [CatalogVoice], isCompact: Bool) -> some View {
        let columnCount = isCompact ? 1 : 2
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)

        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(voices) { voice in
                let isSelected = configuration.selectedVoiceID.caseInsensitiveCompare(voice.id) == .orderedSame
                let isPreviewing = voicePreviewPlayer.isPlaying
                    && voicePreviewPlayer.currentlyPlayingVoiceID?.caseInsensitiveCompare(voice.id) == .orderedSame

                HStack(spacing: 8) {
                    Button {
                        configuration.selectedVoiceID = voice.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(voice.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(DS.Colors.textPrimary)
                                Text(voice.toneDescription)
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button {
                        voicePreviewPlayer.playPreview(for: voice.id)
                    } label: {
                        Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isPreviewing ? DS.Colors.textOnAccent : DS.Colors.textPrimary)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle().fill(isPreviewing ? DS.Colors.accent : DS.Colors.surface3)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(isSelected ? DS.Colors.accentSubtle : DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(isSelected ? DS.Colors.accent.opacity(0.5) : DS.Colors.borderSubtle, lineWidth: 0.75)
                )
            }
        }
    }

    // MARK: - 4. Dictation

    private var dictationSectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "DICTATION & TYPE ANYWHERE") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Active Provider")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                        Spacer()
                        Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName.isEmpty
                             ? "Configured Provider"
                             : companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                    }

                    Divider().background(DS.Colors.borderSubtle)

                    Toggle(isOn: $configuration.dictationAutoDetect) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Detect Dictation Language")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Automatically recognize spoken language during push-to-talk and Type Anywhere dictation.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)

                    Divider().background(DS.Colors.borderSubtle)

                    Toggle(isOn: Binding(
                        get: { companionManager.buddyDictationManager.isTranscriptCleanupEnabled },
                        set: { companionManager.buddyDictationManager.isTranscriptCleanupEnabled = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Transcript Cleanup")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Polish punctuation and filler words before pasting dictated text.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                }
            }

            settingsCard(title: "PREFERRED DICTATION LANGUAGE") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                        TextField("Search dictation languages...", text: $dictationLanguageSearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )

                    if let selectedLanguage = VoiceLanguageCatalog.language(forCode: configuration.dictationLanguageCode) {
                        Text("Selected: \(selectedLanguage.displayLabel)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.accentText)
                    }

                    let filteredLanguages = filterLanguages(query: dictationLanguageSearchQuery)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(filteredLanguages) { language in
                                languageSelectionRow(
                                    language: language,
                                    isSelected: configuration.dictationLanguageCode == language.code
                                ) {
                                    configuration.dictationLanguageCode = language.code
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
        }
    }

    private var voiceWakeCallCard: some View {
        settingsCard(title: "VOICE WAKE CALL (CUSTOM NAME)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Toggle(isOn: $configuration.voiceWakeWordEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Listen for Wake Phrase")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Hands-free callout using local Apple Speech recognition; pauses automatically while speaking or recording.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                }

                labeledInputRow(label: "Wake Phrase") {
                    TextField("hey clicky (e.g. hey nora)", text: $configuration.voiceWakePhrase)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }

                Text("You can customize any name (e.g. \"hey nora\", \"halo clicky\") or list multiple phrases separated by commas (e.g. \"hey nora, nora\").")
                    .font(.system(size: 10.5))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Circle()
                        .fill(wakeWordStatusColor)
                        .frame(width: 7, height: 7)

                    Text(wakeWordListener.status.displayLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(wakeWordStatusColor)

                    Spacer()

                    if !wakeWordListener.lastHeardSnippet.isEmpty && configuration.voiceWakeWordEnabled {
                        Text("Heard: \"\(wakeWordListener.lastHeardSnippet)\"")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: 260, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var wakeWordStatusColor: Color {
        switch wakeWordListener.status {
        case .listening:
            return DS.Colors.success
        case .triggered:
            return DS.Colors.accentText
        case .paused, .requestingPermission:
            return DS.Colors.warningText
        case .error:
            return DS.Colors.destructiveText
        case .stopped:
            return DS.Colors.textTertiary
        }
    }

    // MARK: - 5. Shortcuts (4-Slot Configurator)

    private var shortcutsSectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            voiceWakeCallCard

            settingsCard(title: "GLOBAL SHORTCUT SLOTS") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Configure system-wide shortcuts monitored via CGEvent tap. Press Esc anytime to interrupt active voice output.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(ClickyShortcutSlot.allCases) { slot in
                        shortcutSlotRow(for: slot)
                        if slot != ClickyShortcutSlot.allCases.last {
                            Divider().background(DS.Colors.borderSubtle)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Reset to Defaults") {
                            stopRecordingShortcutKey()
                            shortcutMonitor.resetBindingsToDefaults()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.surface3))
                        .pointerCursor()
                    }
                }
            }
        }
    }

    private func shortcutSlotRow(for slot: ClickyShortcutSlot) -> some View {
        let binding = shortcutMonitor.binding(for: slot)
        let isRecordingKey = recordingKeySlot == slot

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(
                    get: { shortcutMonitor.binding(for: slot).isEnabled },
                    set: { enabled in
                        var updated = shortcutMonitor.binding(for: slot)
                        updated.isEnabled = enabled
                        shortcutMonitor.updateBinding(updated)
                    }
                )) {
                    Text(slot.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)

                Spacer()

                HStack(spacing: 4) {
                    ForEach(binding.keyCapsuleLabels, id: \.self) { capsuleLabel in
                        Text(capsuleLabel)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(DS.Colors.surface3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(DS.Colors.borderStrong, lineWidth: 0.5)
                            )
                    }
                }
            }

            HStack(spacing: 8) {
                Picker("Trigger Mode", selection: Binding(
                    get: { shortcutMonitor.binding(for: slot).triggerMode },
                    set: { triggerMode in
                        var updated = shortcutMonitor.binding(for: slot)
                        updated.triggerMode = triggerMode
                        if triggerMode == .doubleTapModifier {
                            updated.keyCode = nil
                            if let firstModifier = updated.modifiers.first {
                                updated.modifiers = [firstModifier]
                            } else {
                                updated.modifiers = [.function]
                            }
                        }
                        shortcutMonitor.updateBinding(updated)
                    }
                )) {
                    ForEach(ClickyShortcutTriggerMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 155)

                HStack(spacing: 4) {
                    ForEach(ClickyShortcutModifierKey.allCases, id: \.self) { modifierKey in
                        let isActive = binding.modifiers.contains(modifierKey)
                        Button {
                            toggleModifier(modifierKey, for: slot)
                        } label: {
                            Text(modifierKey.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(isActive ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(isActive ? DS.Colors.accent : DS.Colors.surface2)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }

                Spacer()

                if binding.triggerMode == .holdCombo {
                    Button(isRecordingKey ? "Press Key..." : (binding.keyCode == nil ? "+ Key" : "Change Key")) {
                        if isRecordingKey {
                            stopRecordingShortcutKey()
                        } else {
                            beginRecordingShortcutKey(for: slot)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isRecordingKey ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isRecordingKey ? DS.Colors.accent : DS.Colors.surface3)
                    )
                    .pointerCursor()

                    if binding.keyCode != nil {
                        Button("Clear Key") {
                            var updated = shortcutMonitor.binding(for: slot)
                            updated.keyCode = nil
                            shortcutMonitor.updateBinding(updated)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .pointerCursor()
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 6. Cursor

    private var cursorSectionView: some View {
        let cursorColorNames = ["red", "blue", "yellow", "green"]

        return VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "FLOATING CURSOR") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $configuration.hideFloatingCursor) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide Floating Cursor")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Hide Clicky's floating cursor triangle when idle and only reveal it during pointing or voice turns.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                    .onChange(of: configuration.hideFloatingCursor) { _, isHidden in
                        companionManager.setClickyCursorEnabled(!isHidden)
                    }

                    Divider().background(DS.Colors.borderSubtle)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cursor Accent Color")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)

                        HStack(spacing: 14) {
                            ForEach(cursorColorNames, id: \.self) { colorName in
                                let isSelected = configuration.cursorColorName.lowercased() == colorName
                                let swatchColor = DS.Colors.cursorColor(named: colorName)

                                Button {
                                    configuration.cursorColorName = colorName
                                } label: {
                                    VStack(spacing: 5) {
                                        ZStack {
                                            Circle()
                                                .fill(swatchColor)
                                                .frame(width: 28, height: 28)

                                            if isSelected {
                                                Circle()
                                                    .stroke(Color.white, lineWidth: 2)
                                                    .frame(width: 34, height: 34)
                                            }
                                        }

                                        Text(colorName.capitalized)
                                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 7. Browser & Security

    private var browserSectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "CHROME & BROWSER EXTENSION BRIDGE") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(browserBridge.isConnected ? DS.Colors.success : DS.Colors.warning)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(browserBridge.isConnected ? "Browser Extension Connected" : "Extension Not Connected")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(browserBridge.isConnected ? DS.Colors.success : DS.Colors.textPrimary)

                            Text(browserBridge.statusMessage)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }

                        Spacer()
                    }

                    if !browserBridge.connectedBrowsers.isEmpty {
                        Text("Connected browsers: \(browserBridge.connectedBrowsers.joined(separator: ", "))")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                    }

                    if !browserBridge.profiles.isEmpty {
                        HStack {
                            Text("Active Profile")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Colors.textSecondary)
                            Spacer()
                            Picker("Browser Profile", selection: Binding(
                                get: { browserBridge.selectedProfile ?? "" },
                                set: { browserBridge.selectedProfile = $0.isEmpty ? nil : $0 }
                            )) {
                                Text("Automatic").tag("")
                                ForEach(browserBridge.profiles, id: \.self) { profile in
                                    Text(profile).tag(profile)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            browserBridge.installNativeMessagingHosts()
                            browserBridge.start()
                            chromeSetupFlow.refreshSetupState()
                            if browserBridge.nativeHostSetupErrors.isEmpty {
                                browserHostStatusNote = "Native messaging host manifests verified."
                            } else {
                                browserHostStatusNote = browserBridge.nativeHostSetupErrors.first?.underlyingDescription
                            }
                        } label: {
                            Label("Install / Repair Chrome Host", systemImage: "wrench.and.screwdriver")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                        .fill(DS.Colors.surface3)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()

                        Button {
                            chromeSetupFlow.openChromeWebStore()
                        } label: {
                            Label("Chrome Web Store Setup", systemImage: "safari")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textOnAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                        .fill(DS.Colors.accent)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }

                    if chromeSetupFlow.hasOldCopyToRemove {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(DS.Colors.warning)
                            Text("Old unpacked extension detected.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.warningText)
                            Spacer()
                            Button("Open Extensions") {
                                chromeSetupFlow.openExtensionsPageForSwap()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.accentText)
                            .pointerCursor()
                        }
                    }

                    if let browserHostStatusNote {
                        Text(browserHostStatusNote)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
            }

            settingsCard(title: "UPLOAD & TOOL SECURITY") {
                Toggle(isOn: $configuration.alwaysApproveFileUploads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always Approve File Uploads")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Skip per-turn confirmation prompts when browser automation uploads local workspace files.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)
            }
        }
    }

    // MARK: - 8. Routines

    private var routinesSectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "SCHEDULED ROUTINES (\(routineScheduler.routines.count))") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        statusBadge(
                            label: routineScheduler.isNetworkAvailable ? "Network Ready" : "Offline",
                            isPositive: routineScheduler.isNetworkAvailable
                        )
                        if routineScheduler.isKeepAwakeAssertionActive {
                            statusBadge(label: "Keep-Awake Armed", isPositive: true)
                        }
                    }

                    if routineScheduler.routines.isEmpty {
                        Text("No scheduled routines yet. Ask any Clicky to repeat a task on a schedule to create one.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(routineScheduler.routines) { routine in
                            routineRow(routine)
                            if routine.id != routineScheduler.routines.last?.id {
                                Divider().background(DS.Colors.borderSubtle)
                            }
                        }
                    }
                }
            }
        }
    }

    private func routineRow(_ routine: ClickyRoutine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(routine.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)

                        if routine.isPaused {
                            Text("Paused")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Colors.warningText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DS.Colors.warning.opacity(0.15)))
                        }
                    }

                    Text(routine.cadenceLabel)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.accentText)

                    Text(routine.taskPrompt)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 6) {
                    Button(routine.isPaused ? "Resume" : "Pause") {
                        routineScheduler.togglePause(id: routine.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.surface3))
                    .pointerCursor()

                    Button("Run") {
                        Task { await routineScheduler.runNow(id: routine.id) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.accent))
                    .pointerCursor()

                    Button {
                        routineScheduler.delete(id: routine.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.destructiveText)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(DS.Colors.destructive.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            HStack(spacing: 12) {
                Text("Runs: \(routine.runCount)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)

                if let nextRunAt = routine.nextRunAt, !routine.isPaused {
                    Text("Next: \(nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                if let lastRunSummary = routine.lastRunSummary, !lastRunSummary.isEmpty {
                    Text(lastRunSummary)
                        .font(.system(size: 10))
                        .foregroundColor(routine.lastRunFailed ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 9. Memory

    private var memorySectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard(title: "USER MEMORY MARKDOWN") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shared across voice and agent turns. Stored at \(userMemoryStore.userMemoryFileURL.lastPathComponent).")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)

                    TextEditor(text: $memoryMarkdownDraft)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 160, maxHeight: 240)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.75)
                        )

                    HStack {
                        if didSaveMemoryRecently {
                            Text("Saved")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.success)
                        }

                        Spacer()

                        Button("Reload") {
                            userMemoryStore.loadFromDisk()
                            memoryMarkdownDraft = userMemoryStore.markdown
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.surface3))
                        .pointerCursor()

                        Button("Save Memory") {
                            userMemoryStore.save(memoryMarkdownDraft)
                            didSaveMemoryRecently = true
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                didSaveMemoryRecently = false
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.accent))
                        .pointerCursor()
                    }

                    Divider().background(DS.Colors.borderSubtle)

                    HStack(spacing: 8) {
                        TextField("Add standing preference...", text: $newPreferenceDraft)
                            .textFieldStyle(.plain)
                            .settingsInputChrome()

                        Button("Add") {
                            let trimmed = newPreferenceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            userMemoryStore.appendPreference(trimmed)
                            memoryMarkdownDraft = userMemoryStore.markdown
                            newPreferenceDraft = ""
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.accent))
                        .pointerCursor()
                    }

                    if !userMemoryStore.standingPreferences.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(userMemoryStore.standingPreferences, id: \.self) { preference in
                                HStack {
                                    Text("• \(preference)")
                                        .font(.system(size: 11))
                                        .foregroundColor(DS.Colors.textSecondary)
                                    Spacer()
                                    Button {
                                        userMemoryStore.removePreference(preference)
                                        memoryMarkdownDraft = userMemoryStore.markdown
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(DS.Colors.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .pointerCursor()
                                }
                            }
                        }
                    }
                }
            }

            settingsCard(title: "LEARNED HOW-TOS (\(learnedHowTosStore.howTos.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    if learnedHowTosStore.howTos.isEmpty {
                        Text("No learned how-tos yet. As Clicky completes jobs, reusable setup tips appear here.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    } else {
                        ForEach(learnedHowTosStore.howTos) { howTo in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(howTo.text)
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(howTo.learnedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            .padding(.vertical, 3)

                            if howTo.id != learnedHowTosStore.howTos.last?.id {
                                Divider().background(DS.Colors.borderSubtle)
                            }
                        }

                        HStack {
                            Spacer()
                            Button("Clear All How-Tos") {
                                learnedHowTosStore.removeAll()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.destructiveText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(DS.Colors.destructive.opacity(0.15)))
                            .pointerCursor()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reusable Components

    private func settingsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.75)
        )
    }

    private func labeledInputRow<Field: View>(
        label: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 96, alignment: .leading)

            field()
        }
    }

    private func permissionStatusRow(
        title: String,
        iconName: String,
        isGranted: Bool,
        subtitle: String,
        actionLabel: String,
        action: @escaping () -> Void,
        secondaryActionLabel: String? = nil,
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
                statusBadge(label: "Granted", isPositive: true)
            } else {
                HStack(spacing: 6) {
                    Button(actionLabel, action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.accent))
                        .pointerCursor()

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

    private func statusBadge(label: String, isPositive: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isPositive ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isPositive ? DS.Colors.success : DS.Colors.warningText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill((isPositive ? DS.Colors.success : DS.Colors.warning).opacity(0.14))
        )
    }

    private func languageSelectionRow(
        language: VoiceLanguage,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            HStack {
                Text(language.displayLabel)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)

                Spacer()

                Text(language.bcp47Locale)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.accentText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Helpers

    private func connectionModeSummary(_ mode: ClickyConnectionMode) -> String {
        switch mode {
        case .openCodex:
            return "Routes vision, chat, and agent turns through your local OpenCodex proxy with dynamic model discovery."
        case .byok:
            return "Calls Anthropic, OpenAI, Gemini, ElevenLabs, AssemblyAI, and Brave directly using keys stored in macOS Keychain."
        case .nativeAntigravity:
            return "Uses direct Google Cloud Code Assist PKCE OAuth with credentials stored in macOS Keychain."
        case .cloudflareWorker:
            return "Proxies requests through a configured Cloudflare Worker endpoint."
        }
    }

    private func filterLanguages(query: String) -> [VoiceLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return VoiceLanguageCatalog.supportedLanguages
        }
        return VoiceLanguageCatalog.supportedLanguages.filter { language in
            language.name.lowercased().contains(trimmed)
                || language.nativeName.lowercased().contains(trimmed)
                || language.code.lowercased().contains(trimmed)
                || language.bcp47Locale.lowercased().contains(trimmed)
        }
    }

    private func toggleModifier(_ modifierKey: ClickyShortcutModifierKey, for slot: ClickyShortcutSlot) {
        var updated = shortcutMonitor.binding(for: slot)
        if updated.triggerMode == .doubleTapModifier {
            updated.modifiers = [modifierKey]
        } else if updated.modifiers.contains(modifierKey) {
            if updated.modifiers.count > 1 || updated.keyCode != nil {
                updated.modifiers.removeAll { $0 == modifierKey }
            }
        } else {
            updated.modifiers.append(modifierKey)
        }
        shortcutMonitor.updateBinding(updated)
    }

    private func beginRecordingShortcutKey(for slot: ClickyShortcutSlot) {
        stopRecordingShortcutKey()
        recordingKeySlot = slot
        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecordingShortcutKey()
                return nil
            }
            var updated = shortcutMonitor.binding(for: slot)
            updated.keyCode = event.keyCode
            shortcutMonitor.updateBinding(updated)
            stopRecordingShortcutKey()
            return nil
        }
    }

    private func stopRecordingShortcutKey() {
        if let keyCaptureMonitor {
            NSEvent.removeMonitor(keyCaptureMonitor)
            self.keyCaptureMonitor = nil
        }
        recordingKeySlot = nil
    }

    private var loginItemStatusDescription: String {
        switch loginItemStatus {
        case .enabled:
            return "Enabled — Clicky launches automatically when you log in."
        case .requiresApproval:
            return "Requires approval in System Settings → General → Login Items."
        case .notRegistered, .notFound:
            return "Not enabled."
        @unknown default:
            return "Status unavailable."
        }
    }

    private func toggleLoginItemRegistration() {
        loginItemErrorMessage = nil
        do {
            if loginItemStatus == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            loginItemStatus = SMAppService.mainApp.status
        } catch {
            loginItemErrorMessage = error.localizedDescription
            loginItemStatus = SMAppService.mainApp.status
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

private extension View {
    func settingsInputChrome() -> some View {
        self
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.6)
            )
    }
}
