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
final class ElevenLabsTTSClient {
    private let proxyURL: URL?
    private let session: URLSession

    /// The audio player for the current TTS playback.
    private var audioPlayer: AVAudioPlayer?

    init(proxyURL: String? = nil) {
        if let proxyURL = proxyURL, let url = URL(string: proxyURL) {
            self.proxyURL = url
        } else {
            self.proxyURL = nil
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    func speakText(_ text: String) async throws {
        let config = ClickyConfiguration.shared

        // Determine destination: Direct API Key vs Proxy
        let url: URL
        var apiKey: String? = nil

        if !config.elevenLabsAPIKey.isEmpty {
            // Direct ElevenLabs API (BYOK)
            let voiceID = config.elevenLabsVoiceID.isEmpty ? "kPzsL2i3teMYv0FxEYQ6" : config.elevenLabsVoiceID
            guard let directURL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
                throw URLError(.badURL)
            }
            url = directURL
            apiKey = config.elevenLabsAPIKey
        } else if let proxy = proxyURL {
            url = proxy
        } else if let fallbackProxy = URL(string: "\(config.workerBaseURL)/tts") {
            url = fallbackProxy
        } else {
            throw NSError(domain: "ElevenLabsTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "No TTS endpoint or API Key configured."])
        }

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

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }
}
