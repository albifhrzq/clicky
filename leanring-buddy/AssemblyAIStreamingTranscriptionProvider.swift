//
//  AssemblyAIStreamingTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming AI transcription provider backed by AssemblyAI's websocket API.
//

import AVFoundation
import Foundation

struct AssemblyAIStreamingTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class AssemblyAIStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    private static let byokTokenEndpointURLString = "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480"

    let displayName = "AssemblyAI"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        let config = ClickyConfiguration.shared
        let hasDirectKey = !config.assemblyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasDirectKey {
            return true
        }
        let hasWorkerURL = !config.workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return config.mode == .cloudflareWorker && hasWorkerURL
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "AssemblyAI transcription is not configured. Add an AssemblyAI API key in Settings or switch to Cloudflare Worker mode."
    }

    /// Single long-lived URLSession shared across all streaming sessions.
    /// Creating and invalidating a URLSession per session corrupts the OS
    /// connection pool and causes "Socket is not connected" errors after
    /// a few rapid reconnections to the same host.
    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        // Fetch a fresh temporary token before each session
        let temporaryToken = try await fetchTemporaryToken()
        print("🎙️ AssemblyAI: fetched temporary token (\(temporaryToken.prefix(20))...)")

        let session = AssemblyAIStreamingTranscriptionSession(
            apiKey: nil,
            temporaryToken: temporaryToken,
            urlSession: sharedWebSocketURLSession,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }

    /// Fetches a short-lived AssemblyAI v3 token directly via
    /// `GET https://streaming.assemblyai.com/v3/token?expires_in_seconds=480` in BYOK mode
    /// or via the Cloudflare Worker `/transcribe-token` proxy route.
    private func fetchTemporaryToken() async throws -> String {
        let config = ClickyConfiguration.shared
        let trimmedDirectKey = config.assemblyAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var request: URLRequest
        if !trimmedDirectKey.isEmpty {
            guard let url = URL(string: Self.byokTokenEndpointURLString) else {
                throw AssemblyAIStreamingTranscriptionProviderError(
                    message: "Invalid AssemblyAI v3 token URL."
                )
            }
            request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(trimmedDirectKey, forHTTPHeaderField: "Authorization")
        } else {
            let trimmedWorkerBase = config.workerBaseURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmedWorkerBase.isEmpty,
                  let workerURL = URL(string: "\(trimmedWorkerBase)/transcribe-token") else {
                throw AssemblyAIStreamingTranscriptionProviderError(
                    message: "No AssemblyAI API key or Worker proxy URL is configured."
                )
            }
            request = URLRequest(url: workerURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "Failed to fetch AssemblyAI token (HTTP \(statusCode)): \(body)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              !token.isEmpty else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "Invalid token response from AssemblyAI token endpoint."
            )
        }

        return token
    }
}

/// AssemblyAI rejects audio messages shorter than 20 ms ("Input Duration Violation") or longer than
/// 1000 ms. AVCaptureSession delivers ~5 ms buffers, so the session batches audio into 50 ms messages.
nonisolated enum AssemblyAIAudioMessageBatching {
    /// 16 kHz mono PCM16: 32 bytes per millisecond.
    private static let bytesPerMillisecondOfPCM16Audio = 16_000 * 2 / 1000
    static let minimumAudioMessageByteCount = 20 * bytesPerMillisecondOfPCM16Audio
    static let preferredAudioMessageByteCount = 50 * bytesPerMillisecondOfPCM16Audio

    /// The last message may be shorter than the 20 ms minimum; pad it with silence.
    static func finalAudioMessage(fromPendingBytes pendingBytes: Data) -> Data? {
        guard !pendingBytes.isEmpty else { return nil }
        guard pendingBytes.count < minimumAudioMessageByteCount else { return pendingBytes }
        return pendingBytes + Data(count: minimumAudioMessageByteCount - pendingBytes.count)
    }
}

private nonisolated final class AssemblyAIStreamingTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession, @unchecked Sendable {
    private struct MessageEnvelope: Decodable {
        let type: String
    }

    private struct TurnMessage: Decodable {
        let type: String
        let transcript: String?
        let turn_order: Int?
        let end_of_turn: Bool?
        let turn_is_formatted: Bool?
    }

    private struct ErrorMessage: Decodable {
        let type: String
        let error: String?
        let message: String?
    }

    private struct StoredTurnTranscript {
        var transcriptText: String
        var isFormatted: Bool
    }

    private static let websocketBaseURLString = "wss://streaming.assemblyai.com/v3/ws"
    private static let targetSampleRate = 16_000.0
    private static let explicitFinalTranscriptGracePeriodSeconds = 1.4

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.8

    private let apiKey: String?
    private let temporaryToken: String?
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.state")
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
    private let urlSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    /// PCM16 audio waiting for a full message; only touched on `sendQueue`.
    nonisolated(unsafe) private var pendingAudioPCM16Bytes = Data()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedReadyContinuation = false
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false
    private var latestTranscriptText = ""
    private var activeTurnOrder: Int?
    private var activeTurnTranscriptText = ""
    private var storedTurnTranscriptsByOrder: [Int: StoredTurnTranscript] = [:]
    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?

    init(
        apiKey: String?,
        temporaryToken: String?,
        urlSession: URLSession,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.temporaryToken = temporaryToken
        self.urlSession = urlSession
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(
            temporaryToken: temporaryToken,
            keyterms: keyterms
        )

        var websocketRequest = URLRequest(url: websocketURL)
        if let apiKey {
            websocketRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        }

        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveNextMessage()

        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
            }
        }
    }

    nonisolated func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self else { return }
            self.pendingAudioPCM16Bytes.append(audioPCM16Data)
            guard self.pendingAudioPCM16Bytes.count >= AssemblyAIAudioMessageBatching.preferredAudioMessageByteCount else { return }
            self.sendAudioMessageOnSendQueue(self.pendingAudioPCM16Bytes)
            self.pendingAudioPCM16Bytes = Data()
        }
    }

    /// Sends whatever audio is still pending before the final transcript is requested.
    nonisolated private func flushPendingAudioOnSendQueue() {
        guard let finalAudioMessage = AssemblyAIAudioMessageBatching.finalAudioMessage(fromPendingBytes: pendingAudioPCM16Bytes) else { return }
        pendingAudioPCM16Bytes = Data()
        sendAudioMessageOnSendQueue(finalAudioMessage)
    }

    nonisolated private func sendAudioMessageOnSendQueue(_ audioMessageBytes: Data) {
        guard let webSocketTask else { return }
        webSocketTask.send(.data(audioMessageBytes)) { [weak self] error in
            if let error {
                self?.failSession(with: error)
            }
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
        }

        // sendQueue is serial, so the leftover audio goes out before ForceEndpoint.
        sendQueue.async { [weak self] in
            self?.flushPendingAudioOnSendQueue()
        }
        sendJSONMessage(["type": "ForceEndpoint"])
    }

    func cancel() {
        stateQueue.async {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
        }

        sendJSONMessage(["type": "Terminate"])
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                @unknown default:
                    break
                }

                self.receiveNextMessage()
            case .failure(let error):
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }

        do {
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: messageData)

            switch envelope.type.lowercased() {
            case "begin":
                resolveReadyContinuationIfNeeded(with: .success(()))
            case "turn":
                let turnMessage = try JSONDecoder().decode(TurnMessage.self, from: messageData)
                handleTurnMessage(turnMessage)
            case "termination":
                resolveReadyContinuationIfNeeded(with: .success(()))
                stateQueue.async {
                    if self.isAwaitingExplicitFinalTranscript && !self.hasDeliveredFinalTranscript {
                        self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
                    }
                }
            case "error":
                let errorMessage = try JSONDecoder().decode(ErrorMessage.self, from: messageData)
                let messageText = errorMessage.error ?? errorMessage.message ?? "AssemblyAI returned an error."
                failSession(with: AssemblyAIStreamingTranscriptionProviderError(message: messageText))
            default:
                break
            }
        } catch {
            failSession(with: error)
        }
    }

    private func handleTurnMessage(_ turnMessage: TurnMessage) {
        let transcriptText = turnMessage.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        stateQueue.async {
            let turnOrder = turnMessage.turn_order
                ?? self.activeTurnOrder
                ?? ((self.storedTurnTranscriptsByOrder.keys.max() ?? -1) + 1)

            if turnMessage.end_of_turn == true || turnMessage.turn_is_formatted == true {
                self.activeTurnOrder = nil
                self.activeTurnTranscriptText = ""
                self.storeTurnTranscript(
                    transcriptText,
                    forTurnOrder: turnOrder,
                    isFormatted: turnMessage.turn_is_formatted == true
                )
            } else {
                self.activeTurnOrder = turnOrder
                self.activeTurnTranscriptText = transcriptText
            }

            let fullTranscriptText = self.composeFullTranscript()
            self.latestTranscriptText = fullTranscriptText

            if !fullTranscriptText.isEmpty {
                self.onTranscriptUpdate(fullTranscriptText)
            }

            guard self.isAwaitingExplicitFinalTranscript else { return }

            if turnMessage.end_of_turn == true || turnMessage.turn_is_formatted == true {
                self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
                self.explicitFinalTranscriptDeadlineWorkItem = nil
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }
    }

    private func storeTurnTranscript(
        _ transcriptText: String,
        forTurnOrder turnOrder: Int,
        isFormatted: Bool
    ) {
        guard !transcriptText.isEmpty else { return }

        if let existingTurnTranscript = storedTurnTranscriptsByOrder[turnOrder] {
            if existingTurnTranscript.isFormatted && !isFormatted {
                return
            }
        }

        storedTurnTranscriptsByOrder[turnOrder] = StoredTurnTranscript(
            transcriptText: transcriptText,
            isFormatted: isFormatted
        )
    }

    private func composeFullTranscript() -> String {
        let committedTranscriptSegments = storedTurnTranscriptsByOrder
            .sorted(by: { $0.key < $1.key })
            .map(\.value.transcriptText)
            .filter { !$0.isEmpty }

        var transcriptSegments = committedTranscriptSegments

        let trimmedActiveTurnTranscriptText = activeTurnTranscriptText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedActiveTurnTranscriptText.isEmpty {
            transcriptSegments.append(trimmedActiveTurnTranscriptText)
        }

        return transcriptSegments.joined(separator: " ")
    }

    private func scheduleExplicitFinalTranscriptDeadline() {
        explicitFinalTranscriptDeadlineWorkItem?.cancel()

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self else { return }
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }

        explicitFinalTranscriptDeadlineWorkItem = deadlineWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.explicitFinalTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        explicitFinalTranscriptDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText)
        sendJSONMessage(["type": "Terminate"])
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))
        stateQueue.async {
            let latestTranscriptText = self.bestAvailableTranscriptText()

            if self.isAwaitingExplicitFinalTranscript
                && !self.hasDeliveredFinalTranscript
                && !latestTranscriptText.isEmpty {
                print("[AssemblyAI] ⚠️ WebSocket error during active session, delivering partial transcript as fallback: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }
            print("[AssemblyAI] ❌ Session failed with error: \(error.localizedDescription)")

            self.onError(error)
        }
    }

    private func bestAvailableTranscriptText() -> String {
        let composedTranscriptText = composeFullTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !composedTranscriptText.isEmpty {
            return composedTranscriptText
        }

        return latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        stateQueue.async {
            guard !self.hasResolvedReadyContinuation else { return }
            self.hasResolvedReadyContinuation = true

            switch result {
            case .success:
                self.readyContinuation?.resume()
            case .failure(let error):
                self.readyContinuation?.resume(throwing: error)
            }

            self.readyContinuation = nil
        }
    }

    private static func makeWebsocketURL(
        temporaryToken: String?,
        keyterms: [String]
    ) throws -> URL {
        guard var websocketURLComponents = URLComponents(string: websocketBaseURLString) else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "AssemblyAI websocket URL is invalid."
            )
        }

        var queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "format_turns", value: "true"),
            URLQueryItem(name: "speech_model", value: "u3-rt-pro")
        ]

        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalizedKeyterms.isEmpty,
           let keytermsData = try? JSONSerialization.data(withJSONObject: normalizedKeyterms),
           let keytermsJSONString = String(data: keytermsData, encoding: .utf8) {
            queryItems.append(URLQueryItem(name: "keyterms_prompt", value: keytermsJSONString))
        }

        if let temporaryToken {
            queryItems.append(URLQueryItem(name: "token", value: temporaryToken))
        }

        websocketURLComponents.queryItems = queryItems

        guard let websocketURL = websocketURLComponents.url else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "AssemblyAI websocket URL could not be created."
            )
        }

        return websocketURL
    }
}
