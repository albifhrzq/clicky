//
//  UnifiedLLMClient.swift
//  leanring-buddy
//

import Foundation

public final class UnifiedLLMClient {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    public func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let config = ClickyConfiguration.shared

        switch config.mode {
        case .openCodex:
            return try await executeOpenCodexMessages(
                baseURL: config.openCodexBaseURL,
                model: config.selectedModel,
                apiKey: config.openCodexAPIKey,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )

        case .byok:
            if !config.anthropicAPIKey.isEmpty {
                // Direct Anthropic API
                return try await executeAnthropicDirect(
                    apiKey: config.anthropicAPIKey,
                    model: config.selectedModel.contains("claude") ? config.selectedModel : "claude-3-5-sonnet-20241022",
                    images: images,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    onTextChunk: onTextChunk
                )
            } else if !config.openaiAPIKey.isEmpty {
                // Direct OpenAI API
                return try await executeOpenAIDirect(
                    apiKey: config.openaiAPIKey,
                    model: config.selectedModel.contains("gpt") ? config.selectedModel : "gpt-4o",
                    images: images,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    onTextChunk: onTextChunk
                )
            } else {
                throw NSError(domain: "ClickyLLM", code: 401, userInfo: [NSLocalizedDescriptionKey: "No API Key configured for BYOK mode. Please add your Anthropic or OpenAI key in Settings."])
            }

        case .cloudflareWorker:
            return try await executeWorkerProxy(
                workerURL: "\(config.workerBaseURL)/chat",
                model: config.selectedModel,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )

        case .nativeAntigravity:
            guard let token = AntigravityOAuthManager.shared.currentAccessToken else {
                throw NSError(domain: "ClickyLLM", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated with Google Antigravity. Please login first in Settings."])
            }
            return try await executeNativeAntigravity(
                accessToken: token,
                model: config.selectedModel,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                onTextChunk: onTextChunk
            )
        }
    }

    // MARK: - OpenCodex / Anthropic Wire Format SSE Execution

    private func executeOpenCodexMessages(
        baseURL: String,
        model: String,
        apiKey: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let endpoint = "\(baseURL)/messages"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let messagesPayload = buildAnthropicMessagesPayload(
            model: model,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: messagesPayload)

        return try await streamAnthropicSSE(request: request, onTextChunk: onTextChunk)
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

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        for turn in conversationHistory {
            messages.append(["role": "user", "content": turn.userPlaceholder])
            messages.append(["role": "assistant", "content": turn.assistantResponse])
        }

        var userContent: [[String: Any]] = []
        userContent.append(["type": "text", "text": userPrompt])
        for img in images {
            let base64 = img.data.base64EncodedString()
            userContent.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
            ])
        }
        messages.append(["role": "user", "content": userContent])

        let payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "max_tokens": 4096
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        return try await streamOpenAISSE(request: request, onTextChunk: onTextChunk)
    }

    // MARK: - Cloudflare Worker Proxy

    private func executeWorkerProxy(
        workerURL: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        guard let url = URL(string: workerURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Pass BYOK keys in headers if available
        let config = ClickyConfiguration.shared
        if !config.anthropicAPIKey.isEmpty {
            request.setValue(config.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        }

        let messagesPayload = buildAnthropicMessagesPayload(
            model: model,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: messagesPayload)

        return try await streamAnthropicSSE(request: request, onTextChunk: onTextChunk)
    }

    // MARK: - Native Antigravity Execution

    private func executeNativeAntigravity(
        accessToken: String,
        model: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let endpoint = "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateCode"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("antigravity/ide/2.5.5", forHTTPHeaderField: "User-Agent")

        let project = AntigravityOAuthManager.shared.currentProjectNumber ?? "cloudcode-pa-users"
        var contents: [[String: Any]] = []

        for turn in conversationHistory {
            contents.append(["role": "user", "parts": [["text": turn.userPlaceholder]]])
            contents.append(["role": "model", "parts": [["text": turn.assistantResponse]]])
        }

        var currentParts: [[String: Any]] = [["text": userPrompt]]
        for img in images {
            currentParts.append([
                "inlineData": [
                    "mimeType": "image/jpeg",
                    "data": img.data.base64EncodedString()
                ]
            ])
        }
        contents.append(["role": "user", "parts": currentParts])

        let payload: [String: Any] = [
            "project": project,
            "model": model.replacingOccurrences(of: "google-antigravity/", with: ""),
            "contents": contents,
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 4096
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        return try await streamAntigravitySSE(request: request, onTextChunk: onTextChunk)
    }

    // MARK: - Helpers & SSE Decoders

    private func buildAnthropicMessagesPayload(
        model: String,
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
            userContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": img.data.base64EncodedString()
                ]
            ])
            userContent.append(["type": "text", "text": "Display: \(img.label)"])
        }
        userContent.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": userContent])

        return [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": messages,
            "stream": true
        ]
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
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let responseObj = obj["response"] as? [String: Any] ?? obj as? [String: Any],
                  let candidates = responseObj["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                continue
            }

            for part in parts {
                if let text = part["text"] as? String {
                    fullText += text
                    await onTextChunk(text)
                }
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return (fullText, duration)
    }
}
