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
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
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

    /// AssemblyAI Universal-3 Pro streaming (`u3-rt-pro`) supports 6 Western languages.
    /// For languages outside this set (e.g. Indonesian, Japanese, Arabic), route to OpenAI
    /// or Apple Speech so the selected language is actually transcribed accurately.
    private static let assemblyAIStreamingSupportedBaseLanguages: Set<String> = [
        "en", "es", "de", "fr", "pt", "it"
    ]

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    private static func effectiveTargetBaseLanguage() -> String {
        let defaults = UserDefaults.standard
        let dictationAutoDetect = defaults.object(forKey: "clicky_dictation_auto_detect") as? Bool ?? true
        let dictationCode = (defaults.string(forKey: "clicky_dictation_language_code") ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let voiceCode = (defaults.string(forKey: "clicky_selected_voice_language") ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let raw: String
        if !dictationAutoDetect && !dictationCode.isEmpty && dictationCode != "auto" {
            raw = dictationCode
        } else if !voiceCode.isEmpty && voiceCode != "auto" {
            raw = voiceCode
        } else {
            return "auto"
        }

        return raw.split(separator: "-").first.map(String.init) ?? raw
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
        let openAIProvider = OpenAIAudioTranscriptionProvider()

        let targetBaseLang = effectiveTargetBaseLanguage()
        let assemblyAISupportsTargetLanguage = targetBaseLang == "auto"
            || assemblyAIStreamingSupportedBaseLanguages.contains(targetBaseLang)

        if preferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }

        if !assemblyAISupportsTargetLanguage {
            if openAIProvider.isConfigured {
                print("🎙️ Transcription: language '\(targetBaseLang)' uses OpenAI (outside AssemblyAI u3-rt-pro streaming set)")
                return openAIProvider
            }
            print("🎙️ Transcription: language '\(targetBaseLang)' uses Apple Speech (outside AssemblyAI u3-rt-pro streaming set)")
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
