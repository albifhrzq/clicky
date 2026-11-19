//
//  UnifiedLLMClient.swift
//  leanring-buddy
//

import Foundation

@MainActor
public final class UnifiedLLMClient {
    public static let shared = UnifiedLLMClient()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Detects image MIME type by inspecting magic bytes (PNG `89 50 4E 47` -> `image/png`, else `image/jpeg`).
    nonisolated public static func detectImageMediaType(for data: Data) -> String {
        if data.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](data.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    /// Completes a text-only prompt using the active connection mode and returns the full response string.
    public func completeText(
        systemPrompt: String,
        userPrompt: String,
        modelOverride: String? = nil
    ) async throws -> String {
        let result = try await analyzeImageStreaming(
            images: [],
            systemPrompt: systemPrompt,
            conversationHistory: [],
            userPrompt: userPrompt,
            modelOverride: modelOverride,
            onTextChunk: { _ in }
        )
        return result.text
    }

    public func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        modelOverride: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let config = ClickyConfiguration.shared
        let trimmedOverride = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetModel = (trimmedOverride?.isEmpty == false) ? trimmedOverride! : config.selectedModel

        switch config.mode {
        case .openCodex:
            return try await executeOpenCodex(
                baseURL: config.openCodexBaseURL,
                model: targetModel,
                apiKey: config.openCodexAPIKey,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )

        case .byok:
            return try await executeBYOK(
                config: config,
                requestedModel: targetModel,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )

        case .cloudflareWorker:
            return try await executeWorkerProxy(
                workerBaseURL: config.workerBaseURL,
                model: targetModel,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )

        case .nativeAntigravity:
            let accessToken = try await AntigravityOAuthManager.shared.refreshAccessTokenIfNeeded()
            return try await executeNativeAntigravity(
                accessToken: accessToken,
                model: targetModel,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }
    }

    // MARK: - OpenCodex Routing (/v1/messages vs /v1/chat/completions)

    private func shouldUseOpenCodexAnthropicMessages(for model: String) -> Bool {
        let lowercased = model.lowercased()

        // Explicit OpenAI, Gemini, and Ollama models route through /v1/chat/completions.
        if lowercased.hasPrefix("openai/")
            || lowercased.hasPrefix("gpt-")
            || lowercased.hasPrefix("google-antigravity/gemini-")
            || lowercased.hasPrefix("google-antigravity/gpt-")
            || lowercased.hasPrefix("ollama-cloud/")
            || lowercased.hasPrefix("o1")
            || lowercased.hasPrefix("o3")
            || lowercased.hasPrefix("o4") {
            return false
        }

        // Explicit Anthropic/Claude models route through /v1/messages.
        if lowercased.hasPrefix("anthropic/")
            || lowercased.hasPrefix("claude-")
            || lowercased.hasPrefix("google-antigravity/claude-") {
            return true
        }

        // Fall back to advertised api_types from /v1/models when available.
        if let modelInfo = OpenCodexService.shared.modelInfo(for: model),
           !modelInfo.apiTypes.isEmpty {
            if modelInfo.apiTypes.first == "anthropic_messages" {
                return true
            }
            if modelInfo.apiTypes.contains("anthropic_messages") && !modelInfo.apiTypes.contains("chat_completions") {
                return true
            }
        }

        return false
    }

    private func executeOpenCodex(
        baseURL: String,
        model: String,
        apiKey: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let modelInfo = OpenCodexService.shared.modelInfo(for: model)
        let maxTokens = min(max(4096, modelInfo?.maxOutputTokens ?? 8192), 32768)

        if shouldUseOpenCodexAnthropicMessages(for: model) {
            guard let url = OpenCodexService.apiEndpointURL(fromBaseURL: baseURL, suffix: "/messages") else {
                throw URLError(.badURL)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue(apiKey, forHTTPHeaderField: "x-opencodex-api-key")
            }

            let messagesPayload = buildAnthropicMessagesPayload(
                model: model,
                maxTokens: maxTokens,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                images: images,
                userPrompt: userPrompt
            )
            request.httpBody = try JSONSerialization.data(withJSONObject: messagesPayload)

            return try await streamAnthropicSSE(request: request, onTextChunk: onTextChunk)
        } else {
            guard let url = OpenCodexService.apiEndpointURL(fromBaseURL: baseURL, suffix: "/chat/completions") else {
                throw URLError(.badURL)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue(apiKey, forHTTPHeaderField: "x-opencodex-api-key")
            }

            let payload = buildOpenAIChatCompletionsPayload(
                model: model,
                maxTokens: maxTokens,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                images: images,
                userPrompt: userPrompt,
                useMaxCompletionTokens: false
            )
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            return try await streamOpenAISSE(request: request, onTextChunk: onTextChunk)
        }
    }

    // MARK: - BYOK Routing (Anthropic, OpenAI, Gemini)

    private func executeBYOK(
        config: ClickyConfiguration,
        requestedModel: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let lowercased = requestedModel.lowercased()
        let anthropicKey = config.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let openaiKey = config.openaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let geminiKey = config.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if lowercased.contains("gemini") && !geminiKey.isEmpty {
            return try await executeGeminiDirect(
                apiKey: geminiKey,
                model: normalizedDirectGeminiModel(requestedModel),
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }

        if (lowercased.contains("gpt") || lowercased.hasPrefix("openai/") || lowercased.hasPrefix("o1") || lowercased.hasPrefix("o3") || lowercased.hasPrefix("o4")) && !openaiKey.isEmpty {
            return try await executeOpenAIDirect(
                apiKey: openaiKey,
                model: normalizedDirectOpenAIModel(requestedModel),
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }

        if lowercased.contains("claude") && !anthropicKey.isEmpty {
            return try await executeAnthropicDirect(
                apiKey: anthropicKey,
                model: normalizedDirectAnthropicModel(requestedModel),
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }

        if !anthropicKey.isEmpty {
            return try await executeAnthropicDirect(
                apiKey: anthropicKey,
                model: normalizedDirectAnthropicModel(requestedModel),
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }

        if !openaiKey.isEmpty {
            return try await executeOpenAIDirect(
                apiKey: openaiKey,
                model: normalizedDirectOpenAIModel(requestedModel),
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }

        if !geminiKey.isEmpty {
            return try await executeGeminiDirect(
                apiKey: geminiKey,
                model: normalizedDirectGeminiModel(requestedModel),
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }

        throw NSError(
            domain: "ClickyLLM",
            code: 401,
            userInfo: [
                NSLocalizedDescriptionKey: "No API Key configured for BYOK mode. Please add your Anthropic, OpenAI, or Gemini key in Settings."
            ]
        )
    }

    private func normalizedDirectAnthropicModel(_ model: String) -> String {
        let stripped = model
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: "google-antigravity/", with: "")
        return stripped.lowercased().contains("claude") ? stripped : "claude-sonnet-4-6"
    }

    private func normalizedDirectOpenAIModel(_ model: String) -> String {
        let stripped = model.replacingOccurrences(of: "openai/", with: "")
        let lowercased = stripped.lowercased()
        if lowercased.contains("gpt") || lowercased.hasPrefix("o1") || lowercased.hasPrefix("o3") || lowercased.hasPrefix("o4") {
            return stripped
        }
        return "gpt-4o"
    }

    private func normalizedDirectGeminiModel(_ model: String) -> String {
        let stripped = model
            .replacingOccurrences(of: "google-antigravity/", with: "")
            .replacingOccurrences(of: "google/", with: "")
        return stripped.lowercased().contains("gemini") ? stripped : "gemini-2.5-flash"
    }

    // MARK: - Direct Anthropic API

    private func executeAnthropicDirect(
        apiKey: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let messagesPayload = buildAnthropicMessagesPayload(
            model: model,
            maxTokens: 8192,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: messagesPayload)

        return try await streamAnthropicSSE(request: request, onTextChunk: onTextChunk)
    }

    // MARK: - Direct OpenAI Chat Completions

    private func executeOpenAIDirect(
        apiKey: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload = buildOpenAIChatCompletionsPayload(
            model: model,
            maxTokens: 8192,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt,
            useMaxCompletionTokens: true
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        return try await streamOpenAISSE(request: request, onTextChunk: onTextChunk)
    }

    // MARK: - Direct Gemini BYOK API

    private func executeGeminiDirect(
        apiKey: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escapedModel):streamGenerateContent?alt=sse") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let payload = buildGeminiRequestPayload(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        return try await streamAntigravitySSE(request: request, onTextChunk: onTextChunk)
    }

    // MARK: - Cloudflare Worker Proxy

    private func executeWorkerProxy(
        workerBaseURL: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let trimmed = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            throw URLError(.badURL)
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasSuffix("/chat") {
            path += "/chat"
        }
        components.path = path
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let config = ClickyConfiguration.shared
        if !config.anthropicAPIKey.isEmpty {
            request.setValue(config.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        }

        let messagesPayload = buildAnthropicMessagesPayload(
            model: normalizedDirectAnthropicModel(model),
            maxTokens: 4096,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: messagesPayload)

        return try await streamAnthropicSSE(request: request, onTextChunk: onTextChunk)
    }

    // MARK: - Native Antigravity Cloud Code Assist Execution

    private func executeNativeAntigravity(
        accessToken: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let endpoint = "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")

        let project = AntigravityOAuthManager.shared.currentProjectNumber ?? "cloudcode-pa-users"
        let normalizedModel = model.replacingOccurrences(of: "google-antigravity/", with: "")
        let innerRequest = buildGeminiRequestPayload(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt
        )

        let payload: [String: Any] = [
            "model": normalizedModel,
            "userAgent": "antigravity",
            "requestType": "agent",
            "project": project,
            "requestId": "agent-\(UUID().uuidString.lowercased())",
            "request": innerRequest
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        return try await streamAntigravitySSE(request: request, onTextChunk: onTextChunk)
    }

    // MARK: - Helpers & SSE Decoders

    private func buildAnthropicMessagesPayload(
        model: String,
        maxTokens: Int,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> [String: Any] {
        var messages: [[String: Any]] = []

        for turn in conversationHistory {
            messages.append(["role": "user", "content": [["type": "text", "text": turn.userPlaceholder]]])
            messages.append(["role": "assistant", "content": [["type": "text", "text": turn.assistantResponse]]])
        }

        var userContent: [[String: Any]] = []
        for img in images {
            let mediaType = Self.detectImageMediaType(for: img.data)
            userContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": img.data.base64EncodedString()
                ]
            ])
            userContent.append(["type": "text", "text": "Display: \(img.label)"])
        }
        userContent.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": userContent])

        var payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
            "stream": true
        ]
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["system"] = systemPrompt
        }
        return payload
    }

    private func buildOpenAIChatCompletionsPayload(
        model: String,
        maxTokens: Int,
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        images: [(data: Data, label: String)],
        userPrompt: String,
        useMaxCompletionTokens: Bool
    ) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }

        for turn in conversationHistory {
            messages.append(["role": "user", "content": turn.userPlaceholder])
            messages.append(["role": "assistant", "content": turn.assistantResponse])
        }

        if images.isEmpty {
            messages.append(["role": "user", "content": userPrompt])
        } else {
            var userContent: [[String: Any]] = []
            for img in images {
                let mediaType = Self.detectImageMediaType(for: img.data)
                let base64 = img.data.base64EncodedString()
                userContent.append(["type": "text", "text": "Display: \(img.label)"])
                userContent.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mediaType);base64,\(base64)"]
                ])
            }
            userContent.append(["type": "text", "text": userPrompt])
            messages.append(["role": "user", "content": userContent])
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]
        if useMaxCompletionTokens {
            payload["max_completion_tokens"] = maxTokens
        } else {
            payload["max_tokens"] = maxTokens
        }
        return payload
    }

    private func buildGeminiRequestPayload(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> [String: Any] {
        var contents: [[String: Any]] = []

        for turn in conversationHistory {
            contents.append(["role": "user", "parts": [["text": turn.userPlaceholder]]])
            contents.append(["role": "model", "parts": [["text": turn.assistantResponse]]])
        }

        var currentParts: [[String: Any]] = []
        for img in images {
            currentParts.append(["text": "Display: \(img.label)"])
            currentParts.append([
                "inlineData": [
                    "mimeType": Self.detectImageMediaType(for: img.data),
                    "data": img.data.base64EncodedString()
                ]
            ])
        }
        currentParts.append(["text": userPrompt])
        contents.append(["role": "user", "parts": currentParts])

        var payload: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 8192
            ]
        ]
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["systemInstruction"] = ["parts": [["text": systemPrompt]]]
        }
        return payload
    }

    private func streamAnthropicSSE(
        request: URLRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw NSError(domain: "ClickyLLM", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "LLM Provider Error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        var fullText = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            if jsonString == "[DONE]" { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if ClickySafetyFilterDetector.isAnthropicRefusal(obj) { throw ClickySafetyFilterError() }

            // Handle content_block_delta
            if let type = obj["type"] as? String, type == "content_block_delta",
               let delta = obj["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                fullText += text
                await onTextChunk(text)
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return (fullText, duration)
    }

    private func streamOpenAISSE(
        request: URLRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw NSError(domain: "ClickyLLM", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenAI Error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        var fullText = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            if jsonString == "[DONE]" { break }

            if let filterData = jsonString.data(using: .utf8),
               let filterObject = try? JSONSerialization.jsonObject(with: filterData) as? [String: Any],
               ClickySafetyFilterDetector.isOpenAIContentFilter(filterObject) {
                throw ClickySafetyFilterError()
            }

            guard let jsonData = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let content = delta["content"] as? String else {
                continue
            }

            fullText += content
            await onTextChunk(content)
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return (fullText, duration)
    }

    private func streamAntigravitySSE(
        request: URLRequest,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw NSError(domain: "ClickyLLM", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Antigravity Error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        var fullText = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let jsonData = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }
            let responseObj = (obj["response"] as? [String: Any]) ?? obj
            if ClickySafetyFilterDetector.isGeminiSafetyBlock(responseObj) { throw ClickySafetyFilterError() }
            guard let candidates = responseObj["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                continue
            }

            for part in parts {
                if (part["thought"] as? Bool) == true {
                    continue
                }
                if let text = part["text"] as? String, !text.isEmpty {
                    fullText += text
                    await onTextChunk(text)
                }
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return (fullText, duration)
    }
}
