//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    /// Called from the capture queue, not the main actor.
    nonisolated func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case assemblyAI = "assemblyai"
        case openAI = "openai"
        case appleSpeech = "apple"
    }

    /// Languages AssemblyAI streaming accepts (its `language_codes` list); anything else needs another provider.
    private nonisolated static let assemblyAIStreamingLanguageCodes: Set<String> = [
        "af", "ar", "yue", "ca", "da", "nl", "en", "et", "fi", "fr", "gl", "de", "he", "hi", "it", "ja", "ko",
        "zh", "mr", "no", "nn", "fa", "pt", "ro", "ru", "es", "sv", "tr", "ur", "vi", "xh", "zu"
    ]

    /// The language the user wants dictation in, or nil for auto-detect. An explicit dictation language
    /// wins; otherwise the voice language (Settings → Language) is used when it is not "auto".
    nonisolated static func effectiveDictationLanguageCode(
        dictationAutoDetect: Bool,
        dictationLanguageCode: String,
        selectedVoiceLanguage: String
    ) -> String? {
        let normalizedDictationCode = dictationLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !dictationAutoDetect, !normalizedDictationCode.isEmpty, normalizedDictationCode != "auto" {
            return normalizedDictationCode
        }
        let normalizedVoiceCode = selectedVoiceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedVoiceCode.isEmpty, normalizedVoiceCode != "auto" {
            return normalizedVoiceCode
        }
        return nil
    }

    /// Accepts "id" or "id-ID"; compares the base language code.
    nonisolated static func isAssemblyAIStreamingLanguage(_ languageCode: String) -> Bool {
        let baseLanguageCode = languageCode.lowercased().split(separator: "-").first.map(String.init) ?? languageCode
        return assemblyAIStreamingLanguageCodes.contains(baseLanguageCode)
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        // AssemblyAI streaming cannot transcribe some languages (Indonesian among them): it guesses
        // another language and returns gibberish. Use Apple Speech in the user's language instead.
        let configuration = ClickyConfiguration.shared
        let dictationLanguageCode = effectiveDictationLanguageCode(
            dictationAutoDetect: configuration.dictationAutoDetect,
            dictationLanguageCode: configuration.dictationLanguageCode,
            selectedVoiceLanguage: configuration.selectedVoiceLanguage
        )
        if preferredProvider == .assemblyAI,
           let dictationLanguageCode,
           !isAssemblyAIStreamingLanguage(dictationLanguageCode) {
            let localeIdentifier = VoiceLanguageCatalog.language(forCode: dictationLanguageCode)?.bcp47Locale ?? dictationLanguageCode
            print("🎙️ Transcription: AssemblyAI can't do '\(dictationLanguageCode)', using Apple Speech (\(localeIdentifier))")
            return AppleSpeechTranscriptionProvider(preferredLocaleIdentifier: localeIdentifier)
        }

        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()

        if preferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .assemblyAI {
            if assemblyAIProvider.isConfigured {
                return assemblyAIProvider
            }

            print("⚠️ Transcription: AssemblyAI preferred but not configured, falling back")

            if openAIProvider.isConfigured {
                print("⚠️ Transcription: using OpenAI as fallback")
                return openAIProvider
            }

            print("⚠️ Transcription: using Apple Speech as fallback")
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .openAI {
            if openAIProvider.isConfigured {
                return openAIProvider
            }

            print("⚠️ Transcription: OpenAI preferred but not configured, falling back")

            if assemblyAIProvider.isConfigured {
                print("⚠️ Transcription: using AssemblyAI as fallback")
                return assemblyAIProvider
            }

            print("⚠️ Transcription: using Apple Speech as fallback")
            return AppleSpeechTranscriptionProvider()
        }

        if assemblyAIProvider.isConfigured {
            return assemblyAIProvider
        }

        if openAIProvider.isConfigured {
            return openAIProvider
        }

        return AppleSpeechTranscriptionProvider()
    }
}
