//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice, text, and background agent
//  pipelines. Owns dictation, 4-slot shortcut monitoring, active document context,
//  standing user memory, screen annotation streaming, realtime/turn-based voice,
//  and overlay management.
//

import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreFoundation
import CoreMedia
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

public nonisolated struct ClickyChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: String // "user", "assistant", "system"
    public var text: String
    public let timestamp: Date
    public let clickySlug: String?
    public var artifactPaths: [String]

    public init(
        id: UUID = UUID(),
        role: String,
        text: String,
        timestamp: Date = Date(),
        clickySlug: String? = nil,
        artifactPaths: [String] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.clickySlug = clickySlug
        self.artifactPaths = artifactPaths
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var activeAgentJobIDs: Set<String> = []

    // MARK: - Wave 2 Shared UI & Chat State

    @Published var activeDocumentContext: ActiveDocumentContext?
    @Published var activeDocumentNotice: DocumentAccessNotice?
    @Published var textInputDraft: String = ""
    @Published var chatMessages: [ClickyChatMessage] = []

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the AI response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?
    private var onboardingPromptStreamTask: Task<Void, Never>?
    private var onboardingAudioFadeTask: Task<Void, Never>?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()

    private let unifiedLLMClient = UnifiedLLMClient.shared
    private let configuration = ClickyConfiguration.shared

    private let elevenLabsTTSClient = ElevenLabsTTSClient.shared
    private let fallbackSpeechSynthesizer = AVSpeechSynthesizer()

    /// Conversation history so Clicky remembers prior exchanges within a session.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks or submits again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var activeAgentTasksByJobID: [String: Task<Void, Never>] = [:]
    private var lastBusyAt: Date = Date()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var shortcutSlotEventCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var configurationModelCancellable: AnyCancellable?
    private var hideCursorCancellable: AnyCancellable?
    private var activeDocumentNoticeCancellable: AnyCancellable?
    private var activeDocumentContextCancellable: AnyCancellable?
    private var realtimeStateCancellable: AnyCancellable?
    private var wakeWordCancellables: Set<AnyCancellable> = []
    private var wakeWordSleepObserver: NSObjectProtocol?
    private var wakeWordWakeObserver: NSObjectProtocol?
    private var wakeWordPlaybackObserver: NSObjectProtocol?
    private var isSystemSleepingForWakeWord = false
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// interacts again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all four required permissions (accessibility, screen recording,
    /// microphone, screen content) are granted.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    var isOnboardingActive: Bool {
        showOnboardingVideo || showOnboardingPrompt
    }

    var activeAgentTaskCount: Int {
        max(activeAgentJobIDs.count, AgentHarnessRunnerRuntime.shared.activeJobIDs.count)
    }

    var secondsSinceLastBusy: TimeInterval {
        if voiceState != .idle
            || buddyDictationManager.isDictationInProgress
            || activeAgentTaskCount > 0
            || RealtimeVoiceController.shared.state.isActive
            || ClickyTakeOverController.shared.phase != .idle
            || isOnboardingActive {
            return 0
        }
        return max(0, Date().timeIntervalSince(lastBusyAt))
    }

    func markBusy() {
        lastBusyAt = Date()
    }

    /// Whether the cursor overlay is currently visible on screen.
    @Published private(set) var isOverlayVisible: Bool = false

    /// Unified with `ClickyConfiguration.shared.selectedModel`.
    @Published var selectedModel: String = ClickyConfiguration.shared.selectedModel

    func setSelectedModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if ClickyConfiguration.shared.selectedModel != trimmed {
            ClickyConfiguration.shared.selectedModel = trimmed
        }
        selectedModel = trimmed
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay hides when idle and appears transiently during interactions.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    private var shouldShowPersistentOverlay: Bool {
        isClickyCursorEnabled && !ClickyConfiguration.shared.hideFloatingCursor
    }

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled && !ClickyConfiguration.shared.hideFloatingCursor {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = overlayWindowManager.isShowingOverlay()
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")

        startPermissionPolling()
        bindConfigurationSync()
        bindDocumentReaderObservation()
        bindAudioPowerLevel()
        bindVoiceStateObservation()
        bindShortcutMonitorCallbacks()
        bindRealtimeVoiceController()
        bindWakeWordListener()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately unless hidden.
        if hasCompletedOnboarding && allPermissionsGranted && shouldShowPersistentOverlay {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = overlayWindowManager.isShowingOverlay()
        }
    }

    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        markBusy()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        hasCompletedOnboarding = true
        ClickyAnalytics.trackOnboardingStarted()

        startOnboardingMusic()

        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = overlayWindowManager.isShowingOverlay()
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again" footer link.
    func replayOnboarding() {
        markBusy()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = overlayWindowManager.isShowingOverlay()
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingAudioFadeTask?.cancel()
        onboardingAudioFadeTask = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fadeOutOnboardingMusic()
                }
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        onboardingAudioFadeTask?.cancel()
        onboardingAudioFadeTask = Task { @MainActor [weak self] in
            let fadeSteps = 30
            let fadeDuration: Double = 3.0
            let stepNanoseconds = UInt64((fadeDuration / Double(fadeSteps)) * 1_000_000_000)
            let volumeDecrement = player.volume / Float(fadeSteps)

            for _ in 0..<fadeSteps {
                try? await Task.sleep(nanoseconds: stepNanoseconds)
                guard !Task.isCancelled else { return }
                player.volume = max(0, player.volume - volumeDecrement)
            }

            player.stop()
            self?.onboardingMusicPlayer = nil
            self?.onboardingMusicFadeTimer = nil
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        HeyClickyWakeWordListener.shared.stop()
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        RealtimeVoiceController.shared.stopSession()
        ScreenAnnotationManager.shared.clearAll()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        transientHideTask = nil

        currentResponseTask?.cancel()
        currentResponseTask = nil

        for (jobID, task) in activeAgentTasksByJobID {
            task.cancel()
            Task {
                try? await AgentHarnessRunnerRuntime.shared.cancel(jobID: jobID)
            }
        }
        activeAgentTasksByJobID.removeAll()
        activeAgentJobIDs.removeAll()

        shortcutTransitionCancellable?.cancel()
        shortcutSlotEventCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        configurationModelCancellable?.cancel()
        hideCursorCancellable?.cancel()
        activeDocumentNoticeCancellable?.cancel()
        activeDocumentContextCancellable?.cancel()
        realtimeStateCancellable?.cancel()
        wakeWordCancellables.removeAll()
        if let wakeWordSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeWordSleepObserver)
            self.wakeWordSleepObserver = nil
        }
        if let wakeWordWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeWordWakeObserver)
            self.wakeWordWakeObserver = nil
        }
        if let wakeWordPlaybackObserver {
            NotificationCenter.default.removeObserver(wakeWordPlaybackObserver)
            self.wakeWordPlaybackObserver = nil
        }
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }

        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy screenshot capture.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && shouldShowPersistentOverlay {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = overlayWindowManager.isShowingOverlay()
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Wave 2 Public Actions (Text Chat, Background Agents, Active Document)

    func refreshActiveDocumentContext() async {
        let context = await ActiveDocumentReader.shared.captureActiveContext()
        activeDocumentContext = context
        activeDocumentNotice = ActiveDocumentReader.shared.activeDocumentAccessNotice
    }

    func sendOpenCodexOrBYOKTestPrompt() {
        submitTextPrompt("Say hello in one short sentence and mention which model is replying.")
    }

    func submitTextPrompt(_ prompt: String, clickySlug: String? = nil) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        markBusy()
        lastErrorMessage = nil
        if textInputDraft.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedPrompt {
            textInputDraft = ""
        }

        ClickySoundEffectPlayer.shared.play(.clickyTextSend)
        UserMemoryStore.shared.extractAndPersistPreferences(fromUserText: trimmedPrompt)
        ClickyAnalytics.trackUserMessageSent(transcript: trimmedPrompt)

        let userMessage = ClickyChatMessage(
            role: "user",
            text: trimmedPrompt,
            clickySlug: clickySlug
        )
        chatMessages.append(userMessage)

        let assistantMessageID = UUID()
        chatMessages.append(
            ClickyChatMessage(
                id: assistantMessageID,
                role: "assistant",
                text: "",
                clickySlug: clickySlug
            )
        )

        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        RealtimeVoiceController.shared.interruptAssistantSpeech()
        clearDetectedElementLocation()

        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            self.voiceState = .processing

            do {
                let docContext = await ActiveDocumentReader.shared.captureActiveContext()
                self.activeDocumentContext = docContext
                self.activeDocumentNotice = ActiveDocumentReader.shared.activeDocumentAccessNotice

                let screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let systemPrompt = self.buildSystemPrompt(
                    basePrompt: Self.companionTextResponseSystemPrompt,
                    userInput: trimmedPrompt,
                    clickySlug: clickySlug
                )
                let enrichedUserPrompt = Self.composeUserPrompt(
                    rawUserText: trimmedPrompt,
                    documentContext: docContext
                )
                let historyForAPI = self.conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                var accumulatedResponse = ""
                var hasDetectedDrawingBlock = false

                let (fullResponseText, _) = try await self.unifiedLLMClient.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: enrichedUserPrompt,
                    onTextChunk: { [weak self] chunk in
                        guard let self else { return }
                        accumulatedResponse += chunk
                        self.markBusy()

                        if accumulatedResponse.contains("```"),
                           ScreenAnnotationManager.extractDrawingCode(from: accumulatedResponse, allowUnclosedFence: true) != nil {
                            hasDetectedDrawingBlock = true
                            _ = ScreenAnnotationManager.shared.feedStreamingResponse(accumulatedResponse, done: false)
                        }

                        let visibleText = Self.stripDrawingCodeBlocksAndPointTags(from: accumulatedResponse)
                        self.updateAssistantMessage(id: assistantMessageID, text: visibleText)
                    }
                )

                guard !Task.isCancelled else { return }

                if hasDetectedDrawingBlock || ScreenAnnotationManager.extractDrawingCode(from: fullResponseText, allowUnclosedFence: false) != nil {
                    _ = ScreenAnnotationManager.shared.feedStreamingResponse(fullResponseText, done: true)
                }

                let textWithoutDrawingBlocks = Self.stripDrawingCodeBlocks(from: fullResponseText)
                let parseResult = Self.parsePointingCoordinates(from: textWithoutDrawingBlocks)
                let displayReply = parseResult.spokenText.isEmpty
                    ? "Drawn on your screen."
                    : parseResult.spokenText

                self.updateAssistantMessage(id: assistantMessageID, text: displayReply)

                if parseResult.coordinate != nil {
                    self.voiceState = .idle
                }
                self.handlePointingResult(parseResult, screenCaptures: screenCaptures)

                self.appendConversationExchange(
                    userTranscript: trimmedPrompt,
                    assistantResponse: displayReply
                )

                ClickySoundEffectPlayer.shared.play(.clickyTextReceive)
                ClickyAnalytics.trackAIResponseReceived(response: displayReply)
            } catch is CancellationError {
                self.removeEmptyAssistantPlaceholder(id: assistantMessageID)
            } catch {
                let errorMessage = Self.formatProviderError(error)
                self.lastErrorMessage = errorMessage
                self.updateAssistantMessage(id: assistantMessageID, text: errorMessage)
                ClickySoundEffectPlayer.shared.play(.nope)
                ClickyAnalytics.trackResponseError(error: errorMessage)
            }

            if !Task.isCancelled {
                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()
            }
        }
    }

    func startBackgroundAgentTask(prompt: String, clickySlug: String? = nil) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        markBusy()
        lastErrorMessage = nil
        UserMemoryStore.shared.extractAndPersistPreferences(fromUserText: trimmedPrompt)

        let resolvedSlug = resolveClickySlug(requestedSlug: clickySlug)
        let workspaceURL = ClickyWorkFolderFiles.shared.ensureClickyWorkspace(slug: resolvedSlug)
        let threadID = ClickyRoster.shared.threadBindingsBySlug[resolvedSlug] ?? UUID().uuidString
        ClickyRoster.shared.bindThread(threadID, toSlug: resolvedSlug)

        let job = ClickyJobStore.shared.createJob(
            clickySlug: resolvedSlug,
            title: Self.deriveJobTitle(from: trimmedPrompt),
            prompt: trimmedPrompt,
            threadID: threadID,
            folderPath: workspaceURL.path
        )

        chatMessages.append(
            ClickyChatMessage(
                role: "user",
                text: trimmedPrompt,
                clickySlug: resolvedSlug
            )
        )

        ClickySoundEffectPlayer.shared.play(.agentLaunch)
        activeAgentJobIDs.insert(job.id)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runBackgroundAgentJob(
                job: job,
                prompt: trimmedPrompt,
                clickySlug: resolvedSlug,
                workspaceURL: workspaceURL,
                threadID: threadID
            )
        }
        activeAgentTasksByJobID[job.id] = task
    }

    func stopActiveAgentTask(jobID: String) {
        if let runningTask = activeAgentTasksByJobID.removeValue(forKey: jobID) {
            runningTask.cancel()
        }
        activeAgentJobIDs.remove(jobID)

        if let job = ClickyJobStore.shared.job(withID: jobID) {
            Task {
                try? await AgentHarnessRunnerRuntime.shared.cancel(jobID: job.threadID)
            }
            if job.outcome == .working {
                ClickyJobStore.shared.finishLatestRun(
                    jobID: job.id,
                    outcome: .stopped,
                    summary: "Stopped by user."
                )
            }
        }

        ClickySoundEffectPlayer.shared.play(.agentClose)
        markBusy()
    }

    private func runBackgroundAgentJob(
        job: ClickyJob,
        prompt: String,
        clickySlug: String,
        workspaceURL: URL,
        threadID: String
    ) async {
        let startedAt = Date()
        let traceID = ClickyAITracing.shared.beginTrace(prefix: "agent")
        let agentModel = ClickyConfiguration.shared.selectedAgentModel
        ClickyAnalytics.trackAgentTurnStarted(clickySlug: clickySlug, model: agentModel, traceID: traceID)

        defer {
            activeAgentTasksByJobID.removeValue(forKey: job.id)
            activeAgentJobIDs.remove(job.id)
            ClickyAITracing.shared.endTrace(traceID)
            markBusy()
        }

        do {
            let docContext = await ActiveDocumentReader.shared.captureActiveContext()
            activeDocumentContext = docContext
            activeDocumentNotice = ActiveDocumentReader.shared.activeDocumentAccessNotice

            if !ClickyLoopbackMCPServer.shared.isRunning {
                try? ClickyLoopbackMCPServer.shared.start()
            }

            var mcpServers: [String: Any] = [:]
            if let endpointURL = ClickyLoopbackMCPServer.shared.endpointURL {
                mcpServers["clicky"] = [
                    "name": "clicky",
                    "type": "http",
                    "url": endpointURL.absoluteString,
                    "headers": [
                        "Authorization": "Bearer \(ClickyLoopbackMCPServer.shared.bearerToken)"
                    ]
                ]
            }

            let agentsMarkdown = ClickyWorkFolderFiles.shared.readAgentsMarkdown(forSlug: clickySlug)
            let userMemoryBlock = UserMemoryStore.shared.formattedUserMemoryPromptBlock()
                ?? UserMemoryStore.shared.markdown
            let learnedHowTosBlock = ClickyLearnedHowTos.shared.formattedPromptBlock(forPrompt: prompt) ?? ""

            let standingContext = ClickyAgentStandingContextLedger.buildStandingContextPayload(
                threadID: threadID,
                userMemory: userMemoryBlock,
                agentInstructions: agentsMarkdown,
                activeSkills: "",
                learnedHowTos: learnedHowTosBlock,
                commitImmediately: true
            )

            let effectivePrompt = Self.composeUserPrompt(
                rawUserText: prompt,
                documentContext: docContext
            )

            var finalReplyText = ""
            var finalArtifactPaths: [String] = []

            _ = try await AgentHarnessRunnerRuntime.shared.startTurn(
                threadID: threadID,
                clickySlug: clickySlug,
                prompt: effectivePrompt,
                workspaceURL: workspaceURL,
                model: agentModel,
                mcpServers: mcpServers,
                skillDirectories: [],
                instructions: standingContext.injectedText,
                imagePaths: [],
                onEvent: { [weak self] event in
                    guard let self else { return }
                    self.markBusy()

                    switch event.payload {
                    case .commentary(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            ClickyJobStore.shared.updateJob(id: job.id) { currentJob in
                                currentJob.summary = trimmed
                            }
                        }

                    case .note(_, _, let text):
                        if let text {
                            ClickyWorkFolderFiles.shared.writeLiveNote(text, forSlug: clickySlug)
                        }

                    case .answer(let rawText, let parsed):
                        let body = parsed.displayBody.isEmpty ? rawText : parsed.displayBody
                        finalReplyText = body
                        finalArtifactPaths = parsed.artifacts

                        let artifactEntries = parsed.artifacts.map { path in
                            ClickyJobArtifactEntry(
                                path: path,
                                title: URL(fileURLWithPath: path).lastPathComponent
                            )
                        }

                        ClickyJobStore.shared.appendReply(
                            jobID: job.id,
                            replyText: body,
                            summary: parsed.summary,
                            outcome: parsed.waitFor != nil ? .working : .done,
                            artifactEntries: artifactEntries
                        )

                        if let learned = parsed.learned, !learned.isEmpty {
                            ClickyLearnedHowTos.shared.record(learned, jobID: job.id)
                        }

                        if let waitFor = parsed.waitFor, !waitFor.isEmpty {
                            ClickyJobStore.shared.setWaitingStep(
                                jobID: job.id,
                                step: ClickyJobUserStep(step: waitFor)
                            )
                            ClickySoundEffectPlayer.shared.play(.agentNeedsYou)
                        }

                    case .turnEnd(let status, let error):
                        if status == "failed" {
                            let message = error ?? "Agent turn failed."
                            ClickyJobStore.shared.finishLatestRun(
                                jobID: job.id,
                                outcome: .failed,
                                summary: message
                            )
                        }

                    default:
                        break
                    }
                }
            )

            if let updatedJob = ClickyJobStore.shared.job(withID: job.id), updatedJob.outcome == .working {
                ClickyJobStore.shared.finishLatestRun(
                    jobID: job.id,
                    outcome: .done,
                    summary: finalReplyText.isEmpty ? updatedJob.summary : finalReplyText
                )
            }

            let assistantMessageText = finalReplyText.isEmpty
                ? (ClickyJobStore.shared.job(withID: job.id)?.replyText ?? "Done.")
                : finalReplyText

            chatMessages.append(
                ClickyChatMessage(
                    role: "assistant",
                    text: assistantMessageText,
                    clickySlug: clickySlug,
                    artifactPaths: finalArtifactPaths
                )
            )

            ClickySoundEffectPlayer.shared.play(.agentDone)
            ClickyAnalytics.trackAgentTurnCompleted(
                clickySlug: clickySlug,
                durationSeconds: Date().timeIntervalSince(startedAt),
                succeeded: true,
                traceID: traceID
            )
        } catch is CancellationError {
            ClickyJobStore.shared.finishLatestRun(
                jobID: job.id,
                outcome: .stopped,
                summary: "Stopped."
            )
        } catch {
            let errorMessage = Self.formatProviderError(error)
            lastErrorMessage = errorMessage
            ClickyJobStore.shared.finishLatestRun(
                jobID: job.id,
                outcome: .failed,
                summary: errorMessage
            )
            chatMessages.append(
                ClickyChatMessage(
                    role: "assistant",
                    text: errorMessage,
                    clickySlug: clickySlug
                )
            )
            ClickySoundEffectPlayer.shared.play(.nope)
            ClickyAnalytics.trackAgentTurnCompleted(
                clickySlug: clickySlug,
                durationSeconds: Date().timeIntervalSince(startedAt),
                succeeded: false,
                traceID: traceID,
                error: errorMessage
            )
        }
    }

    func executeScheduledRoutine(
        _ routine: ClickyRoutine,
        trigger: ClickyRoutineRunTrigger
    ) async -> ClickyRoutineRunOutcome {
        if activeAgentTaskCount >= 4 {
            return .skippedBusy
        }

        markBusy()
        ClickyAnalytics.trackRoutineTriggered(routineName: routine.title)

        let slug = resolveClickySlug(requestedSlug: routine.clickySlug)
        let workspaceURL = ClickyWorkFolderFiles.shared.ensureClickyWorkspace(slug: slug)
        if trigger == .scheduled {
            _ = ClickyWorkFolderFiles.shared.rotateNoteToPrevious(forSlug: slug)
        }

        let threadID = ClickyRoster.shared.threadBindingsBySlug[slug] ?? UUID().uuidString
        ClickyRoster.shared.bindThread(threadID, toSlug: slug)

        let job = ClickyJobStore.shared.createJob(
            clickySlug: slug,
            title: routine.title,
            prompt: routine.taskPrompt,
            threadID: threadID,
            folderPath: workspaceURL.path
        )
        activeAgentJobIDs.insert(job.id)
        defer {
            activeAgentJobIDs.remove(job.id)
            markBusy()
        }

        do {
            if !ClickyLoopbackMCPServer.shared.isRunning {
                try? ClickyLoopbackMCPServer.shared.start()
            }

            var mcpServers: [String: Any] = [:]
            if let endpointURL = ClickyLoopbackMCPServer.shared.endpointURL {
                mcpServers["clicky"] = [
                    "name": "clicky",
                    "type": "http",
                    "url": endpointURL.absoluteString,
                    "headers": [
                        "Authorization": "Bearer \(ClickyLoopbackMCPServer.shared.bearerToken)"
                    ]
                ]
            }

            let agentsMarkdown = ClickyWorkFolderFiles.shared.readAgentsMarkdown(forSlug: slug)
            let userMemoryBlock = UserMemoryStore.shared.formattedUserMemoryPromptBlock()
                ?? UserMemoryStore.shared.markdown
            let standingContext = ClickyAgentStandingContextLedger.buildStandingContextPayload(
                threadID: threadID,
                userMemory: userMemoryBlock,
                agentInstructions: agentsMarkdown,
                commitImmediately: true
            )

            var runSummary: String?
            _ = try await AgentHarnessRunnerRuntime.shared.startTurn(
                threadID: threadID,
                clickySlug: slug,
                prompt: routine.taskPrompt,
                workspaceURL: workspaceURL,
                model: ClickyConfiguration.shared.selectedAgentModel,
                mcpServers: mcpServers,
                skillDirectories: [],
                instructions: standingContext.injectedText,
                imagePaths: [],
                onEvent: { event in
                    if case .answer(let rawText, let parsed) = event.payload {
                        let body = parsed.displayBody.isEmpty ? rawText : parsed.displayBody
                        runSummary = parsed.summary ?? body
                        ClickyJobStore.shared.appendReply(
                            jobID: job.id,
                            replyText: body,
                            summary: parsed.summary,
                            outcome: .done
                        )
                    }
                }
            )

            if let currentJob = ClickyJobStore.shared.job(withID: job.id), currentJob.outcome == .working {
                ClickyJobStore.shared.finishLatestRun(jobID: job.id, outcome: .done, summary: runSummary)
            }
            ClickySoundEffectPlayer.shared.play(.agentDone)
            return .succeeded(summary: runSummary)
        } catch {
            let formatted = Self.formatProviderError(error)
            ClickyJobStore.shared.finishLatestRun(jobID: job.id, outcome: .failed, summary: formatted)
            let isTransientNetworkError = (error as? URLError) != nil
            return .failed(summary: formatted, transientConnectivity: isTransientNetworkError)
        }
    }

    // MARK: - Idle Update Install Conditions

    func currentIdleUpdateInstallConditions() -> IdleUpdateInstallConditions {
        let isVoiceActive = voiceState != .idle
        let isRealtimeActive = RealtimeVoiceController.shared.state.isActive
        let isDictating = buddyDictationManager.isDictationInProgress
        let isShowingSomething = ScreenAnnotationManager.shared.isActive
            || detectedElementScreenLocation != nil
            || isOverlayVisible && !shouldShowPersistentOverlay
        let isDrivingMac = ClickyTakeOverController.shared.phase != .idle
        let isFullscreen = Self.isFrontmostApplicationFullscreen()

        return IdleUpdateInstallConditions(
            secondsSinceHeyClickyWasLastBusy: secondsSinceLastBusy,
            isOnboardingInProgress: isOnboardingActive,
            activeAgentTaskCount: activeAgentTaskCount,
            isVoiceTurnActive: isVoiceActive,
            isRealtimeVoiceSessionOpen: isRealtimeActive,
            isRecordingOrDictating: isDictating,
            isNotchOpen: NotchWindowManager.shared.isExpanded,
            isNotchAnswerInProgress: isVoiceActive || activeAgentTaskCount > 0,
            isShowingSomethingOnScreen: isShowingSomething,
            isDrivingTheMac: isDrivingMac,
            isOnACall: false,
            isFrontmostAppFullscreen: isFullscreen
        )
    }

    // MARK: - Private Bindings & Permissions

    private func bindConfigurationSync() {
        selectedModel = ClickyConfiguration.shared.selectedModel

        configurationModelCancellable = ClickyConfiguration.shared.$selectedModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedModel in
                guard let self else { return }
                if self.selectedModel != updatedModel {
                    self.selectedModel = updatedModel
                }
            }

        hideCursorCancellable = ClickyConfiguration.shared.$hideFloatingCursor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldHide in
                guard let self else { return }
                if shouldHide {
                    if self.voiceState == .idle && self.detectedElementScreenLocation == nil && !self.isOnboardingActive {
                        self.overlayWindowManager.hideOverlay()
                        self.isOverlayVisible = false
                    }
                } else if self.hasCompletedOnboarding && self.allPermissionsGranted && self.isClickyCursorEnabled {
                    self.overlayWindowManager.hasShownOverlayBefore = true
                    self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                    self.isOverlayVisible = self.overlayWindowManager.isShowingOverlay()
                }
            }
    }

    private func bindDocumentReaderObservation() {
        activeDocumentNotice = ActiveDocumentReader.shared.activeDocumentAccessNotice
        activeDocumentContext = ActiveDocumentReader.shared.lastCapturedContext

        activeDocumentNoticeCancellable = ActiveDocumentReader.shared.$activeDocumentAccessNotice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                self?.activeDocumentNotice = notice
            }

        activeDocumentContextCancellable = ActiveDocumentReader.shared.$lastCapturedContext
            .receive(on: DispatchQueue.main)
            .sink { [weak self] context in
                self?.activeDocumentContext = context
            }
    }

    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .combineLatest(RealtimeVoiceController.shared.$currentAudioPowerLevel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dictationPower, realtimePower in
                self?.currentAudioPowerLevel = max(dictationPower, realtimePower)
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isWakeWordRecording,
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isShortcutRecording, isWakeRecording, isFinalizing, isPreparing in
                guard let self else { return }
                guard self.voiceState != .responding else { return }
                guard !RealtimeVoiceController.shared.state.isActive else { return }

                let isRecording = isShortcutRecording || isWakeRecording

                if isFinalizing {
                    self.markBusy()
                    self.voiceState = .processing
                } else if isRecording {
                    self.markBusy()
                    self.voiceState = .listening
                } else if isPreparing {
                    self.markBusy()
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindWakeWordListener() {
        wakeWordCancellables.removeAll()

        HeyClickyWakeWordListener.shared.onWakeDetected = { [weak self] trailingText in
            guard let self else { return }
            guard !self.buddyDictationManager.isDictationInProgress else { return }
            guard !self.showOnboardingVideo else { return }

            self.markBusy()
            self.transientHideTask?.cancel()
            self.transientHideTask = nil

            if !self.shouldShowPersistentOverlay && !self.isOverlayVisible {
                self.overlayWindowManager.hasShownOverlayBefore = true
                self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                self.isOverlayVisible = self.overlayWindowManager.isShowingOverlay()
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            self.currentResponseTask?.cancel()
            self.elevenLabsTTSClient.stopPlayback()
            self.fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)
            RealtimeVoiceController.shared.interruptAssistantSpeech()
            self.clearDetectedElementLocation()

            ClickySoundEffectPlayer.shared.play(.gelPop)
            self.voiceState = .listening

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.buddyDictationManager.startWakeTriggeredCapture(
                    initialTrailingText: trailingText,
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        print("🗣️ Companion received wake-call transcript: \(finalTranscript)")
                        ClickySoundEffectPlayer.shared.play(.clickyTextSend)
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
                self.syncWakeWordListenerState()
            }
        }

        configuration.$voiceWakeWordEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWakeWordListenerState() }
            .store(in: &wakeWordCancellables)

        configuration.$voiceWakePhrase
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWakeWordListenerState() }
            .store(in: &wakeWordCancellables)

        $voiceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWakeWordListenerState() }
            .store(in: &wakeWordCancellables)

        buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isWakeWordRecording,
                buddyDictationManager.$isSystemWideDictationActive,
                buddyDictationManager.$isFinalizingTranscript
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.syncWakeWordListenerState() }
            .store(in: &wakeWordCancellables)

        RealtimeVoiceController.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncWakeWordListenerState() }
            .store(in: &wakeWordCancellables)

        wakeWordPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .clickyElevenLabsPlaybackDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncWakeWordListenerState()
            }
        }

        wakeWordSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSystemSleepingForWakeWord = true
                self?.syncWakeWordListenerState()
            }
        }

        wakeWordWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSystemSleepingForWakeWord = false
                self?.syncWakeWordListenerState()
            }
        }

        syncWakeWordListenerState()
    }

    func syncWakeWordListenerState() {
        let pauseReason: String?
        if isSystemSleepingForWakeWord {
            pauseReason = "Mac sleeping"
        } else if buddyDictationManager.isDictationInProgress {
            pauseReason = "recording"
        } else if RealtimeVoiceController.shared.state.isActive {
            pauseReason = "realtime voice"
        } else if elevenLabsTTSClient.isPlaying || fallbackSpeechSynthesizer.isSpeaking {
            pauseReason = "speaking"
        } else if voiceState != .idle {
            pauseReason = "busy"
        } else {
            pauseReason = nil
        }

        HeyClickyWakeWordListener.shared.sync(
            enabled: configuration.voiceWakeWordEnabled,
            phraseSetting: configuration.voiceWakePhrase,
            pauseReason: pauseReason
        )
    }

    private func bindRealtimeVoiceController() {
        RealtimeVoiceController.shared.turnBasedHandler = { [weak self] userText in
            guard let self else { return "" }
            return try await self.executeTurnBasedVoiceTurn(userText: userText)
        }

        realtimeStateCancellable = RealtimeVoiceController.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] realtimeState in
                guard let self else { return }
                switch realtimeState {
                case .connecting, .thinking:
                    self.markBusy()
                    self.voiceState = .processing
                case .listening:
                    self.markBusy()
                    self.voiceState = .listening
                case .speaking:
                    self.markBusy()
                    self.voiceState = .responding
                case .error(let message):
                    self.lastErrorMessage = message
                    ClickySoundEffectPlayer.shared.play(.nope)
                    self.voiceState = .idle
                    self.scheduleTransientHideIfNeeded()
                case .idle:
                    if !self.buddyDictationManager.isDictationInProgress && self.currentResponseTask == nil {
                        self.voiceState = .idle
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutMonitorCallbacks() {
        // Attach Type Anywhere dictation slots (dictationHold, handsFreeDictation, escape)
        buddyDictationManager.attachShortcutMonitor(globalPushToTalkShortcutMonitor)

        // Attach voiceHold push-to-talk transitions
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        // Attach textTrigger, dictation audio cues, and Escape interrupt
        shortcutSlotEventCancellable = globalPushToTalkShortcutMonitor
            .slotEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .triggered(let slot) where slot == .textTrigger:
                    self.markBusy()
                    NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                    ClickySoundEffectPlayer.shared.play(.clickyTextOpen)
                    NotchWindowManager.shared.showNotchPeek(tab: .chat)

                case .pressed(let slot) where slot == .dictationHold:
                    self.markBusy()
                    ClickySoundEffectPlayer.shared.play(.gelPop)

                case .triggered(let slot) where slot == .handsFreeDictation:
                    self.markBusy()
                    ClickySoundEffectPlayer.shared.play(.gelPop)

                case .escapeInterrupted:
                    self.interruptAllActiveOperations()

                default:
                    break
                }
            }
    }

    private func interruptAllActiveOperations() {
        markBusy()
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil

        currentResponseTask?.cancel()
        currentResponseTask = nil

        elevenLabsTTSClient.stopPlayback()
        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)
        RealtimeVoiceController.shared.interruptAssistantSpeech()
        if RealtimeVoiceController.shared.state.isActive {
            RealtimeVoiceController.shared.stopSession()
        }

        if buddyDictationManager.isDictationInProgress {
            buddyDictationManager.cancelCurrentDictation(preserveDraftText: true)
        }

        if ClickyTakeOverController.shared.phase != .idle {
            ClickyTakeOverController.shared.abortForUserTakeOver(reason: "escape")
        }

        ScreenAnnotationManager.shared.clearAll()
        clearDetectedElementLocation()
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard !showOnboardingVideo else { return }

            markBusy()
            transientHideTask?.cancel()
            transientHideTask = nil

            if !shouldShowPersistentOverlay && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = overlayWindowManager.isShowingOverlay()
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)
            RealtimeVoiceController.shared.interruptAssistantSpeech()
            clearDetectedElementLocation()

            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.showOnboardingPrompt = false
                    self?.onboardingPromptText = ""
                }
            }

            ClickySoundEffectPlayer.shared.play(.gelPop)
            ClickyAnalytics.trackPushToTalkStarted()

            // If user explicitly chose Realtime Duplex and a duplex route is available,
            // launch the duplex session; otherwise use push-to-talk dictation -> screen/doc LLM turn.
            if configuration.voicePipelineMode == .realtimeDuplex,
               case .realtimeDuplex = RealtimeVoiceController.shared.resolvePreferredRoute() {
                pendingKeyboardShortcutStartTask?.cancel()
                pendingKeyboardShortcutStartTask = Task {
                    await RealtimeVoiceController.shared.startSession()
                }
                return
            }

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickySoundEffectPlayer.shared.play(.clickyTextSend)
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }

        case .released:
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil

            if configuration.voicePipelineMode == .realtimeDuplex,
               RealtimeVoiceController.shared.state.isActive {
                RealtimeVoiceController.shared.stopSession()
                return
            }

            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

        case .none:
            break
        }
    }

    // MARK: - Companion Prompts

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen or open document, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].
    """

    private static let companionTextResponseSystemPrompt = """
    You are HeyClicky, a sharp, helpful macOS desktop companion. You can see the user's screen(s) and active document context when available, and you remember prior exchanges and standing preferences.

    Be direct, clear, and practical. Use clean Markdown when helpful for structured explanations or code. If pointing at a specific on-screen UI element helps, you may append `[POINT:x,y:label]` (or `[POINT:x,y:label:screenN]`) at the end of your reply.
    """

    private func buildSystemPrompt(
        basePrompt: String,
        userInput: String,
        clickySlug: String? = nil
    ) -> String {
        var sections = [basePrompt]

        let selectedLanguageCode = ClickyConfiguration.shared.selectedVoiceLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !selectedLanguageCode.isEmpty && selectedLanguageCode != "auto" {
            let language = VoiceLanguageCatalog.language(forCode: selectedLanguageCode)
            let displayName = language?.name ?? selectedLanguageCode
            let nativeName = language?.nativeName ?? displayName
            let bcp47 = language?.bcp47Locale ?? selectedLanguageCode
            sections.append(
                """
                <response_language>
                Always reply in \(displayName) (\(nativeName), locale: \(bcp47)) unless the user explicitly asks to write or translate in another language. Use natural conversational \(displayName) phrasing.
                </response_language>
                """
            )
        }

        if let clickySlug,
           let profile = ClickyRoster.shared.clicky(forSlug: clickySlug) {
            sections.append(
                "<clicky_persona>\nName: \(profile.name)\nRole: \(profile.roleText)\nSummary: \(profile.oneLiner)\n</clicky_persona>"
            )
        }

        if let userMemoryBlock = UserMemoryStore.shared.formattedUserMemoryPromptBlock() {
            sections.append(userMemoryBlock)
        }

        if let howTosBlock = ClickyLearnedHowTos.shared.formattedPromptBlock(forPrompt: userInput) {
            sections.append(howTosBlock)
        }

        return sections.joined(separator: "\n\n")
    }

    private static func composeUserPrompt(
        rawUserText: String,
        documentContext: ActiveDocumentContext?
    ) -> String {
        guard let documentContext else {
            return rawUserText
        }

        var parts: [String] = []
        parts.append("<active_document>")
        parts.append("source: \(documentContext.reference.rawLocation)")
        parts.append("title: \(documentContext.reference.displayTitle)")
        if let appName = documentContext.applicationName, !appName.isEmpty {
            parts.append("application: \(appName)")
        }
        if let windowTitle = documentContext.windowTitle, !windowTitle.isEmpty {
            parts.append("window: \(windowTitle)")
        }
        parts.append(documentContext.promptContextSummary())
        if let selected = documentContext.selectedText,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("selected_text:\n\(selected)")
        }
        let body = documentContext.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            parts.append("document_text:\n\(body)")
        }
        parts.append("</active_document>")
        parts.append(rawUserText)
        return parts.joined(separator: "\n")
    }

    // MARK: - AI Voice Response Pipeline

    private func executeTurnBasedVoiceTurn(userText: String) async throws -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        UserMemoryStore.shared.extractAndPersistPreferences(fromUserText: trimmed)
        let docContext = await ActiveDocumentReader.shared.captureActiveContext()
        activeDocumentContext = docContext
        activeDocumentNotice = ActiveDocumentReader.shared.activeDocumentAccessNotice

        let screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
        let labeledImages = screenCaptures.map { capture in
            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
            return (data: capture.imageData, label: capture.label + dimensionInfo)
        }

        let systemPrompt = buildSystemPrompt(
            basePrompt: Self.companionVoiceResponseSystemPrompt,
            userInput: trimmed
        )
        let enrichedUserPrompt = Self.composeUserPrompt(
            rawUserText: trimmed,
            documentContext: docContext
        )
        let historyForAPI = conversationHistory.map { entry in
            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
        }

        var accumulatedResponse = ""
        let (fullResponseText, _) = try await unifiedLLMClient.analyzeImageStreaming(
            images: labeledImages,
            systemPrompt: systemPrompt,
            conversationHistory: historyForAPI,
            userPrompt: enrichedUserPrompt,
            onTextChunk: { chunk in
                accumulatedResponse += chunk
                if accumulatedResponse.contains("```"),
                   ScreenAnnotationManager.extractDrawingCode(from: accumulatedResponse, allowUnclosedFence: true) != nil {
                    _ = ScreenAnnotationManager.shared.feedStreamingResponse(accumulatedResponse, done: false)
                }
            }
        )

        if ScreenAnnotationManager.extractDrawingCode(from: fullResponseText, allowUnclosedFence: false) != nil {
            _ = ScreenAnnotationManager.shared.feedStreamingResponse(fullResponseText, done: true)
        }

        let textWithoutDrawingBlocks = Self.stripDrawingCodeBlocks(from: fullResponseText)
        let parseResult = Self.parsePointingCoordinates(from: textWithoutDrawingBlocks)
        handlePointingResult(parseResult, screenCaptures: screenCaptures)
        appendConversationExchange(userTranscript: trimmed, assistantResponse: parseResult.spokenText)

        return parseResult.spokenText
    }

    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }

        markBusy()
        lastErrorMessage = nil
        UserMemoryStore.shared.extractAndPersistPreferences(fromUserText: trimmedTranscript)

        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            self.voiceState = .processing

            do {
                let docContext = await ActiveDocumentReader.shared.captureActiveContext()
                self.activeDocumentContext = docContext
                self.activeDocumentNotice = ActiveDocumentReader.shared.activeDocumentAccessNotice

                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let systemPrompt = self.buildSystemPrompt(
                    basePrompt: Self.companionVoiceResponseSystemPrompt,
                    userInput: trimmedTranscript
                )
                let enrichedUserPrompt = Self.composeUserPrompt(
                    rawUserText: trimmedTranscript,
                    documentContext: docContext
                )
                let historyForAPI = self.conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                var accumulatedResponse = ""
                var hasDetectedDrawingBlock = false

                let (fullResponseText, _) = try await self.unifiedLLMClient.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: enrichedUserPrompt,
                    onTextChunk: { chunk in
                        accumulatedResponse += chunk
                        if accumulatedResponse.contains("```"),
                           ScreenAnnotationManager.extractDrawingCode(from: accumulatedResponse, allowUnclosedFence: true) != nil {
                            hasDetectedDrawingBlock = true
                            _ = ScreenAnnotationManager.shared.feedStreamingResponse(accumulatedResponse, done: false)
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                if hasDetectedDrawingBlock || ScreenAnnotationManager.extractDrawingCode(from: fullResponseText, allowUnclosedFence: false) != nil {
                    _ = ScreenAnnotationManager.shared.feedStreamingResponse(fullResponseText, done: true)
                }

                let textWithoutDrawingBlocks = Self.stripDrawingCodeBlocks(from: fullResponseText)
                let parseResult = Self.parsePointingCoordinates(from: textWithoutDrawingBlocks)
                let spokenText = parseResult.spokenText

                if parseResult.coordinate != nil {
                    self.voiceState = .idle
                }
                self.handlePointingResult(parseResult, screenCaptures: screenCaptures)

                self.appendConversationExchange(
                    userTranscript: trimmedTranscript,
                    assistantResponse: spokenText
                )

                ClickySoundEffectPlayer.shared.play(.clickyTextReceive)
                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await self.speakVoiceResponse(spokenText)
                }
            } catch is CancellationError {
                // Interrupted by user speaking again or Escape
            } catch {
                let errorMessage = Self.formatProviderError(error)
                self.lastErrorMessage = errorMessage
                ClickySoundEffectPlayer.shared.play(.nope)
                ClickyAnalytics.trackResponseError(error: errorMessage)
                print("⚠️ Companion response error: \(errorMessage)")
                self.speakProviderErrorFallback(message: errorMessage)
            }

            if !Task.isCancelled {
                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()
            }
        }
    }

    private func speakVoiceResponse(_ spokenText: String) async {
        let config = ClickyConfiguration.shared
        let hasElevenLabsKey = !config.elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasElevenLabsKey || config.mode == .cloudflareWorker {
            do {
                try await elevenLabsTTSClient.speakText(spokenText)
                voiceState = .responding
                syncWakeWordListenerState()
                return
            } catch {
                ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                lastErrorMessage = error.localizedDescription
                print("⚠️ ElevenLabs TTS error, cascading via RealtimeVoiceController: \(error.localizedDescription)")
            }
        }

        voiceState = .responding
        await RealtimeVoiceController.shared.speakTurnBasedResponse(spokenText)
    }

    private func handlePointingResult(
        _ parseResult: PointingParseResult,
        screenCaptures: [CompanionScreenCapture]
    ) {
        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber = parseResult.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()

        if let pointCoordinate = parseResult.coordinate,
           let targetScreenCapture {
            let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
            let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
            let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
            let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
            let displayFrame = targetScreenCapture.displayFrame

            let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
            let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

            let displayLocalX = clampedX * (displayWidth / screenshotWidth)
            let displayLocalY = clampedY * (displayHeight / screenshotHeight)
            let appKitY = displayHeight - displayLocalY

            let globalLocation = CGPoint(
                x: displayLocalX + displayFrame.origin.x,
                y: appKitY + displayFrame.origin.y
            )

            detectedElementScreenLocation = globalLocation
            detectedElementDisplayFrame = displayFrame
            ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
            print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
        } else {
            print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
        }
    }

    private func appendConversationExchange(userTranscript: String, assistantResponse: String) {
        conversationHistory.append((
            userTranscript: userTranscript,
            assistantResponse: assistantResponse
        ))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        print("🧠 Conversation history: \(conversationHistory.count) exchanges")
    }

    private func updateAssistantMessage(id: UUID, text: String) {
        guard let index = chatMessages.firstIndex(where: { message in message.id == id }) else {
            return
        }
        chatMessages[index].text = text
    }

    private func removeEmptyAssistantPlaceholder(id: UUID) {
        guard let index = chatMessages.firstIndex(where: { message in message.id == id }),
              chatMessages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        chatMessages.remove(at: index)
    }

    private func resolveClickySlug(requestedSlug: String?) -> String {
        if let requestedSlug {
            let trimmed = requestedSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, ClickyRoster.shared.clicky(forSlug: trimmed) != nil {
                return trimmed
            }
        }
        return ClickyRoster.shared.clickys.first?.slug ?? "clicky-general"
    }

    private static func deriveJobTitle(from prompt: String) -> String {
        let singleLine = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count <= 48 {
            return singleLine
        }
        let endIndex = singleLine.index(singleLine.startIndex, offsetBy: 45)
        return String(singleLine[..<endIndex]).trimmingCharacters(in: .whitespaces) + "..."
    }

    private func scheduleTransientHideIfNeeded() {
        guard !shouldShowPersistentOverlay && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task { [weak self] in
            guard let self else { return }
            while self.elevenLabsTTSClient.isPlaying
                || RealtimeVoiceController.shared.state == .speaking
                || self.fallbackSpeechSynthesizer.isSpeaking {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            self.syncWakeWordListenerState()

            while self.detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.overlayWindowManager.fadeOutAndHideOverlay()
            self.isOverlayVisible = false
        }
    }

    // MARK: - Provider-Aware Error Formatting & Fallback

    static func formatProviderError(_ error: Error) -> String {
        let config = ClickyConfiguration.shared
        let rawDescription = error.localizedDescription
        let lowered = rawDescription.lowercased()

        switch config.mode {
        case .openCodex:
            if let urlError = error as? URLError,
               [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut, .notConnectedToInternet].contains(urlError.code) {
                return "OpenCodex proxy is offline at \(config.openCodexBaseURL). Start OpenCodex or switch connection mode in Settings."
            }
            if !OpenCodexService.shared.isHealthy {
                return "OpenCodex appears offline at \(config.openCodexBaseURL): \(rawDescription)"
            }
            if lowered.contains("401") || lowered.contains("403") || lowered.contains("unauthorized") {
                return "OpenCodex authentication failed. Check your OpenCodex API key or OAuth login in Settings."
            }
            return "OpenCodex request failed: \(rawDescription)"

        case .byok:
            let hasAnthropic = !config.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasOpenAI = !config.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasGemini = !config.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if (!hasAnthropic && !hasOpenAI && !hasGemini)
                || lowered.contains("missing")
                || lowered.contains("api key")
                || lowered.contains("401")
                || lowered.contains("invalid_api_key") {
                return "Missing or invalid BYOK API key for \(config.selectedModel). Add your provider key in Settings."
            }
            return "Direct API (BYOK) request failed: \(rawDescription)"

        case .nativeAntigravity:
            if (error as? AntigravityOAuthError) != nil
                || !AntigravityOAuthManager.shared.isAuthenticated
                || lowered.contains("oauth")
                || lowered.contains("token")
                || lowered.contains("401") {
                return "Google Antigravity OAuth session expired or signed out. Please sign in again in Settings."
            }
            return "Google Antigravity request failed: \(rawDescription)"

        case .cloudflareWorker:
            if lowered.contains("402") || lowered.contains("429") || lowered.contains("quota") || lowered.contains("credit") {
                return "Cloudflare Worker proxy quota or rate limit reached at \(config.workerBaseURL)."
            }
            return "Worker proxy request failed (\(config.workerBaseURL)): \(rawDescription)"
        }
    }

    private func speakProviderErrorFallback(message: String) {
        let spokenSummary: String
        switch ClickyConfiguration.shared.mode {
        case .openCodex:
            spokenSummary = "OpenCodex appears offline. Check your connection settings."
        case .byok:
            spokenSummary = "Your direct API key is missing or rejected. Check Settings."
        case .nativeAntigravity:
            spokenSummary = "Your Google Antigravity sign-in expired. Please sign in again in Settings."
        case .cloudflareWorker:
            spokenSummary = "The worker proxy could not complete that request. Check Settings."
        }

        let utterance = AVSpeechUtterance(string: spokenSummary)
        let langCode = ClickyConfiguration.shared.selectedVoiceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !langCode.isEmpty && langCode.lowercased() != "auto" {
            let bcp47 = VoiceLanguageCatalog.language(forCode: langCode)?.bcp47Locale ?? langCode
            utterance.voice = AVSpeechSynthesisVoice(language: bcp47)
        }
        fallbackSpeechSynthesizer.speak(utterance)
        voiceState = .responding
        lastErrorMessage = message
    }

    // MARK: - Point Tag & Drawing Block Parsing

    struct PointingParseResult {
        let spokenText: String
        let coordinate: CGPoint?
        let elementLabel: String?
        let screenNumber: Int?
    }

    static func stripDrawingCodeBlocks(from responseText: String) -> String {
        let pattern = #"```(?:js|javascript|draw)?\s*\n[\s\S]*?(?:```|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return responseText
        }
        let range = NSRange(responseText.startIndex..., in: responseText)
        let stripped = regex.stringByReplacingMatches(in: responseText, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripDrawingCodeBlocksAndPointTags(from responseText: String) -> String {
        let withoutDrawing = stripDrawingCodeBlocks(from: responseText)
        return parsePointingCoordinates(from: withoutDrawing).spokenText
    }

    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    private static func isFrontmostApplicationFullscreen() -> Bool {
        guard AXIsProcessTrusted(),
              let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var focusedWindowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        guard status == .success, let focusedWindowRef else {
            return false
        }
        let windowElement = focusedWindowRef as! AXUIElement
        var fullScreenRef: CFTypeRef?
        let fullScreenStatus = AXUIElementCopyAttributeValue(windowElement, "AXFullScreen" as CFString, &fullScreenRef)
        if fullScreenStatus == .success, let isFullScreen = fullScreenRef as? Bool {
            return isFullScreen
        }
        return false
    }

    // MARK: - Onboarding Video

    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        player.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.onboardingVideoOpacity = 1.0
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                ClickyAnalytics.trackOnboardingDemoTriggered()
                self?.performOnboardingDemoInteraction()
            }
        }

        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                ClickyAnalytics.trackOnboardingVideoCompleted()
                self.onboardingVideoOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.tearDownOnboardingVideo()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.startOnboardingPromptStream()
                    }
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        onboardingPromptStreamTask?.cancel()
        onboardingPromptStreamTask = nil
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        onboardingPromptStreamTask?.cancel()
        onboardingPromptStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for character in message {
                guard !Task.isCancelled else { return }
                self.onboardingPromptText.append(character)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }

            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, self.showOnboardingPrompt else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.onboardingPromptOpacity = 0.0
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self.showOnboardingPrompt = false
            self.onboardingPromptText = ""
        }
    }

    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        Task { @MainActor in
            let steps = 20
            let stepNanoseconds = UInt64((duration / Double(steps)) * 1_000_000_000)
            let volumeIncrement = (targetVolume - player.volume) / Float(steps)

            for _ in 0..<steps {
                try? await Task.sleep(nanoseconds: stepNanoseconds)
                guard !Task.isCancelled else { return }
                player.volume = min(targetVolume, player.volume + volumeIncrement)
            }
            player.volume = targetVolume
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    func performOnboardingDemoInteraction() {
        guard voiceState == .idle || voiceState == .responding else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await self.unifiedLLMClient.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                self.detectedElementBubbleText = parseResult.spokenText
                self.detectedElementScreenLocation = globalLocation
                self.detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
