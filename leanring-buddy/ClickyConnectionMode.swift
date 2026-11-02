//
//  ClickyConnectionMode.swift
//  leanring-buddy
//

import Foundation
import Combine

/// Operating mode for AI inference and media services
public enum ClickyConnectionMode: String, CaseIterable, Identifiable {
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

/// Central configuration store for Clicky connection settings
public final class ClickyConfiguration: ObservableObject {
    public static let shared = ClickyConfiguration()

    private let defaults = UserDefaults.standard

    // Keys
    private let modeKey = "clicky_connection_mode"
    private let openCodexBaseURLKey = "clicky_opencodex_base_url"
    private let openCodexAPIKeyKey = "clicky_opencodex_api_key"
    private let selectedModelKey = "clicky_selected_model"
    private let workerBaseURLKey = "clicky_worker_base_url"
    private let soundEffectsEnabledKey = "clicky_sound_effects_enabled"
    
    // BYOK Keys
    private let anthropicKeyKey = "clicky_anthropic_api_key"
    private let openaiKeyKey = "clicky_openai_api_key"
    private let elevenLabsKeyKey = "clicky_elevenlabs_api_key"
    private let assemblyAIKeyKey = "clicky_assemblyai_api_key"
    private let elevenLabsVoiceIDKey = "clicky_elevenlabs_voice_id"

    @Published public var mode: ClickyConnectionMode {
        didSet { defaults.set(mode.rawValue, forKey: modeKey) }
    }

    @Published public var openCodexBaseURL: String {
        didSet { defaults.set(openCodexBaseURL, forKey: openCodexBaseURLKey) }
    }

    @Published public var openCodexAPIKey: String {
        didSet { ClickyKeychainStore.save(key: openCodexAPIKeyKey, value: openCodexAPIKey) }
    }

    @Published public var selectedModel: String {
        didSet { defaults.set(selectedModel, forKey: selectedModelKey) }
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

    @Published public var elevenLabsAPIKey: String {
        didSet { ClickyKeychainStore.save(key: elevenLabsKeyKey, value: elevenLabsAPIKey) }
    }

    @Published public var assemblyAIAPIKey: String {
        didSet { ClickyKeychainStore.save(key: assemblyAIKeyKey, value: assemblyAIAPIKey) }
    }

    @Published public var elevenLabsVoiceID: String {
        didSet { defaults.set(elevenLabsVoiceID, forKey: elevenLabsVoiceIDKey) }
    }

    private init() {
        let savedMode = defaults.string(forKey: modeKey) ?? ClickyConnectionMode.openCodex.rawValue
        self.mode = ClickyConnectionMode(rawValue: savedMode) ?? .openCodex
        self.openCodexBaseURL = defaults.string(forKey: openCodexBaseURLKey) ?? "http://127.0.0.1:10100/v1"
        self.openCodexAPIKey = ClickyKeychainStore.read(key: openCodexAPIKeyKey) ?? ""
        self.selectedModel = defaults.string(forKey: selectedModelKey) ?? "google-antigravity/gemini-3.8-flash"
        self.workerBaseURL = defaults.string(forKey: workerBaseURLKey) ?? "https://api.heyclicky.com"
        self.soundEffectsEnabled = defaults.object(forKey: soundEffectsEnabledKey) as? Bool ?? true

        self.anthropicAPIKey = ClickyKeychainStore.read(key: anthropicKeyKey) ?? ""
        self.openaiAPIKey = ClickyKeychainStore.read(key: openaiKeyKey) ?? ""
        self.elevenLabsAPIKey = ClickyKeychainStore.read(key: elevenLabsKeyKey) ?? ""
        self.assemblyAIAPIKey = ClickyKeychainStore.read(key: assemblyAIKeyKey) ?? ""
        self.elevenLabsVoiceID = defaults.string(forKey: elevenLabsVoiceIDKey) ?? "kPzsL2i3teMYv0FxEYQ6"
    }
}
