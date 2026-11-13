//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it back
//  through the system audio output. Supports both Direct API Key (BYOK)
//  and Cloudflare Worker proxy mode.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient: NSObject, AVSpeechSynthesizerDelegate {
    private let fallbackProxyURL: URL?
    private let session: URLSession

    /// The audio player for the current TTS playback.
    private var audioPlayer: AVAudioPlayer?
    private let systemSpeechSynthesizer = AVSpeechSynthesizer()
    private var isSystemSpeechPlaying = false

    init(proxyURL: String? = nil) {
        if let proxyURL = proxyURL, let url = URL(string: proxyURL) {
            self.fallbackProxyURL = url
        } else {
            self.fallbackProxyURL = nil
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)

        super.init()
        self.systemSpeechSynthesizer.delegate = self
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Reads `ClickyConfiguration.shared.workerBaseURL` dynamically at request time.
    func speakText(_ text: String, allowSystemFallback: Bool = false) async throws {
        let config = ClickyConfiguration.shared
        let trimmedDirectKey = config.elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Determine destination: Direct API Key vs dynamically-resolved Worker Proxy
        let url: URL
        var apiKey: String? = nil

        if !trimmedDirectKey.isEmpty {
            let voiceID = config.elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "kPzsL2i3teMYv0FxEYQ6"
                : config.elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let directURL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
                throw URLError(.badURL)
            }
            url = directURL
            apiKey = trimmedDirectKey
        } else if let dynamicWorkerURL = dynamicWorkerEndpointURL(from: config.workerBaseURL) {
            url = dynamicWorkerURL
        } else if let fallbackProxyURL {
            url = fallbackProxyURL
        } else {
            if allowSystemFallback {
                speakWithSystemFallback(text, languageCode: config.selectedVoiceLanguage)
                return
            }
            throw NSError(domain: "ElevenLabsTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "No TTS endpoint or API Key configured."])
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

            if let key = apiKey {
                request.setValue(key, forHTTPHeaderField: "xi-api-key")
            }

            let body: [String: Any] = [
                "text": text,
                "model_id": "eleven_flash_v2_5",
                "voice_settings": [
                    "stability": 0.5,
                    "similarity_boost": 0.75
                ]
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "ElevenLabsTTS", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
            }

            try Task.checkCancellation()

            stopPlayback()
            let player = try AVAudioPlayer(data: data)
            self.audioPlayer = player
            player.prepareToPlay()
            player.play()
            print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if allowSystemFallback {
                print("⚠️ ElevenLabs TTS failed (\(error.localizedDescription)); using local AVSpeechSynthesizer fallback")
                speakWithSystemFallback(text, languageCode: config.selectedVoiceLanguage)
                return
            }
            throw error
        }
    }

    /// Speaks text offline using macOS `AVSpeechSynthesizer` with optional language and speed rate.
    func speakWithSystemFallback(
        _ text: String,
        languageCode: String? = nil,
        rate: Double = 1.0
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        stopPlayback()

        let utterance = AVSpeechUtterance(string: trimmedText)
        let resolvedLanguageCode = (languageCode ?? ClickyConfiguration.shared.selectedVoiceLanguage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolvedLanguageCode.isEmpty && resolvedLanguageCode.lowercased() != "auto" {
            let bcp47 = VoiceLanguageCatalog.language(forCode: resolvedLanguageCode)?.bcp47Locale ?? resolvedLanguageCode
            utterance.voice = AVSpeechSynthesisVoice(language: bcp47)
        }

        let clampedRate = min(max(rate, 0.5), 1.5)
        let mappedRate = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * clampedRate)
        utterance.rate = min(
            max(mappedRate, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )

        isSystemSpeechPlaying = true
        systemSpeechSynthesizer.speak(utterance)
    }

    /// Whether TTS audio or fallback system speech is currently playing back.
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false) || systemSpeechSynthesizer.isSpeaking || isSystemSpeechPlaying
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        if systemSpeechSynthesizer.isSpeaking || isSystemSpeechPlaying {
            systemSpeechSynthesizer.stopSpeaking(at: .immediate)
        }
        isSystemSpeechPlaying = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSystemSpeechPlaying = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSystemSpeechPlaying = false
        }
    }

    private func dynamicWorkerEndpointURL(from workerBaseURL: String) -> URL? {
        let trimmedBase = workerBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty else { return nil }
        return URL(string: "\(trimmedBase)/tts")
    }
}
