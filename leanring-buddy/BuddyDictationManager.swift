//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Shared push-to-talk and system-wide dictation manager.
//  Captures microphone audio with AVAudioEngine, routes it into the active
//  transcription provider, supports AX direct insertion / PID-targeted Cmd+V
//  paste with clipboard restore, optional LLM cleanup via UnifiedLLMClient,
//  local .jsonl transcript archival, and partial transcript clipboard salvage
//  on sleep or interruption.
//

import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import Speech

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        var displayText: String {
            switch self {
            case .shiftFunction:
                return "shift + fn"
            case .controlOption:
                return "ctrl + option"
            case .shiftControl:
                return "shift + control"
            case .controlOptionSpace:
                return "ctrl + option + space"
            case .shiftControlSpace:
                return "shift + control + space"
            }
        }

        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction:
                return ["shift", "fn"]
            case .controlOption:
                return ["ctrl", "option"]
            case .shiftControl:
                return ["shift", "control"]
            case .controlOptionSpace:
                return ["ctrl", "option", "space"]
            case .shiftControlSpace:
                return ["shift", "control", "space"]
            }
        }

        fileprivate var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    static let currentShortcutOption: ShortcutOption = .controlOption
    static let pushToTalkKeyCode: UInt16 = 49 // Space
    static let pushToTalkDisplayText = currentShortcutOption.displayText
    static let pushToTalkTooltipText = "push to talk (\(pushToTalkDisplayText))"

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        if let modifierOnlyFlags = currentShortcutOption.modifierOnlyFlags {
            guard shortcutEventType == .flagsChanged else { return .none }

            let isShortcutCurrentlyPressed = modifierFlags.contains(modifierOnlyFlags)

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard let pushToTalkModifierFlags = currentShortcutOption.spaceShortcutModifierFlags else {
            return .none
        }

        let matchesModifierFlags = modifierFlags.isSuperset(of: pushToTalkModifierFlags)

        if shortcutEventType == .keyDown
            && keyCode == pushToTalkKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .keyUp
            && keyCode == pushToTalkKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
    case systemWideHold
    case systemWideHandsFree
    case wakeWord
}

private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
}

private struct SystemWideTargetContext {
    let processIdentifier: pid_t?
    let bundleIdentifier: String?
    let focusedElement: AXUIElement?
    let isEditableTextElement: Bool
    let isSecureTextField: Bool
}

private struct PasteboardSnapshotItem {
    let representations: [(NSPasteboard.PasteboardType, Data)]
}

struct DictationTranscriptRecord: Codable, Sendable {
    let id: String
    let timestampISO8601: String
    let provider: String
    let languageCode: String
    let mode: String
    let rawText: String
    let finalText: String
    let targetAppBundleID: String?
    let wasInterrupted: Bool
}

private nonisolated enum DictationTranscriptArchive {
    private static let ioQueue = DispatchQueue(label: "com.clicky.dictation-transcript-archive", qos: .utility)

    static func appendRecord(_ record: DictationTranscriptRecord) {
        ioQueue.async {
            guard let directoryURL = transcriptsDirectoryURL() else { return }
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let filename = "\(dateFilePrefix(for: Date())).jsonl"
                let fileURL = directoryURL.appendingPathComponent(filename)

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                let jsonData = try encoder.encode(record)
                var lineData = jsonData
                lineData.append(0x0A) // '\n'

                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: lineData)
                } else {
                    try lineData.write(to: fileURL, options: .atomic)
                }
            } catch {
                print("⚠️ DictationTranscriptArchive: failed to write jsonl record: \(error.localizedDescription)")
            }
        }
    }

    static func transcriptsDirectoryURL() -> URL? {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupportURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("DictationTranscripts", isDirectory: true)
    }

    private static func dateFilePrefix(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Pure rules that keep idle polling/publishing from invalidating SwiftUI views.
nonisolated enum ClickyIdleChurnRules {
    static let audioLevelPublishThreshold: CGFloat = 0.01

    /// Poll slowly once nothing can change; fast while the user is granting permissions.
    static func permissionPollInterval(allPermissionsGranted: Bool) -> TimeInterval {
        allPermissionsGranted ? 3.0 : 1.5
    }

    /// Publish only when the level moved noticeably, or to settle exactly on 0 once.
    static func shouldPublishAudioLevel(current: CGFloat, next: CGFloat) -> Bool {
        if next == current { return false }
        if next == 0 { return true }
        return abs(next - current) > audioLevelPublishThreshold
    }

    /// Snap tiny decaying levels to exactly 0 so the decay tail stops publishing.
    static func settledAudioLevel(_ level: CGFloat) -> CGFloat {
        level < audioLevelPublishThreshold ? 0 : level
    }
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    private static let defaultFinalTranscriptFallbackDelaySeconds: TimeInterval = 2.4
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.07
    private static let transcriptCleanupDefaultsKey = "clicky_dictation_llm_cleanup_enabled"

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isSystemWideDictationActive = false
    @Published private(set) var isHandsFreeDictationActive = false
    @Published private(set) var isWakeWordRecording = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.recordedAudioPowerHistoryBaselineLevel,
        count: BuddyDictationManager.recordedAudioPowerHistoryLength
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var lastSalvagedTranscript: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    @Published var isTranscriptCleanupEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isTranscriptCleanupEnabled, forKey: Self.transcriptCleanupDefaultsKey)
        }
    }

    var isDictationInProgress: Bool {
        isPreparingToRecord
            || isRecordingFromMicrophoneButton
            || isRecordingFromKeyboardShortcut
            || isSystemWideDictationActive
            || isWakeWordRecording
            || isFinalizingTranscript
    }

    var isActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
            || isRecordingFromKeyboardShortcut
            || isSystemWideDictationActive
            || isWakeWordRecording
    }

    var isMicrophoneButtonActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
    }

    var isMicrophoneButtonSessionBusy: Bool {
        activeStartSource == .microphoneButton
            && (isPreparingToRecord || isRecordingFromMicrophoneButton || isFinalizingTranscript)
    }

    var needsInitialPermissionPrompt: Bool {
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    private var transcriptionProvider: any BuddyTranscriptionProvider
    // AVCaptureSession-based mic input on the Settings-chosen microphone (does not touch the output device).
    private let microphoneCaptureInput = ClickyMicrophoneCaptureInput(logPrefix: "BuddyDictationManager")
    // The capture handler runs on a background queue, so it reads the current session through this lock-protected box.
    private let audioBufferTargetSessionBox = BuddyAudioBufferTargetSessionBox()
    private let unifiedLLMClient = UnifiedLLMClient()
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var activeSystemWideTargetContext: SystemWideTargetContext?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    private var pendingStartRequestIdentifier = UUID()
    private var contextualKeyterms: [String] = []
    private var lastRecordedAudioPowerSampleDate = Date.distantPast
    private var activePermissionRequestTask: Task<Bool, Never>?
    private var wakeSilenceMonitorTask: Task<Void, Never>?
    private var shortcutMonitorCancellable: AnyCancellable?
    nonisolated(unsafe) private var sleepObserver: NSObjectProtocol?
    /// Timestamp of the last completed permission request, used to debounce
    /// rapid follow-up requests that arrive before macOS updates its cache.
    private var lastPermissionRequestCompletedAt: Date?

    override init() {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        self.isTranscriptCleanupEnabled = UserDefaults.standard.bool(forKey: Self.transcriptCleanupDefaultsKey)
        super.init()

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemSleepInterruption()
            }
        }
    }

    deinit {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
    }

    func updateContextualKeyterms(_ contextualKeyterms: [String]) {
        self.contextualKeyterms = contextualKeyterms
    }

    /// Binds `dictationHold`, `handsFreeDictation`, and `escapeInterrupted` slots
    /// from a `GlobalPushToTalkShortcutMonitor` to system-wide Type Anywhere dictation.
    func attachShortcutMonitor(_ monitor: GlobalPushToTalkShortcutMonitor) {
        shortcutMonitorCancellable?.cancel()
        shortcutMonitorCancellable = monitor.slotEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .pressed(let slot) where slot == .dictationHold:
                    Task { await self.startSystemWideDictation(handsFree: false) }
                case .released(let slot) where slot == .dictationHold:
                    self.stopSystemWideDictation()
                case .triggered(let slot) where slot == .handsFreeDictation:
                    Task { await self.toggleHandsFreeSystemWideDictation() }
                case .escapeInterrupted:
                    if self.isDictationInProgress {
                        self.salvagePartialTranscriptToClipboardIfNeeded(reason: "escape")
                        self.cancelCurrentDictation(preserveDraftText: true)
                    }
                default:
                    break
                }
            }
    }

    func startPersistentDictationFromMicrophoneButton(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: false
        )
    }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .keyboardShortcut,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: currentDraftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    /// Starts a hands-free voice turn triggered by the wake word listener and
    /// automatically stops & submits after a brief silence once the user finishes speaking.
    func startWakeTriggeredCapture(
        initialTrailingText: String,
        submitDraftText: @escaping (String) -> Void
    ) async {
        guard !isDictationInProgress else { return }

        let trimmedTrailing = initialTrailingText.trimmingCharacters(in: .whitespacesAndNewlines)

        await startPushToTalk(
            startSource: .wakeWord,
            currentDraftText: trimmedTrailing,
            updateDraftText: { _ in },
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: true
        )

        guard isWakeWordRecording else { return }
        startWakeSilenceMonitor(hasInitialTrailingText: !trimmedTrailing.isEmpty)
    }

    private func startWakeSilenceMonitor(hasInitialTrailingText: Bool) {
        wakeSilenceMonitorTask?.cancel()
        wakeSilenceMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var lastSpeechAt = startedAt
            var lastTranscript = self.latestRecognizedText
            var sawNewSpeech = hasInitialTrailingText

            // Brief grace period before checking silence so mic warmup doesn't cut off early.
            while !Task.isCancelled && self.isWakeWordRecording && !self.isFinalizingTranscript {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled && self.isWakeWordRecording && !self.isFinalizingTranscript else {
                    return
                }

                let now = Date()
                let elapsed = now.timeIntervalSince(startedAt)

                if self.latestRecognizedText != lastTranscript {
                    lastTranscript = self.latestRecognizedText
                    if !lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sawNewSpeech = true
                        lastSpeechAt = now
                    }
                } else if self.currentAudioPowerLevel > 0.085 && elapsed > 0.25 {
                    sawNewSpeech = true
                    lastSpeechAt = now
                }

                let silenceSeconds = now.timeIntervalSince(lastSpeechAt)

                if elapsed >= 25.0 {
                    self.stopPushToTalk(expectedStartSource: .wakeWord)
                    return
                }

                if sawNewSpeech {
                    let threshold: TimeInterval = hasInitialTrailingText && self.latestRecognizedText.isEmpty ? 1.25 : 1.45
                    if silenceSeconds >= threshold {
                        if hasInitialTrailingText && self.latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // User spoke the whole question in one breath right after wake word.
                            let directQuestion = self.draftTextBeforeCurrentDictation.trimmingCharacters(in: .whitespacesAndNewlines)
                            let callbacks = self.draftCallbacks
                            self.cancelCurrentDictation(preserveDraftText: false)
                            if !directQuestion.isEmpty {
                                callbacks?.submitDraftText(directQuestion)
                            }
                        } else {
                            self.stopPushToTalk(expectedStartSource: .wakeWord)
                        }
                        return
                    }
                } else if silenceSeconds >= 6.5 {
                    // User only said the wake word and stayed silent.
                    self.cancelCurrentDictation(preserveDraftText: false)
                    return
                }
            }
        }
    }

    func startSystemWideDictation(handsFree: Bool = false) async {
        let targetContext = Self.captureSystemWideTargetContext()
        activeSystemWideTargetContext = targetContext

        await startPushToTalk(
            startSource: handsFree ? .systemWideHandsFree : .systemWideHold,
            currentDraftText: "",
            updateDraftText: { _ in },
            submitDraftText: { _ in },
            shouldAutomaticallySubmitFinalDraftOnStop: true
        )
    }

    func stopSystemWideDictation() {
        if activeStartSource == .systemWideHold {
            stopPushToTalk(expectedStartSource: .systemWideHold)
        } else if activeStartSource == .systemWideHandsFree {
            stopPushToTalk(expectedStartSource: .systemWideHandsFree)
        }
    }

    func toggleHandsFreeSystemWideDictation() async {
        if isHandsFreeDictationActive || activeStartSource == .systemWideHandsFree {
            stopPushToTalk(expectedStartSource: .systemWideHandsFree)
        } else if !isDictationInProgress {
            await startSystemWideDictation(handsFree: true)
        }
    }

    func stopPersistentDictationFromMicrophoneButton() {
        stopPushToTalk(expectedStartSource: .microphoneButton)
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        pendingStartRequestIdentifier = UUID()
        wakeSilenceMonitorTask?.cancel()
        wakeSilenceMonitorTask = nil

        guard isDictationInProgress else { return }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if preserveDraftText {
            let currentDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
            draftCallbacks?.updateDraftText(currentDraftText)
        }

        microphoneCaptureInput.stop()
        activeTranscriptionSession?.cancel()

        resetSessionState()
    }

    func requestInitialPushToTalkPermissionsIfNeeded() async {
        refreshTranscriptionProvider()
        guard needsInitialPermissionPrompt else { return }
        guard !isDictationInProgress else { return }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        NSApplication.shared.activate(ignoringOtherApps: true)

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            // Safely continue into permission check.
        }

        let hasPermissions = await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts()
        isPreparingToRecord = false

        if hasPermissions {
            lastErrorMessage = nil
        }
    }

    private func refreshTranscriptionProvider() {
        let resolved = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = resolved
        self.transcriptionProviderDisplayName = resolved.displayName
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool
    ) async {
        guard !isDictationInProgress else { return }

        refreshTranscriptionProvider()
        print("🎙️ BuddyDictationManager: start requested (\(startSource))")

        let isSystemWideSource = startSource == .systemWideHold || startSource == .systemWideHandsFree
        if needsInitialPermissionPrompt && !isSystemWideSource {
            print("🎙️ BuddyDictationManager: requesting initial permissions")
            NSApplication.shared.activate(ignoringOtherApps: true)

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // Continue into permission request.
            }
        }

        let startRequestIdentifier = UUID()
        pendingStartRequestIdentifier = startRequestIdentifier

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() else {
            print("🎙️ BuddyDictationManager: permissions missing or denied")
            isPreparingToRecord = false
            activeSystemWideTargetContext = nil
            return
        }
        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released during permission check)")
            isPreparingToRecord = false
            activeSystemWideTargetContext = nil
            return
        }
        guard pendingStartRequestIdentifier == startRequestIdentifier else {
            print("🎙️ BuddyDictationManager: start request superseded")
            isPreparingToRecord = false
            return
        }

        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText
        )
        activeStartSource = startSource
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        isSystemWideDictationActive = isSystemWideSource
        isHandsFreeDictationActive = startSource == .systemWideHandsFree
        isWakeWordRecording = startSource == .wakeWord
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast

        guard !Task.isCancelled else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released before recording began)")
            resetSessionState()
            return
        }

        do {
            try await startRecognitionSession()
            guard !Task.isCancelled else {
                print("🎙️ BuddyDictationManager: start cancelled (shortcut released during session start)")
                microphoneCaptureInput.stop()
                activeTranscriptionSession?.cancel()
                resetSessionState()
                return
            }
            if startSource == .microphoneButton {
                microphoneButtonRecordingStartedAt = Date()
            }
            isPreparingToRecord = false
            print("🎙️ BuddyDictationManager: recognition session started")
        } catch {
            isPreparingToRecord = false
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: ClickyVoiceMessages.couldntStartVoiceInput
            )
            print("❌ BuddyDictationManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")
            resetSessionState()
        }
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard activeStartSource == expectedStartSource else {
            isPreparingToRecord = false
            return
        }
        guard !isFinalizingTranscript else { return }

        print("🎙️ BuddyDictationManager: stop requested (\(expectedStartSource))")

        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isSystemWideDictationActive = false
        isHandsFreeDictationActive = false
        isWakeWordRecording = false
        isFinalizingTranscript = true
        wakeSilenceMonitorTask?.cancel()
        wakeSilenceMonitorTask = nil

        let finalTranscriptFallbackDelaySeconds = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds
            ?? Self.defaultFinalTranscriptFallbackDelaySeconds

        microphoneCaptureInput.stop()
        activeTranscriptionSession?.requestFinalTranscript()

        finalizeFallbackWorkItem?.cancel()
        let shouldSubmitFinalDraftWhenFallbackTriggers = shouldAutomaticallySubmitFinalDraft
        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finishCurrentDictationSessionIfNeeded(
                    shouldSubmitFinalDraft: shouldSubmitFinalDraftWhenFallbackTriggers
                )
            }
        }
        finalizeFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + finalTranscriptFallbackDelaySeconds,
            execute: fallbackWorkItem
        )
    }

    private func startRecognitionSession() async throws {
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        print("🎙️ BuddyDictationManager: opening transcription provider \(transcriptionProvider.displayName)")

        let activeTranscriptionSession = try await transcriptionProvider.startStreamingSession(
            keyterms: buildTranscriptionKeyterms(),
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    self?.latestRecognizedText = transcriptText
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestRecognizedText = transcriptText

                    if self.isFinalizingTranscript {
                        self.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: self.shouldAutomaticallySubmitFinalDraft
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleRecognitionError(error)
                }
            }
        )

        self.activeTranscriptionSession = activeTranscriptionSession
        print("🎙️ BuddyDictationManager: provider ready, starting audio engine")

        // Start failures (no mic, session can't be built) throw into the existing recognition-start error path.
        audioBufferTargetSessionBox.setSession(activeTranscriptionSession)
        try microphoneCaptureInput.start(
            onAudioBuffer: Self.makeAudioBufferHandler(
                targetSessionBox: audioBufferTargetSessionBox,
                dictationManager: self
            )
        )
    }

    /// Built in a nonisolated context on purpose: the handler runs on the capture delivery queue, and a
    /// MainActor-isolated closure invoked there would trip Swift's runtime isolation check.
    private nonisolated static func makeAudioBufferHandler(
        targetSessionBox: BuddyAudioBufferTargetSessionBox,
        dictationManager: BuddyDictationManager
    ) -> @Sendable (AVAudioPCMBuffer) -> Void {
        return { [weak dictationManager] buffer in
            targetSessionBox.currentSession()?.appendAudioBuffer(buffer)
            dictationManager?.updateAudioPowerLevel(from: buffer)
        }
    }

    private func handleRecognitionError(_ error: Error) {
        if hasFinishedCurrentDictationSession {
            return
        }

        if isFinalizingTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft
            )
        } else {
            print("❌ Buddy dictation error (\(transcriptionProvider.displayName)): \(error)")
            salvagePartialTranscriptToClipboardIfNeeded(reason: "error")
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: ClickyVoiceMessages.couldntTranscribeThatTryAgain
            )
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func handleSystemSleepInterruption() {
        guard isDictationInProgress else { return }
        salvagePartialTranscriptToClipboardIfNeeded(reason: "sleep")
        cancelCurrentDictation(preserveDraftText: true)
    }

    private func salvagePartialTranscriptToClipboardIfNeeded(reason: String) {
        let trimmedPartial = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPartial.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmedPartial, forType: .string)
        lastSalvagedTranscript = trimmedPartial

        let isSystemWide = activeStartSource == .systemWideHold || activeStartSource == .systemWideHandsFree
        archiveTranscriptRecord(
            rawText: trimmedPartial,
            finalText: trimmedPartial,
            mode: isSystemWide ? "systemWide" : "inApp",
            targetAppBundleID: activeSystemWideTargetContext?.bundleIdentifier,
            wasInterrupted: true
        )

        print("📋 BuddyDictationManager: salvaged partial transcript to clipboard on \(reason) (\(trimmedPartial.count) chars)")
    }

    private func finishCurrentDictationSessionIfNeeded(shouldSubmitFinalDraft: Bool) {
        guard !hasFinishedCurrentDictationSession else { return }
        hasFinishedCurrentDictationSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let capturedStartSource = activeStartSource
        let capturedTargetContext = activeSystemWideTargetContext
        let rawTranscriptText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedDraftPrefix = draftTextBeforeCurrentDictation
        let currentDraftCallbacks = draftCallbacks

        microphoneCaptureInput.stop()
        activeTranscriptionSession?.cancel()

        resetSessionState()

        guard !rawTranscriptText.isEmpty else { return }
        guard !ClickyTranscriptNoiseFilter.isNoise(rawTranscriptText) else {
            print("🎙️ BuddyDictationManager: dropped noise-only transcript")
            return
        }

        let isSystemWide = capturedStartSource == .systemWideHold || capturedStartSource == .systemWideHandsFree

        Task { @MainActor [weak self] in
            guard let self else { return }

            let finalTranscriptText: String
            if self.isTranscriptCleanupEnabled {
                finalTranscriptText = await self.cleanupTranscriptWithLLMIfPossible(rawTranscriptText)
            } else {
                finalTranscriptText = rawTranscriptText
            }

            self.archiveTranscriptRecord(
                rawText: rawTranscriptText,
                finalText: finalTranscriptText,
                mode: isSystemWide ? "systemWide" : "inApp",
                targetAppBundleID: capturedTargetContext?.bundleIdentifier,
                wasInterrupted: false
            )

            if isSystemWide {
                await self.insertTextAtCurrentSystemCursor(
                    finalTranscriptText,
                    targetContext: capturedTargetContext
                )
                return
            }

            let finalDraftText = Self.composeDraftText(
                existingDraft: capturedDraftPrefix,
                withTranscribedText: finalTranscriptText
            )

            if !shouldSubmitFinalDraft && !finalDraftText.isEmpty {
                currentDraftCallbacks?.updateDraftText(finalDraftText)
            }

            guard shouldSubmitFinalDraft else { return }
            currentDraftCallbacks?.submitDraftText(finalDraftText)
        }
    }

    // MARK: - Optional LLM Transcript Cleanup

    private func cleanupTranscriptWithLLMIfPossible(_ rawText: String) async -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        let cleanupSystemPrompt = """
        Clean up this raw speech-to-text dictation transcript. Fix punctuation, capitalization, and obvious filler words (like "um", "uh") while preserving the speaker's exact meaning, wording, technical terms, and original language. Return ONLY the cleaned transcript text with no quotes or commentary.
        """

        do {
            let cleaned = try await unifiedLLMClient.completeText(
                systemPrompt: cleanupSystemPrompt,
                userPrompt: trimmed
            )
            let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedCleaned.isEmpty ? trimmed : trimmedCleaned
        } catch {
            print("⚠️ BuddyDictationManager: LLM cleanup failed, keeping raw transcript: \(error.localizedDescription)")
            return trimmed
        }
    }

    // MARK: - Local JSONL Backup

    private func archiveTranscriptRecord(
        rawText: String,
        finalText: String,
        mode: String,
        targetAppBundleID: String?,
        wasInterrupted: Bool
    ) {
        let config = ClickyConfiguration.shared
        let language = config.dictationAutoDetect ? "auto" : config.dictationLanguageCode
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let record = DictationTranscriptRecord(
            id: UUID().uuidString,
            timestampISO8601: timestamp,
            provider: transcriptionProviderDisplayName,
            languageCode: language,
            mode: mode,
            rawText: rawText,
            finalText: finalText,
            targetAppBundleID: targetAppBundleID,
            wasInterrupted: wasInterrupted
        )
        DictationTranscriptArchive.appendRecord(record)
    }

    // MARK: - System-Wide Type Anywhere (AX Direct Insertion + PID-Targeted Cmd+V Paste + Clipboard Restore)

    @discardableResult
    func insertTextAtCurrentSystemCursor(_ text: String) async -> Bool {
        let context = Self.captureSystemWideTargetContext()
        return await insertTextAtCurrentSystemCursor(text, targetContext: context)
    }

    @discardableResult
    private func insertTextAtCurrentSystemCursor(
        _ text: String,
        targetContext: SystemWideTargetContext?
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let resolvedContext = targetContext ?? Self.captureSystemWideTargetContext()

        if resolvedContext.isSecureTextField {
            lastErrorMessage = ClickyVoiceMessages.iDidntFillThatPasswordField
            return false
        }

        // 1. Try Accessibility direct insertion at caret (zero clipboard disruption)
        if let focusedElement = resolvedContext.focusedElement,
           resolvedContext.isEditableTextElement,
           Self.tryInsertViaAccessibility(trimmed, into: focusedElement) {
            return true
        }

        // 2. Fallback: PID-targeted Cmd+V paste with full clipboard snapshot & restore.
        // Without Accessibility the synthetic paste cannot work, so leave the text on the clipboard instead.
        guard AXIsProcessTrusted() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
            lastErrorMessage = "\(ClickyVoiceMessages.copiedToYourClipboard) · \(ClickyVoiceMessages.enableAccessibilityToInsertDictation)"
            return false
        }
        return await pasteWithClipboardRestore(trimmed, targetPID: resolvedContext.processIdentifier)
    }

    private static func captureSystemWideTargetContext() -> SystemWideTargetContext {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let targetPID: pid_t? = (frontApp != nil && frontApp?.processIdentifier != selfPID)
            ? frontApp?.processIdentifier
            : nil
        let bundleID = targetPID != nil ? frontApp?.bundleIdentifier : nil

        guard AXIsProcessTrusted() else {
            return SystemWideTargetContext(
                processIdentifier: targetPID,
                bundleIdentifier: bundleID,
                focusedElement: nil,
                isEditableTextElement: false,
                isSecureTextField: false
            )
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let copyStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard copyStatus == .success, let focusedObject else {
            return SystemWideTargetContext(
                processIdentifier: targetPID,
                bundleIdentifier: bundleID,
                focusedElement: nil,
                isEditableTextElement: false,
                isSecureTextField: false
            )
        }

        let focusedElement = focusedObject as! AXUIElement
        let isEditable = isAXElementEditable(focusedElement)

        return SystemWideTargetContext(
            processIdentifier: targetPID,
            bundleIdentifier: bundleID,
            focusedElement: focusedElement,
            isEditableTextElement: isEditable,
            isSecureTextField: Self.isAXElementSecureTextField(focusedElement)
        )
    }

    /// Password fields expose AXSubrole == AXSecureTextField; never type into them.
    private static func isAXElementSecureTextField(_ element: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
              let subrole = subroleValue as? String else { return false }
        return subrole == "AXSecureTextField"
    }

    private static func isAXElementEditable(_ element: AXUIElement) -> Bool {
        var isSelectedTextSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSelectedTextSettable) == .success,
           isSelectedTextSettable.boolValue {
            return true
        }

        var isValueSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isValueSettable) == .success,
           isValueSettable.boolValue {
            return true
        }

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String {
            let editableRoles: Set<String> = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String
            ]
            if editableRoles.contains(role) {
                return true
            }
        }

        return false
    }

    private static func tryInsertViaAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        var isSelectedTextSettable: DarwinBoolean = false
        let settableCheck = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSelectedTextSettable
        )
        guard settableCheck == .success, isSelectedTextSettable.boolValue else {
            return false
        }

        let setStatus = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        return setStatus == .success
    }

    private func pasteWithClipboardRestore(_ text: String, targetPID: pid_t?) async -> Bool {
        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let injectedChangeCount = pasteboard.changeCount

        let posted = Self.postCommandVPaste(toPID: targetPID)

        // Allow the target app a brief window to read NSPasteboard before restoring
        try? await Task.sleep(for: .milliseconds(250))

        if pasteboard.changeCount == injectedChangeCount {
            restorePasteboard(pasteboard, from: savedItems)
        }

        return posted
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [PasteboardSnapshotItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let reps: [(NSPasteboard.PasteboardType, Data)] = item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return PasteboardSnapshotItem(representations: reps)
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, from snapshot: [PasteboardSnapshotItem]) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }

        let restoredItems: [NSPasteboardItem] = snapshot.compactMap { itemSnapshot in
            guard !itemSnapshot.representations.isEmpty else { return nil }
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in itemSnapshot.representations {
                pasteboardItem.setData(data, forType: type)
            }
            return pasteboardItem
        }

        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }

    private static func postCommandVPaste(toPID targetPID: pid_t?) -> Bool {
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V
        guard let eventSource = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        if let targetPID, targetPID > 0 {
            keyDown.postToPid(targetPID)
            keyUp.postToPid(targetPID)
        } else {
            keyDown.post(tap: .cgSessionEventTap)
            keyUp.post(tap: .cgSessionEventTap)
        }
        return true
    }

    private func composeDraftText(withTranscribedText transcribedText: String) -> String {
        Self.composeDraftText(
            existingDraft: draftTextBeforeCurrentDictation,
            withTranscribedText: transcribedText
        )
    }

    private static func composeDraftText(
        existingDraft: String,
        withTranscribedText transcribedText: String
    ) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return existingDraft
        }

        let trimmedExistingDraftText = existingDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if existingDraft.hasSuffix(" ") || existingDraft.hasSuffix("\n") {
            return existingDraft + trimmedTranscriptText
        }

        return existingDraft + " " + trimmedTranscriptText
    }

    private func resetSessionState() {
        pendingStartRequestIdentifier = UUID()
        activeTranscriptionSession = nil
        draftCallbacks = nil
        activeStartSource = nil
        activeSystemWideTargetContext = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false
        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isSystemWideDictationActive = false
        isHandsFreeDictationActive = false
        isWakeWordRecording = false
        isFinalizingTranscript = false
        wakeSilenceMonitorTask?.cancel()
        wakeSilenceMonitorTask = nil
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast
    }

    private func buildTranscriptionKeyterms() -> [String] {
        let baseKeyterms = [
            "makesomething",
            "Learning Buddy",
            "Clicky",
            "Codex",
            "Claude",
            "Anthropic",
            "OpenAI",
            "Gemini",
            "SwiftUI",
            "Xcode",
            "Vercel",
            "Next.js",
            "localhost"
        ]

        let combinedKeyterms = baseKeyterms + contextualKeyterms
        var uniqueNormalizedKeyterms = Set<String>()
        var orderedKeyterms: [String] = []

        for keyterm in combinedKeyterms {
            let trimmedKeyterm = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKeyterm.isEmpty else { continue }

            let normalizedKeyterm = trimmedKeyterm.lowercased()
            if uniqueNormalizedKeyterms.contains(normalizedKeyterm) {
                continue
            }

            uniqueNormalizedKeyterms.insert(normalizedKeyterm)
            orderedKeyterms.append(trimmedKeyterm)
        }

        return orderedKeyterms
    }

    private nonisolated func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        Task { @MainActor [weak self] in
            guard let self else { return }

            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.72
            )
            let settledAudioPowerLevel = ClickyIdleChurnRules.settledAudioLevel(smoothedAudioPowerLevel)
            if ClickyIdleChurnRules.shouldPublishAudioLevel(
                current: self.currentAudioPowerLevel,
                next: settledAudioPowerLevel
            ) {
                self.currentAudioPowerLevel = settledAudioPowerLevel
            }

            let now = Date()
            if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                self.lastRecordedAudioPowerSampleDate = now
                self.appendRecordedAudioPowerSample(
                    max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                )
            }
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            lastErrorMessage = ClickyVoiceMessages.microphonePermissionRequiredForPushToTalk
            return false
        }

        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return true
        }

        let hasSpeechRecognitionPermission = await requestSpeechRecognitionPermissionIfNeeded()
        guard hasSpeechRecognitionPermission else {
            lastErrorMessage = ClickyVoiceMessages.speechRecognitionPermissionRequiredForPushToTalk
            return false
        }

        return true
    }

    private func requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() async -> Bool {
        if let activePermissionRequestTask {
            return await activePermissionRequestTask.value
        }

        if let lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(lastPermissionRequestCompletedAt) < 1.0 {
            return AVCaptureDevice.authorizationStatus(for: .audio) != .denied
                && AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
        }

        let permissionRequestTask = Task { @MainActor in
            await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }

        activePermissionRequestTask = permissionRequestTask

        let hasPermissions = await permissionRequestTask.value
        activePermissionRequestTask = nil
        lastPermissionRequestCompletedAt = Date()
        return hasPermissions
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
            currentPermissionProblem = isGranted ? nil : .speechRecognitionDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        @unknown default:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        }
    }

    func openRelevantPrivacySettings() {
        let settingsURLString: String

        switch currentPermissionProblem {
        case .microphoneAccessDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognitionDenied:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case nil:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security"
        }

        guard let settingsURL = URL(string: settingsURLString) else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func userFacingErrorMessage(from error: Error, fallback: String) -> String {
        ClickyVoiceErrorMapper.message(
            for: error,
            providerName: transcriptionProvider.displayName,
            fallback: fallback
        )
    }
}


/// Lock-protected reference to the transcription session that capture buffers feed, readable from the capture queue.
nonisolated final class BuddyAudioBufferTargetSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any BuddyStreamingTranscriptionSession)?

    func setSession(_ newSession: (any BuddyStreamingTranscriptionSession)?) {
        lock.lock()
        session = newSession
        lock.unlock()
    }

    func currentSession() -> (any BuddyStreamingTranscriptionSession)? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }
}
