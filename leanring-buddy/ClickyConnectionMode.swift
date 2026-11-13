//
//  ClickyConnectionMode.swift
//  leanring-buddy
//

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
    private let hideFloatingCursorKey = "clicky_hide_floating_cursor"
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

    @Published public var hideFloatingCursor: Bool {
        didSet { defaults.set(hideFloatingCursor, forKey: hideFloatingCursorKey) }
    }

    @Published public var cursorColorName: String {
        didSet { defaults.set(cursorColorName, forKey: cursorColorNameKey) }
    }

    @Published public var alwaysApproveFileUploads: Bool {
        didSet { defaults.set(alwaysApproveFileUploads, forKey: alwaysApproveFileUploadsKey) }
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
        self.hideFloatingCursor = defaults.object(forKey: hideFloatingCursorKey) as? Bool ?? false
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
