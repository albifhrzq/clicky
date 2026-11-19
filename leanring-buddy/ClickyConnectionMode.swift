//
//  ClickyConnectionMode.swift
//  leanring-buddy
//

import AppKit
import Combine
import Foundation

/// Operating mode for AI inference and media services.
nonisolated public enum ClickyConnectionMode: String, CaseIterable, Identifiable, Sendable {
    case openCodex = "opencodex"
    case byok = "byok"
    case cloudflareWorker = "cloudflare_worker"
    case nativeAntigravity = "native_antigravity"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openCodex: return "OpenCodex (Local Proxy / OAuth)"
        case .byok: return "Direct API Keys (BYOK)"
        case .cloudflareWorker: return "Cloudflare Worker Proxy"
        case .nativeAntigravity: return "Google Antigravity (Direct OAuth)"
        }
    }
}

/// Operating mode for the voice input/output pipeline.
nonisolated public enum ClickyVoicePipelineMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case realtimeDuplex = "realtime_duplex"
    case turnBased = "turn_based"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto (Best Available)"
        case .realtimeDuplex: return "Realtime Duplex"
        case .turnBased: return "Turn-Based"
        }
    }
}

/// Central configuration store for Clicky connection, model, voice, and UI settings.
@MainActor
public final class ClickyConfiguration: ObservableObject {
    public static let shared = ClickyConfiguration()

    private let defaults = UserDefaults.standard
    private var openCodexRefreshTask: Task<Void, Never>?

    // UserDefaults Keys
    private let modeKey = "clicky_connection_mode"
    private let openCodexBaseURLKey = "clicky_opencodex_base_url"
    private let openCodexAPIKeyKey = "clicky_opencodex_api_key"
    private let selectedModelKey = "clicky_selected_model"
    private let selectedAgentModelKey = "clicky_selected_agent_model"
    private let workerBaseURLKey = "clicky_worker_base_url"
    private let soundEffectsEnabledKey = "clicky_sound_effects_enabled"
    private let stayQuietDuringCallsKey = "clicky_stay_quiet_during_calls"
    private let askBeforeStartingJobsKey = "clicky_ask_before_starting_jobs"

    // Keychain Keys
    private let anthropicKeyKey = "clicky_anthropic_api_key"
    private let openaiKeyKey = "clicky_openai_api_key"
    private let geminiKeyKey = "clicky_gemini_api_key"
    private let braveKeyKey = "clicky_brave_api_key"
    private let elevenLabsKeyKey = "clicky_elevenlabs_api_key"
    private let assemblyAIKeyKey = "clicky_assemblyai_api_key"
    private let elevenLabsVoiceIDKey = "clicky_elevenlabs_voice_id"
    private let antigravityClientIDKey = "antigravity_client_id"
    private let antigravityClientSecretKey = "antigravity_client_secret"

    // Voice, Dictation, Wake Word, Cursor & Approval Keys
    private let voicePipelineModeKey = "clicky_voice_pipeline_mode"
    private let selectedVoiceIDKey = "clicky_selected_voice_id"
    private let selectedVoiceLanguageKey = "clicky_selected_voice_language"
    private let voiceWakeWordEnabledKey = "clicky_voice_wake_word_enabled"
    private let voiceWakePhraseKey = "clicky_voice_wake_phrase"
    private let dictationLanguageCodeKey = "clicky_dictation_language_code"
    private let dictationAutoDetectKey = "clicky_dictation_auto_detect"
    private let appLanguageKey = "clicky_app_language"
    private let hideFloatingCursorKey = "clicky_hide_floating_cursor"
    private let suggestAgentTasksKey = "clicky_suggest_agent_tasks"
    // Same keys as HeyClicky 1.1.5 so the two Agents → Announcements toggles mean the same thing.
    private let speakWhenJobStartsOrFinishesKey = "ClickyAgentVoiceAnnouncementsEnabled"
    private let showJobUpdatesBesideCursorKey = "ClickyAgentCursorTextAnnouncementsEnabled"
    private let readsAnswersAloudKey = "clicky_reads_answers_aloud"
    private let showUpcomingMeetingsKey = "clicky_show_upcoming_meetings"
    private let cursorColorNameKey = "clicky_cursor_color_name"
    private let alwaysApproveFileUploadsKey = "clicky_always_approve_file_uploads"

    @Published public var mode: ClickyConnectionMode {
        didSet {
            defaults.set(mode.rawValue, forKey: modeKey)
            if mode == .openCodex {
                scheduleOpenCodexRefresh()
            }
        }
    }

    @Published public var openCodexBaseURL: String {
        didSet {
            defaults.set(openCodexBaseURL, forKey: openCodexBaseURLKey)
            if openCodexBaseURL != oldValue && mode == .openCodex {
                scheduleOpenCodexRefresh()
            }
        }
    }

    @Published public var openCodexAPIKey: String {
        didSet { ClickyKeychainStore.save(key: openCodexAPIKeyKey, value: openCodexAPIKey) }
    }

    @Published public var selectedModel: String {
        didSet { defaults.set(selectedModel, forKey: selectedModelKey) }
    }

    @Published public var selectedAgentModel: String {
        didSet { defaults.set(selectedAgentModel, forKey: selectedAgentModelKey) }
    }

    @Published public var workerBaseURL: String {
        didSet { defaults.set(workerBaseURL, forKey: workerBaseURLKey) }
    }

    @Published public var soundEffectsEnabled: Bool {
        didSet { defaults.set(soundEffectsEnabled, forKey: soundEffectsEnabledKey) }
    }

    /// When true, unprompted audio (agent chimes, proactive speech) is skipped while another app is using the mic (a call).
    @Published public var stayQuietDuringCalls: Bool {
        didSet { defaults.set(stayQuietDuringCalls, forKey: stayQuietDuringCallsKey) }
    }

    /// When on, a job the companion offers waits for "Start job" on a notch card; when off it starts right away.
    @Published public var askBeforeStartingJobs: Bool {
        didSet { defaults.set(askBeforeStartingJobs, forKey: askBeforeStartingJobsKey) }
    }

    // Direct Keys
    @Published public var anthropicAPIKey: String {
        didSet { ClickyKeychainStore.save(key: anthropicKeyKey, value: anthropicAPIKey) }
    }

    @Published public var openaiAPIKey: String {
        didSet { ClickyKeychainStore.save(key: openaiKeyKey, value: openaiAPIKey) }
    }

    @Published public var geminiAPIKey: String {
        didSet { ClickyKeychainStore.save(key: geminiKeyKey, value: geminiAPIKey) }
    }

    @Published public var braveAPIKey: String {
        didSet { ClickyKeychainStore.save(key: braveKeyKey, value: braveAPIKey) }
    }

    @Published public var elevenLabsAPIKey: String {
        didSet { ClickyKeychainStore.save(key: elevenLabsKeyKey, value: elevenLabsAPIKey) }
    }

    @Published public var assemblyAIAPIKey: String {
        didSet { ClickyKeychainStore.save(key: assemblyAIKeyKey, value: assemblyAIAPIKey) }
    }

    @Published public var antigravityClientID: String {
        didSet { ClickyKeychainStore.save(key: antigravityClientIDKey, value: antigravityClientID) }
    }

    @Published public var antigravityClientSecret: String {
        didSet { ClickyKeychainStore.save(key: antigravityClientSecretKey, value: antigravityClientSecret) }
    }

    @Published public var elevenLabsVoiceID: String {
        didSet { defaults.set(elevenLabsVoiceID, forKey: elevenLabsVoiceIDKey) }
    }

    @Published public var voicePipelineMode: ClickyVoicePipelineMode {
        didSet { defaults.set(voicePipelineMode.rawValue, forKey: voicePipelineModeKey) }
    }

    @Published public var selectedVoiceID: String {
        didSet { defaults.set(selectedVoiceID, forKey: selectedVoiceIDKey) }
    }

    @Published public var selectedVoiceLanguage: String {
        didSet { defaults.set(selectedVoiceLanguage, forKey: selectedVoiceLanguageKey) }
    }

    @Published public var voiceWakeWordEnabled: Bool {
        didSet { defaults.set(voiceWakeWordEnabled, forKey: voiceWakeWordEnabledKey) }
    }

    @Published public var voiceWakePhrase: String {
        didSet { defaults.set(voiceWakePhrase, forKey: voiceWakePhraseKey) }
    }

    @Published public var dictationLanguageCode: String {
        didSet { defaults.set(dictationLanguageCode, forKey: dictationLanguageCodeKey) }
    }

    @Published public var dictationAutoDetect: Bool {
        didSet { defaults.set(dictationAutoDetect, forKey: dictationAutoDetectKey) }
    }

    /// "system", "en" or "id". Takes effect after relaunch because AppleLanguages is read at launch.
    @Published public var appLanguage: String {
        didSet {
            defaults.set(appLanguage, forKey: appLanguageKey)
            if let appleLanguagesValue = ClickyAppLanguage.appleLanguagesValue(for: appLanguage) {
                defaults.set(appleLanguagesValue, forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    @Published public var hideFloatingCursor: Bool {
        didSet { defaults.set(hideFloatingCursor, forKey: hideFloatingCursorKey) }
    }

    @Published public var suggestAgentTasks: Bool {
        didSet { defaults.set(suggestAgentTasks, forKey: suggestAgentTasksKey) }
    }

    @Published public var showUpcomingMeetings: Bool {
        didSet { defaults.set(showUpcomingMeetings, forKey: showUpcomingMeetingsKey) }
    }

    @Published public var cursorColorName: String {
        didSet { defaults.set(cursorColorName, forKey: cursorColorNameKey) }
    }

    @Published public var alwaysApproveFileUploads: Bool {
        didSet { defaults.set(alwaysApproveFileUploads, forKey: alwaysApproveFileUploadsKey) }
    }

    /// Speaks a short line when a background job starts, finishes, or needs the user.
    @Published public var speakWhenJobStartsOrFinishes: Bool {
        didSet { defaults.set(speakWhenJobStartsOrFinishes, forKey: speakWhenJobStartsOrFinishesKey) }
    }

    /// Shows a finished job's summary in the bubble next to the cursor.
    @Published public var showJobUpdatesBesideCursor: Bool {
        didSet { defaults.set(showJobUpdatesBesideCursor, forKey: showJobUpdatesBesideCursorKey) }
    }

    /// Composer speaker toggle: also speak typed-chat answers out loud.
    @Published public var readsAnswersAloud: Bool {
        didSet { defaults.set(readsAnswersAloud, forKey: readsAnswersAloudKey) }
    }

    /// True when running in any local/direct mode or pointing at a local Worker URL,
    /// unlocking all features without a cloud paywall or login gate.
    public var isLocalModeWithoutPaywall: Bool {
        let lowercasedWorkerURL = workerBaseURL.lowercased()
        return mode != .cloudflareWorker
            || lowercasedWorkerURL.contains("127.0.0.1")
            || lowercasedWorkerURL.contains("localhost")
    }

    private init() {
        let savedMode = defaults.string(forKey: modeKey) ?? ClickyConnectionMode.openCodex.rawValue
        self.mode = ClickyConnectionMode(rawValue: savedMode) ?? .openCodex
        let defaultOpenCodexURL = AppBundleConfiguration.stringValue(forKey: "ClickyOpenCodexBaseURL")
            ?? "http://127.0.0.1:10100/v1"
        self.openCodexBaseURL = defaults.string(forKey: openCodexBaseURLKey) ?? defaultOpenCodexURL
        self.openCodexAPIKey = ClickyKeychainStore.read(key: openCodexAPIKeyKey) ?? ""

        let initialSelectedModel = defaults.string(forKey: selectedModelKey) ?? "google-antigravity/gemini-3.8-flash"
        self.selectedModel = initialSelectedModel
        let savedAgentModel = defaults.string(forKey: selectedAgentModelKey)
        self.selectedAgentModel = (savedAgentModel?.isEmpty == false) ? savedAgentModel! : initialSelectedModel

        let defaultWorkerURL = AppBundleConfiguration.stringValue(forKey: "ClickyWorkerBaseURL")
            ?? "https://api.heyclicky.com"
        self.workerBaseURL = defaults.string(forKey: workerBaseURLKey) ?? defaultWorkerURL
        self.soundEffectsEnabled = defaults.object(forKey: soundEffectsEnabledKey) as? Bool ?? true
        self.stayQuietDuringCalls = defaults.object(forKey: stayQuietDuringCallsKey) as? Bool ?? true
        self.askBeforeStartingJobs = defaults.object(forKey: askBeforeStartingJobsKey) as? Bool ?? true

        self.anthropicAPIKey = ClickyKeychainStore.read(key: anthropicKeyKey) ?? ""
        self.openaiAPIKey = ClickyKeychainStore.read(key: openaiKeyKey) ?? ""
        self.geminiAPIKey = ClickyKeychainStore.read(key: geminiKeyKey) ?? ""
        self.braveAPIKey = ClickyKeychainStore.read(key: braveKeyKey) ?? ""
        self.elevenLabsAPIKey = ClickyKeychainStore.read(key: elevenLabsKeyKey) ?? ""
        self.assemblyAIAPIKey = ClickyKeychainStore.read(key: assemblyAIKeyKey) ?? ""
        self.antigravityClientID = ClickyKeychainStore.read(key: antigravityClientIDKey)
            ?? defaults.string(forKey: antigravityClientIDKey)
            ?? AppBundleConfiguration.stringValue(forKey: "AntigravityClientID")
            ?? ""
        self.antigravityClientSecret = ClickyKeychainStore.read(key: antigravityClientSecretKey)
            ?? defaults.string(forKey: antigravityClientSecretKey)
            ?? AppBundleConfiguration.stringValue(forKey: "AntigravityClientSecret")
            ?? ""
        self.elevenLabsVoiceID = defaults.string(forKey: elevenLabsVoiceIDKey) ?? "kPzsL2i3teMYv0FxEYQ6"

        let savedVoiceMode = defaults.string(forKey: voicePipelineModeKey) ?? ClickyVoicePipelineMode.auto.rawValue
        self.voicePipelineMode = ClickyVoicePipelineMode(rawValue: savedVoiceMode) ?? .auto
        self.selectedVoiceID = defaults.string(forKey: selectedVoiceIDKey) ?? "cedar"
        self.selectedVoiceLanguage = defaults.string(forKey: selectedVoiceLanguageKey) ?? "auto"
        self.voiceWakeWordEnabled = defaults.object(forKey: voiceWakeWordEnabledKey) as? Bool ?? false
        let savedWakePhrase = defaults.string(forKey: voiceWakePhraseKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceWakePhrase = (savedWakePhrase?.isEmpty == false) ? savedWakePhrase! : "hey clicky"
        self.dictationLanguageCode = defaults.string(forKey: dictationLanguageCodeKey) ?? "auto"
        self.dictationAutoDetect = defaults.object(forKey: dictationAutoDetectKey) as? Bool ?? true
        self.appLanguage = defaults.string(forKey: appLanguageKey) ?? "system"
        self.hideFloatingCursor = defaults.object(forKey: hideFloatingCursorKey) as? Bool ?? false
        self.suggestAgentTasks = defaults.object(forKey: suggestAgentTasksKey) as? Bool ?? true
        self.speakWhenJobStartsOrFinishes = defaults.object(forKey: speakWhenJobStartsOrFinishesKey) as? Bool ?? true
        self.showJobUpdatesBesideCursor = defaults.object(forKey: showJobUpdatesBesideCursorKey) as? Bool ?? true
        self.readsAnswersAloud = defaults.object(forKey: readsAnswersAloudKey) as? Bool ?? false
        self.showUpcomingMeetings = defaults.object(forKey: showUpcomingMeetingsKey) as? Bool ?? false
        self.cursorColorName = defaults.string(forKey: cursorColorNameKey) ?? "blue"
        self.alwaysApproveFileUploads = defaults.object(forKey: alwaysApproveFileUploadsKey) as? Bool ?? false
    }

    private func scheduleOpenCodexRefresh() {
        openCodexRefreshTask?.cancel()
        openCodexRefreshTask = Task { @MainActor in
            await OpenCodexService.shared.refresh()
        }
    }
}


/// Maps the app language preference to the `AppleLanguages` override.
enum ClickyAppLanguage {
    /// Returns nil for "system" (and unknown values) so the override key is removed.
    nonisolated static func appleLanguagesValue(for preference: String) -> [String]? {
        switch preference {
        case "en": return ["en"]
        case "id": return ["id"]
        default: return nil
        }
    }

    /// Spawns a detached shell that waits for this process to exit, then opens a new
    /// instance (so two copies never overlap), and terminates the current app.
    /// If the helper cannot be spawned the app keeps running and the error is shown.
    @MainActor static func relaunchApp() {
        let relaunchProcess = Process()
        relaunchProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The bundle path is passed as $0 rather than interpolated into the script.
        relaunchProcess.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        do {
            try relaunchProcess.run()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not relaunch Clicky"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        NSApp.terminate(nil)
    }
}
