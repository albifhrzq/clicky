//
//  RealtimeVoiceClient.swift
//  leanring-buddy
//
//  Duplex WebSocket client for OpenAI Realtime (gpt-realtime-2.1) and
//  Gemini Live Bidi (BidiGenerateContent) audio/text streaming.
//

import Foundation

public enum RealtimeVoiceProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case gemini = "gemini"

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI Realtime"
        case .gemini: return "Gemini Live"
        }
    }
}

public struct RealtimeVoiceSessionConfiguration: Sendable {
    public let provider: RealtimeVoiceProvider
    public let apiKey: String
    public let voiceID: String
    public let languageCode: String
    public let instructions: String
    public let speechSpeed: Double

    public init(
        provider: RealtimeVoiceProvider,
        apiKey: String,
        voiceID: String,
        languageCode: String,
        instructions: String,
        speechSpeed: Double = 1.0
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.languageCode = languageCode
        self.instructions = instructions
        self.speechSpeed = speechSpeed
    }
}

public enum RealtimeVoiceClientEvent: Sendable {
    case connected(provider: RealtimeVoiceProvider)
    case inputAudioSpeechStarted
    case inputAudioSpeechStopped
    case userTranscriptDelta(String)
    case userTranscriptCompleted(String)
    case assistantResponseStarted
    case assistantAudioDelta(Data, sampleRate: Int)
    case assistantTranscriptDelta(String)
    case assistantTranscriptCompleted(String)
    case assistantResponseCompleted
    case toolCallRequested(RealtimeToolCall)
    case error(String)
    case disconnected(reason: String?)
}

public nonisolated struct RealtimeToolCall: Sendable, Equatable {
    public let callID: String
    public let name: String
    public let arguments: [String: String]
}

/// Pure builders/parsers for the realtime function-calling wire formats (testable without a socket).
/// Serializes realtime tool calls: one in flight at a time, and at most one
/// use_screen and one start_background_job per user utterance.
public nonisolated struct RealtimeToolCallGate: Equatable {
    public static let busyMessage = "busy: one thing at a time, say it to the user"
    private(set) var isToolInFlight = false
    private var useScreenCallsThisUtterance = 0
    private var backgroundJobCallsThisUtterance = 0

    public init() {}

    /// Returns nil when the call may run (and marks it in flight), otherwise the text to return to the model.
    public mutating func admit(toolName: String) -> String? {
        if isToolInFlight { return Self.busyMessage }
        switch toolName {
        case RealtimeToolSupport.useScreenToolName:
            if useScreenCallsThisUtterance >= 1 { return Self.busyMessage }
            useScreenCallsThisUtterance += 1
        case RealtimeToolSupport.startBackgroundJobToolName:
            if backgroundJobCallsThisUtterance >= 1 { return Self.busyMessage }
            backgroundJobCallsThisUtterance += 1
        default:
            break
        }
        isToolInFlight = true
        return nil
    }

    public mutating func finishToolCall() { isToolInFlight = false }

    /// Call when a new user transcript completes.
    public mutating func resetForNewUtterance() {
        useScreenCallsThisUtterance = 0
        backgroundJobCallsThisUtterance = 0
    }

    public mutating func resetAll() { self = RealtimeToolCallGate() }
}

public nonisolated enum RealtimeToolSupport {
    public static let useScreenToolName = "use_screen"
    public static let startBackgroundJobToolName = "start_background_job"

    private static let useScreenDescription = "Look at the user's screen and answer, point at, or draw on what they asked. Use for anything about what's on screen, pointing at an element, or drawing/diagrams."
    private static let startBackgroundJobDescription = "Start a background agent job for work that takes a while."

    private static func schema(parameterName: String, parameterDescription: String) -> [String: Any] {
        [
            "type": "object",
            "properties": [parameterName: ["type": "string", "description": parameterDescription]],
            "required": [parameterName]
        ]
    }

    private static var toolDefinitions: [(name: String, description: String, parameters: [String: Any])] {
        [
            (useScreenToolName, useScreenDescription,
             schema(parameterName: "request", parameterDescription: "What the user asked, in their words.")),
            (startBackgroundJobToolName, startBackgroundJobDescription,
             schema(parameterName: "task", parameterDescription: "The task for the background agent, fully self-contained."))
        ]
    }

    public static func openAIToolDeclarations() -> [[String: Any]] {
        toolDefinitions.map {
            ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters]
        }
    }

    public static func geminiToolDeclarations() -> [[String: Any]] {
        [["functionDeclarations": toolDefinitions.map {
            ["name": $0.name, "description": $0.description, "parameters": $0.parameters] as [String: Any]
        }]]
    }

    /// OpenAI `response.function_call_arguments.done` -> call.
    public static func parseOpenAIToolCall(from json: [String: Any]) -> RealtimeToolCall? {
        guard json["type"] as? String == "response.function_call_arguments.done",
              let callID = json["call_id"] as? String,
              let name = json["name"] as? String else { return nil }
        var arguments: [String: String] = [:]
        if let raw = json["arguments"] as? String,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = stringify(object)
        }
        return RealtimeToolCall(callID: callID, name: name, arguments: arguments)
    }

    /// Gemini Live `toolCall.functionCalls[]` -> calls.
    public static func parseGeminiToolCalls(from json: [String: Any]) -> [RealtimeToolCall] {
        guard let toolCall = json["toolCall"] as? [String: Any],
              let functionCalls = toolCall["functionCalls"] as? [[String: Any]] else { return [] }
        return functionCalls.compactMap { functionCall in
            guard let callID = functionCall["id"] as? String,
                  let name = functionCall["name"] as? String else { return nil }
            let arguments = (functionCall["args"] as? [String: Any]).map(stringify) ?? [:]
            return RealtimeToolCall(callID: callID, name: name, arguments: arguments)
        }
    }

    /// OpenAI: the output item to create, followed by a `response.create`.
    public static func openAIToolResultMessages(callID: String, output: String) -> [[String: Any]] {
        [
            ["type": "conversation.item.create",
             "item": ["type": "function_call_output", "call_id": callID, "output": output]],
            ["type": "response.create"]
        ]
    }

    public static func geminiToolResultMessage(callID: String, name: String, output: String) -> [String: Any] {
        ["toolResponse": ["functionResponses": [["id": callID, "name": name, "response": ["result": output]]]]]
    }

    private static func stringify(_ object: [String: Any]) -> [String: String] {
        object.reduce(into: [:]) { result, pair in
            result[pair.key] = (pair.value as? String) ?? "\(pair.value)"
        }
    }
}

public enum RealtimeVoiceClientError: LocalizedError {
    case missingAPIKey(RealtimeVoiceProvider)
    case invalidEndpointURL
    case connectionClosed(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Missing API key for \(provider.displayName)."
        case .invalidEndpointURL:
            return "Failed to construct realtime WebSocket endpoint URL."
        case .connectionClosed(let reason):
            return "Realtime WebSocket connection closed: \(reason)"
        case .protocolError(let detail):
            return "Realtime protocol error: \(detail)"
        }
    }
}

public nonisolated final class RealtimeVoiceClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private static let openAIRealtimeURLString = "https://api.openai.com/v1/realtime?model=gpt-realtime-2.1"
    private static let openAIRealtimeWSSString = "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1"
    private static let geminiLiveWSSBase = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    private static let geminiLiveModel = "models/gemini-2.5-flash-native-audio-preview-09-2025"

    private let stateQueue = DispatchQueue(label: "com.clicky.realtime-voice-client.state")
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var activeConfiguration: RealtimeVoiceSessionConfiguration?
    private var eventHandler: (@MainActor @Sendable (RealtimeVoiceClientEvent) -> Void)?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedConnectContinuation = false
    private var isDisconnected = false

    public var inputSampleRate: Double {
        stateQueue.sync {
            switch activeConfiguration?.provider {
            case .gemini:
                return 16_000.0
            case .openAI, .none:
                return 24_000.0
            }
        }
    }

    public func connect(
        configuration: RealtimeVoiceSessionConfiguration,
        onEvent: @MainActor @Sendable @escaping (RealtimeVoiceClientEvent) -> Void
    ) async throws {
        let trimmedKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw RealtimeVoiceClientError.missingAPIKey(configuration.provider)
        }

        disconnect()

        let request = try Self.makeWebSocketRequest(for: configuration, trimmedKey: trimmedKey)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async {
                self.isDisconnected = false
                self.activeConfiguration = configuration
                self.eventHandler = onEvent
                self.connectContinuation = continuation
                self.hasResolvedConnectContinuation = false

                let sessionConfig = URLSessionConfiguration.default
                sessionConfig.timeoutIntervalForRequest = 30
                sessionConfig.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
                self.urlSession = session

                let task = session.webSocketTask(with: request)
                self.webSocketTask = task
                task.resume()
                self.receiveNextMessage()
            }
        }
    }

    public func sendInputAudioPCM16(_ pcmData: Data, sampleRate: Int) {
        guard !pcmData.isEmpty else { return }

        let provider: RealtimeVoiceProvider? = stateQueue.sync {
            guard !isDisconnected else { return nil }
            return activeConfiguration?.provider
        }
        guard let provider else { return }

        let base64Audio = pcmData.base64EncodedString()

        switch provider {
        case .openAI:
            sendJSON([
                "type": "input_audio_buffer.append",
                "audio": base64Audio
            ])
        case .gemini:
            sendJSON([
                "realtimeInput": [
                    "mediaChunks": [
                        [
                            "mimeType": "audio/pcm;rate=\(sampleRate)",
                            "data": base64Audio
                        ]
                    ]
                ]
            ])
        }
    }

    public func commitInputAudioAndRequestResponse() {
        let provider: RealtimeVoiceProvider? = stateQueue.sync {
            guard !isDisconnected else { return nil }
            return activeConfiguration?.provider
        }
        guard let provider else { return }

        switch provider {
        case .openAI:
            sendJSON(["type": "input_audio_buffer.commit"])
            sendJSON(["type": "response.create"])
        case .gemini:
            sendJSON([
                "realtimeInput": [
                    "audioStreamEnd": true
                ]
            ])
        }
    }

    public func sendTextTurn(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let provider: RealtimeVoiceProvider? = stateQueue.sync {
            guard !isDisconnected else { return nil }
            return activeConfiguration?.provider
        }
        guard let provider else { return }

        switch provider {
        case .openAI:
            sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": trimmedText
                        ]
                    ]
                ]
            ])
            sendJSON(["type": "response.create"])
        case .gemini:
            sendJSON([
                "clientContent": [
                    "turns": [
                        [
                            "role": "user",
                            "parts": [
                                ["text": trimmedText]
                            ]
                        ]
                    ],
                    "turnComplete": true
                ]
            ])
        }
    }

    public func interruptResponse() {
        let provider: RealtimeVoiceProvider? = stateQueue.sync {
            guard !isDisconnected else { return nil }
            return activeConfiguration?.provider
        }
        guard let provider else { return }

        if provider == .openAI {
            sendJSON(["type": "response.cancel"])
        }
    }

    public func disconnect() {
        stateQueue.sync {
            isDisconnected = true
            resolveConnectContinuationIfNeeded(with: .failure(CancellationError()))
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            urlSession?.invalidateAndCancel()
            urlSession = nil
            activeConfiguration = nil
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let config: RealtimeVoiceSessionConfiguration? = stateQueue.sync {
            guard !isDisconnected, self.webSocketTask === webSocketTask else { return nil }
            return activeConfiguration
        }
        guard let config else { return }

        sendInitialSetup(for: config)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "closeCode=\(closeCode.rawValue)"
        let shouldEmitDisconnect: Bool = stateQueue.sync {
            guard !isDisconnected, self.webSocketTask === webSocketTask else { return false }
            isDisconnected = true
            resolveConnectContinuationIfNeeded(
                with: .failure(RealtimeVoiceClientError.connectionClosed(reasonText))
            )
            return true
        }
        if shouldEmitDisconnect {
            emitEvent(.disconnected(reason: reasonText))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let shouldEmitError: Bool = stateQueue.sync {
            guard !isDisconnected else { return false }
            isDisconnected = true
            resolveConnectContinuationIfNeeded(with: .failure(error))
            return true
        }
        if shouldEmitError {
            emitEvent(.error(error.localizedDescription))
            emitEvent(.disconnected(reason: error.localizedDescription))
        }
    }

    // MARK: - Setup & Messaging

    private func sendInitialSetup(for configuration: RealtimeVoiceSessionConfiguration) {
        switch configuration.provider {
        case .openAI:
            let openAIVoice = VoiceLanguageCatalog.openAIVoiceName(forSelectedID: configuration.voiceID)
            var transcriptionConfig: [String: Any] = [
                "model": "gpt-4o-transcribe"
            ]
            let trimmedLang = configuration.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLang.isEmpty && trimmedLang.lowercased() != "auto" {
                transcriptionConfig["language"] = trimmedLang
            }

            let sessionPayload: [String: Any] = [
                "modalities": ["audio", "text"],
                "instructions": Self.buildInstructions(base: configuration.instructions, languageCode: configuration.languageCode),
                "voice": openAIVoice,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": transcriptionConfig,
                "tools": RealtimeToolSupport.openAIToolDeclarations(),
                "tool_choice": "auto",
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ]
            ]

            sendJSON([
                "type": "session.update",
                "session": sessionPayload
            ])
            resolveConnectContinuationIfNeeded(with: .success(()))
            emitEvent(.connected(provider: .openAI))

        case .gemini:
            let geminiVoice = VoiceLanguageCatalog.geminiVoiceName(forSelectedID: configuration.voiceID)
            let fullInstructions = Self.buildInstructions(
                base: configuration.instructions,
                languageCode: configuration.languageCode
            )

            let setupPayload: [String: Any] = [
                "setup": [
                    "model": Self.geminiLiveModel,
                    "generationConfig": [
                        "responseModalities": ["AUDIO"],
                        "speechConfig": [
                            "voiceConfig": [
                                "prebuiltVoiceConfig": [
                                    "voiceName": geminiVoice
                                ]
                            ]
                        ]
                    ],
                    "systemInstruction": [
                        "parts": [
                            ["text": fullInstructions]
                        ]
                    ],
                    "tools": RealtimeToolSupport.geminiToolDeclarations(),
                    "inputAudioTranscription": [String: Any](),
                    "outputAudioTranscription": [String: Any]()
                ]
            ]
            sendJSON(setupPayload)
        }
    }

    private func receiveNextMessage() {
        let task: URLSessionWebSocketTask? = stateQueue.sync {
            guard !isDisconnected else { return nil }
            return webSocketTask
        }
        guard let task else { return }

        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self.handleIncomingPayload(data)
                    }
                case .data(let data):
                    self.handleIncomingPayload(data)
                @unknown default:
                    break
                }
                self.receiveNextMessage()

            case .failure(let error):
                let shouldEmit: Bool = self.stateQueue.sync {
                    guard !self.isDisconnected else { return false }
                    self.isDisconnected = true
                    self.resolveConnectContinuationIfNeeded(with: .failure(error))
                    return true
                }
                if shouldEmit {
                    self.emitEvent(.error(error.localizedDescription))
                    self.emitEvent(.disconnected(reason: error.localizedDescription))
                }
            }
        }
    }

    private func handleIncomingPayload(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let provider: RealtimeVoiceProvider? = stateQueue.sync { activeConfiguration?.provider }
        guard let provider else { return }

        switch provider {
        case .openAI:
            handleOpenAIPayload(json)
        case .gemini:
            handleGeminiPayload(json)
        }
    }

    private func handleOpenAIPayload(_ json: [String: Any]) {
        guard let eventType = json["type"] as? String else { return }

        switch eventType {
        case "session.created", "session.updated":
            resolveConnectContinuationIfNeeded(with: .success(()))

        case "input_audio_buffer.speech_started":
            emitEvent(.inputAudioSpeechStarted)

        case "input_audio_buffer.speech_stopped":
            emitEvent(.inputAudioSpeechStopped)

        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                emitEvent(.userTranscriptDelta(delta))
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                emitEvent(.userTranscriptCompleted(transcript))
            }

        case "response.created":
            emitEvent(.assistantResponseStarted)

        case "response.audio.delta", "response.output_audio.delta":
            if let base64Delta = json["delta"] as? String,
               let pcmData = Data(base64Encoded: base64Delta),
               !pcmData.isEmpty {
                emitEvent(.assistantAudioDelta(pcmData, sampleRate: 24_000))
            }

        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String, !delta.isEmpty {
                emitEvent(.assistantTranscriptDelta(delta))
            }

        case "response.audio_transcript.done", "response.output_audio_transcript.done":
            if let transcript = json["transcript"] as? String {
                emitEvent(.assistantTranscriptCompleted(transcript))
            }

        case "response.function_call_arguments.done":
            if let toolCall = RealtimeToolSupport.parseOpenAIToolCall(from: json) {
                emitEvent(.toolCallRequested(toolCall))
            }

        case "response.done":
            emitEvent(.assistantResponseCompleted)

        case "error":
            let errorDict = json["error"] as? [String: Any]
            let errorMessage = (errorDict?["message"] as? String)
                ?? (json["message"] as? String)
                ?? "OpenAI Realtime error"
            resolveConnectContinuationIfNeeded(
                with: .failure(RealtimeVoiceClientError.protocolError(errorMessage))
            )
            emitEvent(.error(errorMessage))

        default:
            break
        }
    }

    private func handleGeminiPayload(_ json: [String: Any]) {
        if json["setupComplete"] != nil {
            resolveConnectContinuationIfNeeded(with: .success(()))
            emitEvent(.connected(provider: .gemini))
            return
        }

        if let errorDict = json["error"] as? [String: Any] {
            let message = (errorDict["message"] as? String) ?? "Gemini Live API error"
            resolveConnectContinuationIfNeeded(
                with: .failure(RealtimeVoiceClientError.protocolError(message))
            )
            emitEvent(.error(message))
            return
        }

        for toolCall in RealtimeToolSupport.parseGeminiToolCalls(from: json) {
            emitEvent(.toolCallRequested(toolCall))
        }

        guard let serverContent = json["serverContent"] as? [String: Any] else { return }

        if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
            emitEvent(.inputAudioSpeechStarted)
            emitEvent(.assistantResponseCompleted)
        }

        if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String,
           !text.isEmpty {
            emitEvent(.userTranscriptDelta(text))
        }

        if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String,
           !text.isEmpty {
            emitEvent(.assistantTranscriptDelta(text))
        }

        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            emitEvent(.assistantResponseStarted)
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty {
                    emitEvent(.assistantTranscriptDelta(text))
                }
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.lowercased().hasPrefix("audio/pcm"),
                   let base64Audio = inlineData["data"] as? String,
                   let pcmData = Data(base64Encoded: base64Audio),
                   !pcmData.isEmpty {
                    let sampleRate = Self.parseSampleRate(fromMimeType: mimeType) ?? 24_000
                    emitEvent(.assistantAudioDelta(pcmData, sampleRate: sampleRate))
                }
            }
        }

        if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
            emitEvent(.assistantResponseCompleted)
        }
    }

    /// Sends a tool result back and asks the model to continue (OpenAI needs an explicit response.create).
    public func sendToolResult(_ call: RealtimeToolCall, output: String) {
        let provider: RealtimeVoiceProvider? = stateQueue.sync { activeConfiguration?.provider }
        switch provider {
        case .openAI:
            RealtimeToolSupport.openAIToolResultMessages(callID: call.callID, output: output).forEach(sendJSON)
        case .gemini:
            sendJSON(RealtimeToolSupport.geminiToolResultMessage(callID: call.callID, name: call.name, output: output))
        case .none:
            break
        }
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        let task: URLSessionWebSocketTask? = stateQueue.sync {
            guard !isDisconnected else { return nil }
            return webSocketTask
        }
        guard let task else { return }

        task.send(.string(jsonString)) { [weak self] error in
            guard let self, let error else { return }
            let shouldReport: Bool = self.stateQueue.sync { !self.isDisconnected }
            if shouldReport {
                self.emitEvent(.error(error.localizedDescription))
            }
        }
    }

    private func resolveConnectContinuationIfNeeded(with result: Result<Void, Error>) {
        guard !hasResolvedConnectContinuation else { return }
        hasResolvedConnectContinuation = true
        let continuation = connectContinuation
        connectContinuation = nil
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func emitEvent(_ event: RealtimeVoiceClientEvent) {
        let handler: (@MainActor @Sendable (RealtimeVoiceClientEvent) -> Void)? = stateQueue.sync {
            eventHandler
        }
        guard let handler else { return }
        Task { @MainActor in
            handler(event)
        }
    }

    // MARK: - Helpers

    private static func makeWebSocketRequest(
        for configuration: RealtimeVoiceSessionConfiguration,
        trimmedKey: String
    ) throws -> URLRequest {
        switch configuration.provider {
        case .openAI:
            guard let url = URL(string: openAIRealtimeWSSString) else {
                throw RealtimeVoiceClientError.invalidEndpointURL
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
            return request

        case .gemini:
            var components = URLComponents(string: geminiLiveWSSBase)
            components?.queryItems = [URLQueryItem(name: "key", value: trimmedKey)]
            guard let url = components?.url else {
                throw RealtimeVoiceClientError.invalidEndpointURL
            }
            return URLRequest(url: url)
        }
    }

    private static func buildInstructions(base: String, languageCode: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLang = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLang.isEmpty, trimmedLang.lowercased() != "auto" else {
            return trimmedBase
        }
        let languageName = VoiceLanguageCatalog.language(forCode: trimmedLang)?.name ?? trimmedLang
        if trimmedBase.isEmpty {
            return "Always understand and respond naturally in \(languageName) (\(trimmedLang))."
        }
        return "\(trimmedBase)\n\nLanguage preference: Always respond naturally in \(languageName) (\(trimmedLang))."
    }

    private static func parseSampleRate(fromMimeType mimeType: String) -> Int? {
        let parts = mimeType.split(separator: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.hasPrefix("rate="),
               let rateValue = Int(trimmed.dropFirst(5)) {
                return rateValue
            }
        }
        return nil
    }
}
