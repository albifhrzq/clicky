//
//  RealtimeVoiceController.swift
//  leanring-buddy
//
//  Orchestrates capability-based voice sessions:
//   - Path A (BYOK Duplex Realtime): OpenAI Realtime & Gemini Live Bidi with
//     10-minute Gemini cooldown fallback to OpenAI, plus AVAudioEngine playback
//     with runningWithoutIOCycle post-wake detection and [0.25, 0.5, 1.0]s rebuild.
//   - Path B (OpenCodex / Antigravity / Turn-Based): clean delegation hook to
//     turn-based LLM pipeline + OpenAI TTS / Gemini TTS / ElevenLabs / AVSpeechSynthesizer.
//

import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import Foundation

public enum RealtimeVoiceState: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case error(String)

    public var isActive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking:
            return true
        case .idle, .error:
            return false
        }
    }
}

public enum VoicePipelineRoute: Equatable, Sendable {
    case realtimeDuplex(RealtimeVoiceProvider)
    case turnBased
}

@MainActor
public final class RealtimeVoiceController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = RealtimeVoiceController()

    private static let geminiCooldownDurationSeconds: TimeInterval = 600 // 10 minutes
    private static let engineRebuildRetryDelays: [TimeInterval] = [0.25, 0.5, 1.0]
    private static let speechSpeedDefaultsKey = "clicky_voice_speech_speed"
    private static let defaultPlaybackSampleRate: Double = 24_000.0

    @Published public private(set) var state: RealtimeVoiceState = .idle
    @Published public private(set) var activeRoute: VoicePipelineRoute = .turnBased
    @Published public private(set) var activeProviderLabel: String = ""
    @Published public private(set) var lastUserTranscript: String = ""
    @Published public private(set) var lastAssistantTranscript: String = ""
    @Published public private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published public private(set) var isGeminiInCooldown: Bool = false
    @Published public private(set) var lastErrorMessage: String?

    @Published public var speechSpeed: Double {
        didSet {
            let clamped = min(max(speechSpeed, 0.5), 1.5)
            if clamped != speechSpeed {
                speechSpeed = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.speechSpeedDefaultsKey)
        }
    }

    /// Optional delegation hook for Path B turn-based responses (e.g. CompanionManager
    /// screenshot + vision pipeline). When nil, falls back to UnifiedLLMClient.completeText.
    public var turnBasedHandler: ((_ userText: String) async throws -> String)?
    /// Builds the session instructions at connect time (memory, skills, abilities). Set by CompanionManager.
    public var instructionsProvider: ((_ baseInstructions: String) -> String)?
    /// Starts (or offers) a background agent job for the `start_background_job` tool. Set by CompanionManager.
    /// Returns a status line for the model (started / waiting for the user's OK / not started and why).
    public var backgroundJobHandler: ((_ task: String) -> String)?

    private var realtimeToolCallsInFlight = 0
    private var realtimeToolCallGate = RealtimeToolCallGate()
    /// Bumped whenever a session starts or stops so late tool results can be dropped.
    private var realtimeSessionGeneration = 0
    private nonisolated let realtimeClient = RealtimeVoiceClient()
    private let elevenLabsTTSClient = ElevenLabsTTSClient.shared
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let unifiedLLMClient = UnifiedLLMClient()
    private let urlSession: URLSession

    private var captureEngine: AVAudioEngine?
    private let legacyMicrophoneCaptureInput = ClickyMicrophoneCaptureInput(logPrefix: "RealtimeVoiceController")
    private var isLegacyMicrophoneCaptureRunning = false
    private var captureConverter: BuddyPCM16AudioConverter?
    /// True while `playbackEngine` doubles as the capture engine with voice processing (AEC) enabled.
    private var isDuplexVoiceProcessingActive = false
    private var activeCaptureSampleRate: Double = 24000
    private var captureStartedAt = Date()
    private var lastNonSilentInputAt: Date?
    private var hasReportedDeadMicrophone = false
    private var playbackEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat
    private var audioPlayerForClip: AVAudioPlayer?

    private var geminiCooldownUntil: Date?
    private var cooldownRefreshTimer: Timer?
    private var activeRealtimeProvider: RealtimeVoiceProvider?
    private var pendingRealtimeBuffersCount = 0
    /// A route change wants a capture restart, but playback was active; apply it once playback drains.
    private var isCaptureRestartPending = false
    private var hasInjectedPreRollForCurrentTurn = false
    private var lastPlaybackActivityAt: Date = .distantPast
    private var isRebuildingPlaybackEngine = false
    private var engineRebuildTask: Task<Void, Never>?
    private var ioCycleWatchdogTask: Task<Void, Never>?
    private var activeTurnTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var configChangeObserver: NSObjectProtocol?

    private override init() {
        let savedSpeed = UserDefaults.standard.object(forKey: Self.speechSpeedDefaultsKey) as? Double ?? 1.0
        self.speechSpeed = min(max(savedSpeed, 0.5), 1.5)
        self.playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.defaultPlaybackSampleRate,
            channels: 1,
            interleaved: false
        )!

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 120
        self.urlSession = URLSession(configuration: sessionConfig)

        super.init()
        speechSynthesizer.delegate = self

        configurePlaybackEngineGraph()
        observeSystemAndAudioTopologyEvents()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    // MARK: - Public Session Controls

    public func startSession() async {
        stopSession()

        lastErrorMessage = nil
        lastUserTranscript = ""
        lastAssistantTranscript = ""

        let route = resolvePreferredRoute()
        activeRoute = route

        switch route {
        case .realtimeDuplex(let preferredProvider):
            await startDuplexRealtimeSession(preferredProvider: preferredProvider)
        case .turnBased:
            activeProviderLabel = turnBasedProviderLabel()
            state = .listening
        }
    }

    public func stopSession() {
        realtimeSessionGeneration += 1
        realtimeToolCallsInFlight = 0
        realtimeToolCallGate.resetAll()
        activeTurnTask?.cancel()
        activeTurnTask = nil
        ioCycleWatchdogTask?.cancel()
        ioCycleWatchdogTask = nil
        engineRebuildTask?.cancel()
        engineRebuildTask = nil

        stopMicCapture()
        stopAudioPlayback()
        realtimeClient.disconnect()
        activeRealtimeProvider = nil
        currentAudioPowerLevel = 0
        state = .idle
    }

    public func sendTextTurn(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        lastUserTranscript = trimmedText
        lastErrorMessage = nil

        if case .realtimeDuplex = activeRoute,
           activeRealtimeProvider != nil,
           state.isActive {
            state = .thinking
            lastAssistantTranscript = ""
            hasInjectedPreRollForCurrentTurn = false
            realtimeClient.sendTextTurn(trimmedText)
            return
        }

        // Check if we can start a duplex session or should use Path B turn-based
        let route = resolvePreferredRoute()
        activeRoute = route

        if case .realtimeDuplex(let provider) = route {
            let started = await connectRealtimeProvider(provider)
            if started {
                state = .thinking
                lastAssistantTranscript = ""
                hasInjectedPreRollForCurrentTurn = false
                realtimeClient.sendTextTurn(trimmedText)
                return
            }
        }

        // Path B: Turn-based fallback
        await executeTurnBasedPipeline(userText: trimmedText)
    }

    public func interruptAssistantSpeech() {
        stopAudioPlayback()
        if activeRealtimeProvider != nil {
            realtimeClient.interruptResponse()
            state = .listening
        } else {
            activeTurnTask?.cancel()
            activeTurnTask = nil
            state = .idle
        }
    }

    // MARK: - Capability Routing & 10-Minute Cooldown

    public func resolvePreferredRoute() -> VoicePipelineRoute {
        refreshGeminiCooldownState()
        let config = ClickyConfiguration.shared

        if config.voicePipelineMode == .turnBased {
            return .turnBased
        }

        let allowsRealtime = config.mode == .byok || config.voicePipelineMode == .realtimeDuplex
        guard allowsRealtime else {
            return .turnBased
        }

        let hasOpenAIKey = !config.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasGeminiKey = !config.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGeminiInCooldown

        let selectedVoice = VoiceLanguageCatalog.voice(forID: config.selectedVoiceID)
        let prefersGeminiVoice = selectedVoice?.provider == .gemini

        if prefersGeminiVoice {
            if hasGeminiKey {
                return .realtimeDuplex(.gemini)
            }
            if hasOpenAIKey {
                return .realtimeDuplex(.openAI)
            }
        } else {
            if hasOpenAIKey {
                return .realtimeDuplex(.openAI)
            }
            if hasGeminiKey {
                return .realtimeDuplex(.gemini)
            }
        }

        return .turnBased
    }

    private func markGeminiCooldown() {
        geminiCooldownUntil = Date().addingTimeInterval(Self.geminiCooldownDurationSeconds)
        isGeminiInCooldown = true
        cooldownRefreshTimer?.invalidate()
        cooldownRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshGeminiCooldownState()
            }
        }
    }

    private func refreshGeminiCooldownState() {
        guard let cooldownUntil = geminiCooldownUntil else {
            if isGeminiInCooldown {
                isGeminiInCooldown = false
            }
            return
        }
        if Date() >= cooldownUntil {
            geminiCooldownUntil = nil
            isGeminiInCooldown = false
            cooldownRefreshTimer?.invalidate()
            cooldownRefreshTimer = nil
        } else {
            isGeminiInCooldown = true
        }
    }

    // MARK: - Path A: Duplex Realtime

    private func startDuplexRealtimeSession(preferredProvider: RealtimeVoiceProvider) async {
        guard await ensureMicrophonePermission() else {
            let message = ClickyVoiceMessages.microphoneAccessIsOff
            lastErrorMessage = message
            state = .error(message)
            return
        }

        state = .connecting

        if await connectRealtimeProvider(preferredProvider) {
            do {
                try startMicCapture(sampleRate: realtimeClient.inputSampleRate)
                state = .listening
            } catch {
                print("⚠️ Realtime mic capture failed: \(error.localizedDescription)")
                let message = ClickyVoiceMessages.microphoneCaptureFailed
                lastErrorMessage = message
                state = .error(message)
            }
            return
        }

        // If Gemini failed, apply 10-minute cooldown and fail over to OpenAI if available
        if preferredProvider == .gemini {
            markGeminiCooldown()
            let openAIKey = ClickyConfiguration.shared.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !openAIKey.isEmpty, await connectRealtimeProvider(.openAI) {
                do {
                    try startMicCapture(sampleRate: realtimeClient.inputSampleRate)
                    state = .listening
                    return
                } catch {
                    print("⚠️ Realtime mic capture failed: \(error.localizedDescription)")
                let message = ClickyVoiceMessages.microphoneCaptureFailed
                    lastErrorMessage = message
                    state = .error(message)
                    return
                }
            }
        }

        // Fall back cleanly to Path B turn-based mode if duplex could not connect
        activeRoute = .turnBased
        activeProviderLabel = turnBasedProviderLabel()
        state = .listening
    }

    private func connectRealtimeProvider(_ provider: RealtimeVoiceProvider) async -> Bool {
        let config = ClickyConfiguration.shared
        let apiKey: String = switch provider {
        case .openAI:
            config.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .gemini:
            config.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !apiKey.isEmpty else { return false }

        let sessionConfig = RealtimeVoiceSessionConfiguration(
            provider: provider,
            apiKey: apiKey,
            voiceID: config.selectedVoiceID,
            languageCode: config.selectedVoiceLanguage,
            instructions: realtimeInstructionsForConnect(),
            speechSpeed: speechSpeed
        )

        do {
            try await realtimeClient.connect(configuration: sessionConfig) { [weak self] event in
                self?.handleRealtimeEvent(event)
            }
            activeRealtimeProvider = provider
            activeRoute = .realtimeDuplex(provider)
            activeProviderLabel = provider.displayName
            return true
        } catch {
            if provider == .gemini {
                markGeminiCooldown()
            }
            print("⚠️ Realtime connect failed (\(provider.displayName)): \(error.localizedDescription)")
            lastErrorMessage = ClickyVoiceErrorMapper.message(
                for: error,
                providerName: provider.displayName,
                isPushToTalk: false,
                fallback: ClickyVoiceMessages.myVoiceConnectionDidntOpen
            )
            return false
        }
    }

    private func handleRealtimeEvent(_ event: RealtimeVoiceClientEvent) {
        switch event {
        case .connected(let provider):
            activeRealtimeProvider = provider
            activeProviderLabel = provider.displayName
            if state == .connecting {
                state = .listening
            }

        case .inputAudioSpeechStarted:
            stopAudioPlayback()
            hasInjectedPreRollForCurrentTurn = false
            state = .listening

        case .inputAudioSpeechStopped:
            if state == .listening {
                state = .thinking
            }

        case .userTranscriptDelta(let delta):
            lastUserTranscript += delta

        case .userTranscriptCompleted(let transcript):
            lastUserTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            realtimeToolCallGate.resetForNewUtterance()

        case .assistantResponseStarted:
            lastAssistantTranscript = ""
            hasInjectedPreRollForCurrentTurn = false
            if state != .speaking {
                state = .thinking
            }

        case .assistantAudioDelta(let pcmData, let sampleRate):
            state = .speaking
            enqueueRealtimePCM16Audio(pcmData, sampleRate: Double(sampleRate))

        case .assistantTranscriptDelta(let delta):
            lastAssistantTranscript += delta

        case .assistantTranscriptCompleted(let transcript):
            lastAssistantTranscript = transcript

        case .assistantResponseCompleted:
            if realtimeToolCallsInFlight > 0 { break }
            if pendingRealtimeBuffersCount <= 0 && !playerNode.isPlaying {
                if isMicrophoneCaptureActive {
                    state = .listening
                } else {
                    state = .idle
                }
                applyPendingCaptureRestartIfIdle()
            }

        case .toolCallRequested(let toolCall):
            runRealtimeToolCall(toolCall)

        case .error(let message):
            print("⚠️ Realtime error: \(message)")
            lastErrorMessage = ClickyVoiceMessages.connectionDroppedMidResponse
            if activeRealtimeProvider == .gemini {
                handleMidSessionGeminiFailure(message: message)
            } else {
                state = .error(ClickyVoiceMessages.connectionDroppedMidResponse)
            }

        case .disconnected(let reason):
            if activeRealtimeProvider != nil {
                activeRealtimeProvider = nil
                stopMicCapture()
                if state.isActive {
                    state = .idle
                }
                if let reason, !reason.isEmpty, lastErrorMessage == nil {
                    lastErrorMessage = reason
                }
            }
        }
    }

    private func realtimeInstructionsForConnect() -> String {
        let languageCode = ClickyConfiguration.shared.selectedVoiceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = Self.realtimeSystemInstructions
        if !languageCode.isEmpty, languageCode.lowercased() != "auto" {
            let languageName = VoiceLanguageCatalog.language(forCode: languageCode)?.name ?? languageCode
            base += "\n\nLanguage preference: Always respond naturally in \(languageName) (\(languageCode))."
        }
        return instructionsProvider?(base) ?? base
    }

    /// Runs the tool off the event path (mic audio keeps flowing), then returns the result to the model.
    private func runRealtimeToolCall(_ toolCall: RealtimeToolCall) {
        if let busyOutput = realtimeToolCallGate.admit(toolName: toolCall.name) {
            realtimeClient.sendToolResult(toolCall, output: busyOutput)
            return
        }
        realtimeToolCallsInFlight += 1
        state = .thinking
        let sessionGenerationAtStart = realtimeSessionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            var output: String
            do {
                switch toolCall.name {
                case RealtimeToolSupport.useScreenToolName:
                    let request = toolCall.arguments["request"] ?? self.lastUserTranscript
                    guard let handler = self.turnBasedHandler else {
                        throw RealtimeToolError.handlerUnavailable
                    }
                    output = try await handler(request)
                case RealtimeToolSupport.startBackgroundJobToolName:
                    guard let handler = self.backgroundJobHandler else {
                        throw RealtimeToolError.handlerUnavailable
                    }
                    output = handler(toolCall.arguments["task"] ?? self.lastUserTranscript)
                default:
                    output = "Error: unknown tool \(toolCall.name)."
                }
            } catch {
                output = "Error: \(error.localizedDescription). Apologize briefly and tell the user it didn't work."
            }
            // Session ended or was replaced while the tool ran: drop the result, leave state alone.
            guard self.realtimeSessionGeneration == sessionGenerationAtStart else { return }
            self.realtimeToolCallsInFlight = max(0, self.realtimeToolCallsInFlight - 1)
            self.realtimeToolCallGate.finishToolCall()
            guard self.activeRealtimeProvider != nil else {
                self.state = self.isMicrophoneCaptureActive ? .listening : .idle
                return
            }
            // The model answers next; assistantResponseStarted/Completed drive the state from here.
            self.realtimeClient.sendToolResult(toolCall, output: output)
        }
    }

    private enum RealtimeToolError: LocalizedError {
        case handlerUnavailable
        var errorDescription: String? { "That ability isn't available right now" }
    }

    private func handleMidSessionGeminiFailure(message: String) {
        markGeminiCooldown()
        realtimeClient.disconnect()
        activeRealtimeProvider = nil

        let openAIKey = ClickyConfiguration.shared.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !openAIKey.isEmpty else {
            activeRoute = .turnBased
            activeProviderLabel = turnBasedProviderLabel()
            print("⚠️ Gemini Live unavailable (\(message)). Switched to turn-based mode.")
            lastErrorMessage = ClickyVoiceMessages.myVoiceConnectionDidntOpen
            state = .idle
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .connecting
            if await self.connectRealtimeProvider(.openAI) {
                self.captureConverter = BuddyPCM16AudioConverter(targetSampleRate: self.realtimeClient.inputSampleRate)
                self.state = .listening
            } else {
                self.activeRoute = .turnBased
                self.activeProviderLabel = self.turnBasedProviderLabel()
                self.state = .error(ClickyVoiceMessages.connectionDroppedMidResponse)
            }
        }
    }

    // MARK: - Path B: Turn-Based Pipeline & TTS Cascade

    private func executeTurnBasedPipeline(userText: String) async {
        activeTurnTask?.cancel()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .thinking
            self.lastAssistantTranscript = ""

            do {
                let responseText: String
                if let customHandler = self.turnBasedHandler {
                    responseText = try await customHandler(userText)
                } else {
                    responseText = try await self.unifiedLLMClient.completeText(
                        systemPrompt: Self.turnBasedSystemInstructions(languageCode: ClickyConfiguration.shared.selectedVoiceLanguage),
                        userPrompt: userText
                    )
                }

                try Task.checkCancellation()

                let trimmedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.lastAssistantTranscript = trimmedResponse

                guard !trimmedResponse.isEmpty else {
                    self.state = .idle
                    return
                }

                self.state = .speaking
                await self.speakTurnBasedResponse(trimmedResponse)

                if !Task.isCancelled && !self.speechSynthesizer.isSpeaking {
                    self.state = .idle
                }
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.lastErrorMessage = error.localizedDescription
                self.state = .error(error.localizedDescription)
            }
        }

        activeTurnTask = task
        await task.value
    }

    public func speakTurnBasedResponse(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let config = ClickyConfiguration.shared

        // 1. ElevenLabs TTS (BYOK or Worker Proxy) — highest priority when configured
        let hasElevenLabsKey = !config.elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasElevenLabsKey || config.mode == .cloudflareWorker {
            do {
                try await elevenLabsTTSClient.speakText(trimmedText)
                while elevenLabsTTSClient.isPlaying {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                return
            } catch {
                print("⚠️ ElevenLabs TTS failed, cascading: \(error.localizedDescription)")
            }
        }

        // 2. OpenAI TTS (/v1/audio/speech)
        let openAIKey = config.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !openAIKey.isEmpty {
            do {
                let audioData = try await fetchOpenAITTSAudio(
                    text: trimmedText,
                    apiKey: openAIKey,
                    voice: VoiceLanguageCatalog.openAIVoiceName(forSelectedID: config.selectedVoiceID),
                    speed: speechSpeed
                )
                try await playEncodedAudioData(audioData)
                return
            } catch {
                print("⚠️ OpenAI TTS failed, cascading: \(error.localizedDescription)")
            }
        }

        // 3. Gemini TTS
        refreshGeminiCooldownState()
        let geminiKey = config.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !geminiKey.isEmpty && !isGeminiInCooldown {
            do {
                let wavData = try await fetchGeminiTTSAudio(
                    text: trimmedText,
                    apiKey: geminiKey,
                    voice: VoiceLanguageCatalog.geminiVoiceName(forSelectedID: config.selectedVoiceID)
                )
                try await playEncodedAudioData(wavData)
                return
            } catch {
                print("⚠️ Gemini TTS failed, cascading: \(error.localizedDescription)")
            }
        }

        // 4. Offline AVSpeechSynthesizer fallback
        speakWithSystemSynthesizer(
            text: trimmedText,
            languageCode: config.selectedVoiceLanguage,
            speed: speechSpeed
        )
    }

    private func fetchOpenAITTSAudio(
        text: String,
        apiKey: String,
        voice: String,
        speed: Double
    ) async throws -> Data {
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": text,
            "voice": voice,
            "speed": speed,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "ClickyOpenAITTS",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI TTS HTTP \(statusCode)"]
            )
        }
        return data
    }

    private func fetchGeminiTTSAudio(
        text: String,
        apiKey: String,
        voice: String
    ) async throws -> Data {
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-tts:generateContent"
        )
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": text]]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": voice
                        ]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "ClickyGeminiTTS",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Gemini TTS HTTP \(statusCode)"]
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw NSError(
                domain: "ClickyGeminiTTS",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini TTS payload"]
            )
        }

        for part in parts {
            if let inlineData = part["inlineData"] as? [String: Any],
               let base64Audio = inlineData["data"] as? String,
               let rawAudioData = Data(base64Encoded: base64Audio) {
                let mimeType = (inlineData["mimeType"] as? String ?? "").lowercased()
                if mimeType.contains("wav") || mimeType.contains("mp3") || mimeType.contains("mpeg") {
                    return rawAudioData
                }
                // Raw L16 PCM -> wrap in WAV container for AVAudioPlayer
                return BuddyWAVFileBuilder.buildWAVData(
                    fromPCM16MonoAudio: rawAudioData,
                    sampleRate: 24_000
                )
            }
        }

        throw NSError(
            domain: "ClickyGeminiTTS",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No audio data returned by Gemini TTS"]
        )
    }

    private func playEncodedAudioData(_ data: Data) async throws {
        let topologySnapshot = ClickyAudioTopologyMonitor.shared.snapshot
        let preRoll = topologySnapshot.requiredPreRollSilenceDuration
        if Date().timeIntervalSince(lastPlaybackActivityAt) > 2.0 {
            try? await Task.sleep(nanoseconds: UInt64(preRoll * 1_000_000_000))
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        player.enableRate = true
        player.rate = Float(speechSpeed)
        player.prepareToPlay()
        audioPlayerForClip = player
        player.play()
        lastPlaybackActivityAt = Date()

        while player.isPlaying {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        lastPlaybackActivityAt = Date()
        if audioPlayerForClip === player {
            audioPlayerForClip = nil
        }
    }

    private func speakWithSystemSynthesizer(
        text: String,
        languageCode: String,
        speed: Double
    ) {
        speechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)

        let normalizedLang = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedLang.isEmpty && normalizedLang.lowercased() != "auto" {
            let bcp47 = VoiceLanguageCatalog.language(forCode: normalizedLang)?.bcp47Locale ?? normalizedLang
            utterance.voice = AVSpeechSynthesisVoice(language: bcp47)
        }

        // Map 0.5x..1.5x onto AVSpeechUtterance rate range around AVSpeechUtteranceDefaultSpeechRate
        let baseRate = Double(AVSpeechUtteranceDefaultSpeechRate)
        let scaledRate = Float(min(max(baseRate * speed, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
        utterance.rate = scaledRate
        state = .speaking
        speechSynthesizer.speak(utterance)
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.state == .speaking {
                self.state = .idle
            }
        }
    }

    // MARK: - AVAudioEngine Playback & runningWithoutIOCycle Recovery

    private func configurePlaybackEngineGraph() {
        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.prepare()
    }

    private func ensurePlaybackEngineRunning() {
        if playbackEngine.isRunning {
            scheduleIOCycleWatchdogIfNeeded()
            return
        }

        do {
            playbackEngine.prepare()
            try playbackEngine.start()
            if !playerNode.isPlaying {
                playerNode.play()
            }
            scheduleIOCycleWatchdogIfNeeded()
        } catch {
            print("⚠️ AVAudioEngine start failed, scheduling rebuild: \(error.localizedDescription)")
            triggerPlaybackEngineRebuildWithRetries()
        }
    }

    private func enqueueRealtimePCM16Audio(_ pcm16Data: Data, sampleRate: Double) {
        guard !pcm16Data.isEmpty else { return }
        ensurePlaybackEngineRunning()

        // Inject pre-roll silence on the first chunk of a cold BT/wired playback turn
        if !hasInjectedPreRollForCurrentTurn {
            hasInjectedPreRollForCurrentTurn = true
            if ClickyMicrophoneHealth.isDefaultOutputMuted() {
                lastErrorMessage = ClickyMicrophoneProblem.outputMuted.userFacingMessage
            }
            let isCold = Date().timeIntervalSince(lastPlaybackActivityAt) > 2.0
            if isCold {
                let preRollSeconds = ClickyAudioTopologyMonitor.shared.snapshot.requiredPreRollSilenceDuration
                let silenceFrameCount = AVAudioFrameCount((playbackFormat.sampleRate * preRollSeconds).rounded())
                if let silenceBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: silenceFrameCount) {
                    silenceBuffer.frameLength = silenceFrameCount
                    if let channel = silenceBuffer.floatChannelData?[0] {
                        memset(channel, 0, Int(silenceFrameCount) * MemoryLayout<Float>.size)
                    }
                    pendingRealtimeBuffersCount += 1
                    playerNode.scheduleBuffer(silenceBuffer) { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.handleScheduledBufferCompleted()
                        }
                    }
                }
            }
        }

        guard let floatBuffer = makeFloatBuffer(fromPCM16Data: pcm16Data, sourceSampleRate: sampleRate) else {
            return
        }

        pendingRealtimeBuffersCount += 1
        lastPlaybackActivityAt = Date()
        if !playerNode.isPlaying {
            playerNode.play()
        }

        playerNode.scheduleBuffer(floatBuffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleScheduledBufferCompleted()
            }
        }

        scheduleIOCycleWatchdogIfNeeded()
    }

    private func handleScheduledBufferCompleted() {
        pendingRealtimeBuffersCount = max(0, pendingRealtimeBuffersCount - 1)
        lastPlaybackActivityAt = Date()
        if pendingRealtimeBuffersCount == 0 && state == .speaking {
            if isMicrophoneCaptureActive {
                state = .listening
            } else {
                state = .idle
            }
            applyPendingCaptureRestartIfIdle()
        }
    }

    private func makeFloatBuffer(fromPCM16Data pcm16Data: Data, sourceSampleRate: Double) -> AVAudioPCMBuffer? {
        let sampleCount = pcm16Data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ),
        let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else {
            return nil
        }

        sourceBuffer.frameLength = AVAudioFrameCount(sampleCount)
        if let floatChannel = sourceBuffer.floatChannelData?[0] {
            pcm16Data.withUnsafeBytes { rawBuffer in
                guard let int16Pointer = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
                let scale: Float = 1.0 / 32768.0
                for index in 0..<sampleCount {
                    let littleEndianSample = Int16(littleEndian: int16Pointer[index])
                    floatChannel[index] = Float(littleEndianSample) * scale
                }
            }
        }

        if abs(sourceSampleRate - playbackFormat.sampleRate) < 1.0 {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: playbackFormat) else {
            return sourceBuffer
        }

        let ratio = playbackFormat.sampleRate / sourceSampleRate
        let outputCapacity = AVAudioFrameCount((Double(sampleCount) * ratio).rounded(.up) + 16)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        var didSupplyInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didSupplyInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didSupplyInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        return status == .error ? nil : outputBuffer
    }

    private func stopAudioPlayback() {
        playerNode.stop()
        pendingRealtimeBuffersCount = 0
        audioPlayerForClip?.stop()
        audioPlayerForClip = nil
        elevenLabsTTSClient.stopPlayback()
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func observeSystemAndAudioTopologyEvents() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePostWakeAudioCheck()
            }
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let changedEngine = notification.object as? AVAudioEngine,
                   changedEngine === self.playbackEngine {
                    self.triggerPlaybackEngineRebuildWithRetries()
                }
            }
        }

        ClickyAudioTopologyMonitor.shared.topologyChangedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handlePostWakeAudioCheck()
                self?.restartCaptureIfVoiceProcessingSuitabilityChanged()
            }
            .store(in: &cancellables)
    }

    private func handlePostWakeAudioCheck() {
        guard playbackEngine.isRunning || state == .speaking || pendingRealtimeBuffersCount > 0 else {
            return
        }
        scheduleIOCycleWatchdogIfNeeded(forceImmediateCheck: true)
    }

    private func scheduleIOCycleWatchdogIfNeeded(forceImmediateCheck: Bool = false) {
        guard playbackEngine.isRunning else { return }
        if !forceImmediateCheck && ioCycleWatchdogTask != nil { return }

        ioCycleWatchdogTask?.cancel()
        ioCycleWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.ioCycleWatchdogTask = nil }

            let initialRenderTime = self.playbackEngine.outputNode.lastRenderTime
            let initialSampleTime = initialRenderTime?.sampleTime ?? 0

            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            guard self.playbackEngine.isRunning else { return }

            let updatedRenderTime = self.playbackEngine.outputNode.lastRenderTime
            let updatedSampleTime = updatedRenderTime?.sampleTime ?? 0
            let isRenderTimeValid = updatedRenderTime?.isSampleTimeValid ?? false
            let hasAdvanced = isRenderTimeValid && (updatedSampleTime > initialSampleTime)
            let isDeviceRunningSomewhere = Self.isDefaultOutputDeviceRunningSomewhere()

            // runningWithoutIOCycle: AVAudioEngine reports isRunning == true,
            // yet render sample time is stalled/invalid or CoreAudio HAL reports no IO cycle.
            let hasActiveAudioWork = self.playerNode.isPlaying || self.pendingRealtimeBuffersCount > 0
            if (hasActiveAudioWork && !hasAdvanced) || !isDeviceRunningSomewhere {
                print("⚠️ Detected AVAudioEngine runningWithoutIOCycle; rebuilding audio engine")
                self.triggerPlaybackEngineRebuildWithRetries()
            }
        }
    }

    private func triggerPlaybackEngineRebuildWithRetries() {
        guard !isRebuildingPlaybackEngine else { return }
        isRebuildingPlaybackEngine = true

        engineRebuildTask?.cancel()
        engineRebuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isRebuildingPlaybackEngine = false
                self.engineRebuildTask = nil
            }

            for (attemptIndex, delaySeconds) in Self.engineRebuildRetryDelays.enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }

                let rebuilt = self.rebuildPlaybackEngineOnce()
                if rebuilt {
                    print("✅ Rebuilt AVAudioEngine successfully on retry #\(attemptIndex + 1) (\(delaySeconds)s)")
                    return
                }
            }

            print("❌ Failed to rebuild AVAudioEngine after \(Self.engineRebuildRetryDelays.count) retries")
        }
    }

    @discardableResult
    private func rebuildPlaybackEngineOnce() -> Bool {
        // Duplex mode owns the capture tap too, so redo the whole graph (voice processing + tap).
        if isDuplexVoiceProcessingActive {
            do {
                try startDuplexVoiceProcessingCapture(sampleRate: activeCaptureSampleRate)
                pendingRealtimeBuffersCount = 0
                return playbackEngine.isRunning
            } catch {
                print("⚠️ Duplex rebuild failed, falling back to two engines: \(error.localizedDescription)")
                isDuplexVoiceProcessingActive = false
                // Tear down the old duplex engine (tap + engine) and give playback a fresh engine,
                // otherwise the stale graph keeps the mic and the old player attached.
                captureEngine?.inputNode.removeTap(onBus: 0)
                captureEngine?.stop()
                legacyMicrophoneCaptureInput.stop()
                isLegacyMicrophoneCaptureRunning = false
                playerNode.stop()
                playbackEngine.stop()
                captureEngine = nil
                playbackEngine = AVAudioEngine()
                playerNode = AVAudioPlayerNode()
                configurePlaybackEngineGraph()
                try? startLegacyMicCapture(sampleRate: activeCaptureSampleRate)
                return false
            }
        }

        playerNode.stop()
        playbackEngine.stop()
        playbackEngine.reset()

        let freshEngine = AVAudioEngine()
        let freshPlayer = AVAudioPlayerNode()
        freshEngine.attach(freshPlayer)
        freshEngine.connect(freshPlayer, to: freshEngine.mainMixerNode, format: playbackFormat)
        freshEngine.prepare()

        do {
            try freshEngine.start()
            freshPlayer.play()
            playbackEngine = freshEngine
            playerNode = freshPlayer
            pendingRealtimeBuffersCount = 0
            return freshEngine.isRunning
        } catch {
            return false
        }
    }

    private nonisolated static func isDefaultOutputDeviceRunningSomewhere() -> Bool {
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            0,
            nil,
            &deviceSize,
            &deviceID
        )
        guard deviceStatus == noErr, deviceID != kAudioObjectUnknown else {
            return true
        }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &runningAddress) else {
            return true
        }

        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        let runningStatus = AudioObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0,
            nil,
            &runningSize,
            &isRunning
        )
        guard runningStatus == noErr else { return true }
        return isRunning != 0
    }

    // MARK: - Mic Capture (Path A)

    private func startMicCapture(sampleRate: Double) throws {
        stopMicCapture()
        activeCaptureSampleRate = sampleRate
        captureStartedAt = Date()
        lastNonSilentInputAt = nil
        hasReportedDeadMicrophone = false

        if isVoiceProcessingSuitableForCurrentRoute() {
            do {
                try startDuplexVoiceProcessingCapture(sampleRate: sampleRate)
                return
            } catch {
                // Fall back to the original two-engine behaviour.
                print("⚠️ Voice processing unavailable, using two engines: \(error.localizedDescription)")
                isDuplexVoiceProcessingActive = false
                playbackEngine.stop()
                playbackEngine = AVAudioEngine()
                playerNode = AVAudioPlayerNode()
                configurePlaybackEngineGraph()
            }
        }
        try startLegacyMicCapture(sampleRate: sampleRate)
    }

    private func isVoiceProcessingSuitableForCurrentRoute() -> Bool {
        let snapshot = ClickyAudioTopologyMonitor.shared.snapshot
        return ClickyAudioRoutePolicy.shouldUseVoiceProcessing(
            outputIsBluetooth: snapshot.outputIsBluetooth,
            outputIsHeadphones: snapshot.outputIsHeadphones
        )
    }

    private func restartCaptureIfVoiceProcessingSuitabilityChanged() {
        guard isMicrophoneCaptureActive else { return }
        guard isVoiceProcessingSuitableForCurrentRoute() != isDuplexVoiceProcessingActive else {
            isCaptureRestartPending = false
            return
        }
        // Restarting rebuilds the playback engine, which would cut off speech: wait for the next idle point.
        guard state != .speaking, pendingRealtimeBuffersCount <= 0 else {
            isCaptureRestartPending = true
            return
        }
        isCaptureRestartPending = false
        do {
            try startMicCapture(sampleRate: activeCaptureSampleRate)
        } catch {
            print("⚠️ Realtime mic restart failed: \(error.localizedDescription)")
            let message = ClickyVoiceMessages.microphoneCaptureFailed
            lastErrorMessage = message
            state = .error(message)
        }
    }

    /// Runs a capture restart that was postponed while the assistant was speaking.
    private func applyPendingCaptureRestartIfIdle() {
        guard isCaptureRestartPending else { return }
        restartCaptureIfVoiceProcessingSuitabilityChanged()
    }

    /// One engine for both capture and playback with voice processing (echo cancellation) on.
    /// The input format MUST be read after enabling voice processing: it changes the node's format.
    private func startDuplexVoiceProcessingCapture(sampleRate: Double) throws {
        playerNode.stop()
        playbackEngine.stop()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let inputNode = engine.inputNode
        try inputNode.setVoiceProcessingEnabled(true)
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "ClickyVoice", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid voice processing input format"])
        }

        let converter = BuddyPCM16AudioConverter(targetSampleRate: sampleRate)
        captureConverter = converter
        installCaptureTap(on: inputNode, format: inputFormat, converter: converter, sampleRate: sampleRate)

        engine.prepare()
        try engine.start()
        player.play()

        playbackEngine = engine
        playerNode = player
        captureEngine = engine
        isDuplexVoiceProcessingActive = true
    }

    /// Original behaviour: a dedicated capture engine alongside the playback engine.
    private func startLegacyMicCapture(sampleRate: Double) throws {
        let converter = BuddyPCM16AudioConverter(targetSampleRate: sampleRate)
        self.captureConverter = converter
        try legacyMicrophoneCaptureInput.start(
            onAudioBuffer: Self.makeLegacyCaptureHandler(
                controller: self,
                converter: converter,
                client: realtimeClient,
                sampleRate: sampleRate
            )
        )
        isLegacyMicrophoneCaptureRunning = true
    }

    /// Built nonisolated so the closure is not MainActor-isolated when the capture queue invokes it.
    private nonisolated static func makeLegacyCaptureHandler(
        controller: RealtimeVoiceController,
        converter: BuddyPCM16AudioConverter,
        client: RealtimeVoiceClient,
        sampleRate: Double
    ) -> @Sendable (AVAudioPCMBuffer) -> Void {
        return { [weak controller] buffer in
            controller?.updatePowerLevel(from: buffer)
            if let pcmData = converter.convertToPCM16Data(from: buffer), !pcmData.isEmpty {
                client.sendInputAudioPCM16(pcmData, sampleRate: Int(sampleRate))
            }
        }
    }

    private func installCaptureTap(
        on inputNode: AVAudioInputNode,
        format inputFormat: AVAudioFormat,
        converter: BuddyPCM16AudioConverter,
        sampleRate: Double
    ) {
        let client = self.realtimeClient
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.updatePowerLevel(from: buffer)
            if let pcmData = converter.convertToPCM16Data(from: buffer), !pcmData.isEmpty {
                client.sendInputAudioPCM16(pcmData, sampleRate: Int(sampleRate))
            }
        }
    }

    /// True while either the duplex voice-processing engine or the AVCaptureSession mic is running.
    private var isMicrophoneCaptureActive: Bool {
        isLegacyMicrophoneCaptureRunning || captureEngine?.isRunning == true
    }

    private func stopMicCapture() {
        legacyMicrophoneCaptureInput.stop()
        isLegacyMicrophoneCaptureRunning = false
        captureEngine?.inputNode.removeTap(onBus: 0)
        if isDuplexVoiceProcessingActive {
            // The duplex engine also plays audio; give playback a clean non-voice-processing engine again.
            isDuplexVoiceProcessingActive = false
            playerNode.stop()
            captureEngine?.stop()
            playbackEngine = AVAudioEngine()
            playerNode = AVAudioPlayerNode()
            configurePlaybackEngineGraph()
        } else {
            captureEngine?.stop()
        }
        captureEngine = nil
        captureConverter = nil
        currentAudioPowerLevel = 0
    }

    /// Reports a dead mic (exact digital silence for several seconds).
    private func evaluateCaptureHealth(rms: Float) {
        guard isMicrophoneCaptureActive else { return }
        let now = Date()
        if rms > 0 { lastNonSilentInputAt = now }
        guard !hasReportedDeadMicrophone,
              ClickyMicrophoneHealth.isInputDead(
                captureStartedAt: captureStartedAt,
                lastNonSilentInputAt: lastNonSilentInputAt,
                now: now
              ) else { return }
        hasReportedDeadMicrophone = true
        lastErrorMessage = ClickyMicrophoneProblem.deadDevice(
            name: ClickyAudioTopologyMonitor.shared.snapshot.inputDeviceName
        ).userFacingMessage
    }

    private nonisolated func updatePowerLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sumSquares: Float = 0
        for index in 0..<frameCount {
            let sample = channelData[index]
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameCount))
        let level = CGFloat(min(max(rms * 10.0, 0), 1))

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentAudioPowerLevel = max(level, self.currentAudioPowerLevel * 0.72)
            self.evaluateCaptureHealth(rms: rms)
        }
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func turnBasedProviderLabel() -> String {
        switch ClickyConfiguration.shared.mode {
        case .openCodex:
            return "OpenCodex (Turn-Based)"
        case .nativeAntigravity:
            return "Antigravity (Turn-Based)"
        case .cloudflareWorker:
            return "Cloudflare Worker (Turn-Based)"
        case .byok:
            return "Turn-Based"
        }
    }

    private static let realtimeSystemInstructions = """
    You are Clicky, a warm, direct macOS voice companion. Keep spoken answers concise and natural for the ear (1-3 short sentences unless asked to explain deeply). Avoid markdown, bullet points, or emojis.

    You can see the user's screen, point at things and draw on it ONLY by calling the use_screen tool. Never describe the screen, point or draw without calling it. Never say tags or code aloud. When a tool returns, say its result to the user in your own words, briefly. For long-running work call start_background_job.
    """

    private static func turnBasedSystemInstructions(languageCode: String) -> String {
        let base = realtimeSystemInstructions
        let trimmedLang = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLang.isEmpty, trimmedLang.lowercased() != "auto" else {
            return base
        }
        let languageName = VoiceLanguageCatalog.language(forCode: trimmedLang)?.name ?? trimmedLang
        return "\(base) Always respond naturally in \(languageName) (\(trimmedLang))."
    }
}
