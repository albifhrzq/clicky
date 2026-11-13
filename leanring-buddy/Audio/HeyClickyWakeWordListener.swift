//
//  HeyClickyWakeWordListener.swift
//  leanring-buddy
//
//  Always-listening local wake-word detector powered by AVAudioEngine and
//  Apple SFSpeechRecognizer. Supports custom wake phrases (e.g. "hey nora",
//  "hey clicky", or comma-separated aliases) with automatic task recycling,
//  mic conflict pausing, and trailing-command extraction.
//

import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class HeyClickyWakeWordListener: NSObject, ObservableObject {
    static let shared = HeyClickyWakeWordListener()

    enum Status: Equatable, Sendable {
        case stopped
        case requestingPermission
        case listening(phrase: String)
        case paused(reason: String)
        case triggered(phrase: String)
        case error(String)

        var displayLabel: String {
            switch self {
            case .stopped:
                return "Off"
            case .requestingPermission:
                return "Requesting mic & speech permissions…"
            case .listening(let phrase):
                return "Listening for \"\(phrase)\""
            case .paused(let reason):
                return "Paused (\(reason))"
            case .triggered(let phrase):
                return "Triggered \"\(phrase)\""
            case .error(let message):
                return message
            }
        }
    }

    private static let taskRecycleIntervalSeconds: TimeInterval = 45
    private static let postTriggerCooldownSeconds: TimeInterval = 2.0

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastHeardSnippet: String = ""
    @Published private(set) var lastTriggeredAt: Date?

    /// Invoked on MainActor after releasing the microphone when the custom wake phrase is detected.
    var onWakeDetected: ((_ trailingText: String) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let tapRequestLock = NSLock()
    nonisolated(unsafe) private var tapRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recycleTimer: Timer?
    private var activeGenerationID = UUID()
    private var lastTriggerDate: Date = .distantPast
    private var currentPhraseSetting: String = "hey clicky"
    private var isStarting = false

    private override init() {
        super.init()
    }

    func sync(
        enabled: Bool,
        phraseSetting: String,
        pauseReason: String?
    ) {
        let trimmedPhrase = Self.primaryDisplayPhrase(from: phraseSetting)
        let phraseChanged = Self.normalizeText(phraseSetting) != Self.normalizeText(currentPhraseSetting)
        currentPhraseSetting = trimmedPhrase

        guard enabled else {
            if status != .stopped {
                stop()
            }
            return
        }

        if let pauseReason, !pauseReason.isEmpty {
            pause(reason: pauseReason)
            return
        }

        if case .listening = status, !phraseChanged {
            return
        }

        if phraseChanged {
            stopEngineAndTask()
        }

        startListeningIfPermitted()
    }

    func pause(reason: String) {
        recycleTimer?.invalidate()
        recycleTimer = nil
        stopEngineAndTask()
        status = .paused(reason: reason)
    }

    func stop() {
        recycleTimer?.invalidate()
        recycleTimer = nil
        stopEngineAndTask()
        status = .stopped
    }

    // MARK: - Listening Lifecycle

    private func startListeningIfPermitted() {
        guard !isStarting else { return }
        if Date().timeIntervalSince(lastTriggerDate) < Self.postTriggerCooldownSeconds {
            let remaining = Self.postTriggerCooldownSeconds - Date().timeIntervalSince(lastTriggerDate)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1000) + 100))
                guard let self else { return }
                let config = ClickyConfiguration.shared
                if config.voiceWakeWordEnabled, case .paused = self.status {
                    return
                }
                if config.voiceWakeWordEnabled, self.audioEngine == nil {
                    self.startListeningIfPermitted()
                }
            }
            return
        }

        isStarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isStarting = false }

            let granted = await self.ensurePermissions()
            guard granted else {
                return
            }

            let config = ClickyConfiguration.shared
            guard config.voiceWakeWordEnabled else {
                self.status = .stopped
                return
            }
            if case .paused = self.status {
                return
            }

            do {
                try self.beginAudioAndRecognitionSession(phraseSetting: self.currentPhraseSetting)
            } catch {
                self.stopEngineAndTask()
                self.status = .error("Wake listener error: \(error.localizedDescription)")
                print("⚠️ HeyClickyWakeWordListener failed to start: \(error.localizedDescription)")
            }
        }
    }

    private func ensurePermissions() async -> Bool {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        if micStatus == .authorized && speechStatus == .authorized {
            return true
        }

        status = .requestingPermission

        let micGranted: Bool
        switch micStatus {
        case .authorized:
            micGranted = true
        case .notDetermined:
            micGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        default:
            micGranted = false
        }

        guard micGranted else {
            status = .error("Microphone permission required for wake call")
            return false
        }

        let speechGranted: Bool
        switch speechStatus {
        case .authorized:
            speechGranted = true
        case .notDetermined:
            speechGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authStatus in
                    continuation.resume(returning: authStatus == .authorized)
                }
            }
        default:
            speechGranted = false
        }

        guard speechGranted else {
            status = .error("Speech Recognition permission required for wake call")
            return false
        }

        return true
    }

    private func beginAudioAndRecognitionSession(phraseSetting: String) throws {
        stopEngineAndTask()

        let recognizer = Self.makeRecognizer(for: phraseSetting)
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(
                domain: "HeyClickyWakeWordListener",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable on this Mac"]
            )
        }
        self.speechRecognizer = recognizer

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "HeyClickyWakeWordListener",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No active microphone input format"]
            )
        }

        self.audioEngine = engine
        startNewRecognitionTask(on: engine, recognizer: recognizer, phraseSetting: phraseSetting)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.appendTapAudioBuffer(buffer)
        }

        engine.prepare()
        try engine.start()

        status = .listening(phrase: Self.primaryDisplayPhrase(from: phraseSetting))

        recycleTimer?.invalidate()
        recycleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.taskRecycleIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recycleRecognitionTaskIfActive()
            }
        }
    }

    private func startNewRecognitionTask(
        on engine: AVAudioEngine,
        recognizer: SFSpeechRecognizer,
        phraseSetting: String
    ) {
        recognitionTask?.cancel()
        recognitionTask = nil
        setTapRecognitionRequest(nil)
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        let generationID = UUID()
        activeGenerationID = generationID

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = Self.contextualHints(from: phraseSetting)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = request
        setTapRecognitionRequest(request)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handleRecognitionCallback(
                    generationID: generationID,
                    transcript: transcript,
                    isFinal: isFinal,
                    errorMessage: errorMessage
                )
            }
        }
    }

    private func recycleRecognitionTaskIfActive() {
        guard case .listening = status,
              let engine = audioEngine,
              engine.isRunning,
              let recognizer = speechRecognizer,
              recognizer.isAvailable else {
            return
        }
        startNewRecognitionTask(on: engine, recognizer: recognizer, phraseSetting: currentPhraseSetting)
    }

    private func handleRecognitionCallback(
        generationID: UUID,
        transcript: String?,
        isFinal: Bool,
        errorMessage: String?
    ) {
        guard activeGenerationID == generationID else { return }
        guard case .listening = status else { return }

        if let transcript, !transcript.isEmpty {
            lastHeardSnippet = String(transcript.suffix(80))

            if let match = Self.extractMatch(from: transcript, rawPhraseSetting: currentPhraseSetting) {
                guard Date().timeIntervalSince(lastTriggerDate) >= Self.postTriggerCooldownSeconds else {
                    return
                }
                lastTriggerDate = Date()
                lastTriggeredAt = lastTriggerDate

                recycleTimer?.invalidate()
                recycleTimer = nil
                stopEngineAndTask()
                status = .triggered(phrase: match.matchedPhrase)
                print("🎙️ Wake word detected: \"\(match.matchedPhrase)\" trailing=\"\(match.trailingText)\"")
                onWakeDetected?(match.trailingText)
                return
            }
        }

        if isFinal || errorMessage != nil {
            recycleRecognitionTaskIfActive()
        }
    }

    private func stopEngineAndTask() {
        activeGenerationID = UUID()

        recognitionTask?.cancel()
        recognitionTask = nil

        setTapRecognitionRequest(nil)
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
        }
    }

    private func setTapRecognitionRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        tapRequestLock.lock()
        tapRecognitionRequest = request
        tapRequestLock.unlock()
    }

    nonisolated private func appendTapAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        tapRequestLock.lock()
        let request = tapRecognitionRequest
        tapRequestLock.unlock()
        request?.append(buffer)
    }

    // MARK: - Phrase Normalization & Matching

    private static func makeRecognizer(for phraseSetting: String) -> SFSpeechRecognizer? {
        let lower = phraseSetting.lowercased()
        let selectedLang = ClickyConfiguration.shared.selectedVoiceLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let startsWithEnglishGreeting = lower.hasPrefix("hey ") || lower.hasPrefix("hi ")
        if (lower.contains("halo") || lower.contains("hai ") || (!startsWithEnglishGreeting && selectedLang != "auto" && !selectedLang.isEmpty)) {
            let bcp47 = VoiceLanguageCatalog.language(forCode: selectedLang)?.bcp47Locale
                ?? (selectedLang == "id" ? "id-ID" : selectedLang)
            if let customRecognizer = SFSpeechRecognizer(locale: Locale(identifier: bcp47)),
               customRecognizer.isAvailable {
                return customRecognizer
            }
        }

        if let enRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
           enRecognizer.isAvailable {
            return enRecognizer
        }

        return SFSpeechRecognizer()
    }

    static func primaryDisplayPhrase(from rawSetting: String) -> String {
        let first = rawSetting
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return first ?? "hey clicky"
    }

    private static func contextualHints(from rawSetting: String) -> [String] {
        var hints: [String] = []
        let phrases = rawSetting
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for phrase in phrases {
            hints.append(phrase)
            for word in phrase.split(whereSeparator: \.isWhitespace) {
                let w = String(word)
                if !hints.contains(w) {
                    hints.append(w)
                }
            }
        }
        if hints.isEmpty {
            return ["Hey Clicky", "Clicky", "Hey"]
        }
        return hints
    }

    private static func expandedCandidates(from rawSetting: String) -> [String] {
        let rawPhrases = rawSetting
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { normalizeText(String($0)) }
            .filter { !$0.isEmpty }

        let bases = rawPhrases.isEmpty ? ["hey clicky"] : rawPhrases
        var candidates: [String] = []

        func appendUnique(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }

        for base in bases {
            appendUnique(base)

            if base.hasPrefix("hey ") {
                let target = String(base.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                if target.count >= 2 {
                    appendUnique("a \(target)")
                    appendUnique("he \(target)")
                    appendUnique("hay \(target)")
                    appendUnique("ey \(target)")
                    appendUnique("hi \(target)")
                }
            }

            if base == "hey clicky" {
                appendUnique("hey clickie")
                appendUnique("hey click")
                appendUnique("hey kiki")
                appendUnique("a clicky")
            }
        }

        return candidates
    }

    static func extractMatch(
        from rawTranscript: String,
        rawPhraseSetting: String
    ) -> (matchedPhrase: String, trailingText: String)? {
        let normalizedTranscript = normalizeText(rawTranscript)
        guard !normalizedTranscript.isEmpty else { return nil }

        let transcriptWords = normalizedTranscript.split(separator: " ").map(String.init)
        guard !transcriptWords.isEmpty else { return nil }

        let candidates = expandedCandidates(from: rawPhraseSetting)
        for candidate in candidates {
            let candidateWords = candidate.split(separator: " ").map(String.init)
            guard !candidateWords.isEmpty, transcriptWords.count >= candidateWords.count else { continue }

            // Search from the latest occurrence forward-backward so stale words in the rolling buffer don't trap us.
            for startIndex in stride(from: transcriptWords.count - candidateWords.count, through: 0, by: -1) {
                let slice = Array(transcriptWords[startIndex..<(startIndex + candidateWords.count)])
                if slice == candidateWords {
                    let trailingWords = transcriptWords[(startIndex + candidateWords.count)...]
                    let trailing = trailingWords.joined(separator: " ")
                    return (primaryDisplayPhrase(from: rawPhraseSetting), trailing)
                }
            }
        }

        return nil
    }

    private static func normalizeText(_ text: String) -> String {
        let lower = text.lowercased()
        let cleanedScalars = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return String(cleanedScalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
