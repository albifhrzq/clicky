//
//  ClickyLocalAgentShim.swift
//  leanring-buddy
//

import Foundation
import Combine
import Network

private nonisolated struct ShimRoutingSnapshot: Sendable {
    let mode: ClickyConnectionMode
    let openCodexBaseURL: String
    let openCodexAPIKey: String
    let openaiAPIKey: String
    let anthropicAPIKey: String
    let braveAPIKey: String
    let workerBaseURL: String
    let selectedModel: String
}

private nonisolated struct ParsedHTTPRequest: Sendable {
    let method: String
    let path: String
    let queryString: String?
    let headers: [String: String]
    let body: Data

    func headerValue(named name: String) -> String? {
        headers[name.lowercased()]
    }
}

public nonisolated enum ClickyLocalAgentShimError: LocalizedError, Sendable {
    case failedToStart(String)
    case missingPort

    public var errorDescription: String? {
        switch self {
        case .failedToStart(let reason):
            return "Failed to start ClickyLocalAgentShim: \(reason)"
        case .missingPort:
            return "ClickyLocalAgentShim listener started without an assigned port."
        }
    }
}

@MainActor
public final class ClickyLocalAgentShim: ObservableObject {
    public static let shared = ClickyLocalAgentShim()

    @Published public private(set) var port: UInt16?
    public var sessionToken: String

    private var server: LocalAgentShimHTTPServer?
    private var startTask: Task<URL, Error>?

    private init() {
        self.sessionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func ensureStarted() async throws -> URL {
        if let port, let url = URL(string: "http://127.0.0.1:\(port)") {
            return url
        }

        if let existingTask = startTask {
            return try await existingTask.value
        }

        let token = self.sessionToken
        let task = Task<URL, Error> { [weak self] in
            let httpServer = LocalAgentShimHTTPServer(
                sessionToken: token,
                snapshotProvider: {
                    await MainActor.run {
                        ClickyLocalAgentShim.captureRoutingSnapshot()
                    }
                }
            )
            let boundPort = try await httpServer.start()
            guard let self else {
                httpServer.stop()
                throw ClickyLocalAgentShimError.failedToStart("Shim deallocated during startup.")
            }
            self.server = httpServer
            self.port = boundPort
            guard let url = URL(string: "http://127.0.0.1:\(boundPort)") else {
                throw ClickyLocalAgentShimError.missingPort
            }
            return url
        }

        self.startTask = task
        do {
            let url = try await task.value
            self.startTask = nil
            return url
        } catch {
            self.startTask = nil
            throw error
        }
    }

    public func stop() {
        startTask?.cancel()
        startTask = nil
        server?.stop()
        server = nil
        port = nil
    }

    private static func captureRoutingSnapshot() -> ShimRoutingSnapshot {
        let config = ClickyConfiguration.shared
        let braveKeyFromKeychain = ClickyKeychainStore.read(key: "clicky_brave_api_key") ?? ""
        let braveKeyFromEnv = ProcessInfo.processInfo.environment["CLICKY_BRAVE_API_KEY"] ?? ""
        let effectiveBraveKey = braveKeyFromKeychain.isEmpty ? braveKeyFromEnv : braveKeyFromKeychain
        let persistedAgentModel = UserDefaults.standard.string(forKey: "clicky_selected_agent_model") ?? ""
        let effectiveModel = persistedAgentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.selectedModel
            : persistedAgentModel

        return ShimRoutingSnapshot(
            mode: config.mode,
            openCodexBaseURL: config.openCodexBaseURL,
            openCodexAPIKey: config.openCodexAPIKey,
            openaiAPIKey: config.openaiAPIKey,
            anthropicAPIKey: config.anthropicAPIKey,
            braveAPIKey: effectiveBraveKey,
            workerBaseURL: config.workerBaseURL,
            selectedModel: effectiveModel
        )
    }
}

// MARK: - Nonisolated Network Server & Streaming Proxy

private nonisolated final class LocalAgentShimHTTPServer: @unchecked Sendable {
    private let sessionToken: String
    private let snapshotProvider: @Sendable () async -> ShimRoutingSnapshot
    private let queue = DispatchQueue(label: "com.clicky.local-agent-shim", qos: .userInitiated)
    private let urlSession: URLSession

    private var listener: NWListener?
    private let stateLock = NSLock()
    private var startupContinuation: CheckedContinuation<UInt16, Error>?
    private var hasCompletedStartup = false

    init(
        sessionToken: String,
        snapshotProvider: @escaping @Sendable () async -> ShimRoutingSnapshot
    ) {
        self.sessionToken = sessionToken
        self.snapshotProvider = snapshotProvider

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 1800
        config.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: config)
    }

    func start() async throws -> UInt16 {
        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            self.startupContinuation = continuation
            self.hasCompletedStartup = false
            stateLock.unlock()

            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host("127.0.0.1"),
                    port: .any
                )

                let newListener = try NWListener(using: parameters)
                newListener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state, listener: newListener)
                }
                newListener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection: connection)
                }

                self.listener = newListener
                newListener.start(queue: queue)
            } catch {
                self.completeStartup(with: .failure(error))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        urlSession.invalidateAndCancel()
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            if let assignedPort = listener.port?.rawValue, assignedPort > 0 {
                completeStartup(with: .success(assignedPort))
            } else {
                completeStartup(with: .failure(ClickyLocalAgentShimError.missingPort))
            }
        case .failed(let error):
            completeStartup(with: .failure(ClickyLocalAgentShimError.failedToStart(error.localizedDescription)))
        case .cancelled:
            completeStartup(with: .failure(ClickyLocalAgentShimError.failedToStart("Listener cancelled before becoming ready.")))
        default:
            break
        }
    }

    private func completeStartup(with result: Result<UInt16, Error>) {
        stateLock.lock()
        guard !hasCompletedStartup, let continuation = startupContinuation else {
            stateLock.unlock()
            return
        }
        hasCompletedStartup = true
        startupContinuation = nil
        stateLock.unlock()
        continuation.resume(with: result)
    }

    private func accept(connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(on: connection, accumulatedData: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                _ = error
                connection.cancel()
                return
            }

            var buffer = accumulatedData
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            switch self.tryParseHTTPRequest(from: buffer) {
            case .complete(let request):
                Task.detached { [weak self] in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    await self.handleRequest(request, on: connection)
                }
            case .incomplete:
                if isComplete {
                    self.sendJSONResponse(
                        on: connection,
                        statusCode: 400,
                        payload: ["error": "Incomplete HTTP request"]
                    )
                } else {
                    self.receiveHTTPRequest(on: connection, accumulatedData: buffer)
                }
            case .invalid(let reason):
                self.sendJSONResponse(
                    on: connection,
                    statusCode: 400,
                    payload: ["error": reason]
                )
            }
        }
    }

    private enum ParseOutcome {
        case complete(ParsedHTTPRequest)
        case incomplete
        case invalid(String)
    }

    private func tryParseHTTPRequest(from buffer: Data) -> ParseOutcome {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerEndRange = buffer.range(of: separator) else {
            if buffer.count > 1_048_576 {
                return .invalid("HTTP headers too large")
            }
            return .incomplete
        }

        let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .invalid("Invalid UTF-8 in HTTP headers")
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .invalid("Missing HTTP request line")
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return .invalid("Malformed HTTP request line")
        }

        let method = String(requestParts[0]).uppercased()
        let rawTarget = String(requestParts[1])
        let targetComponents = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(targetComponents[0])
        let queryString = targetComponents.count > 1 ? String(targetComponents[1]) : nil

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStartIndex = headerEndRange.upperBound
        let remainingData = buffer.subdata(in: bodyStartIndex..<buffer.count)

        if let transferEncoding = headers["transfer-encoding"]?.lowercased(),
           transferEncoding.contains("chunked") {
            switch decodeChunkedBody(from: remainingData) {
            case .complete(let decodedBody):
                return .complete(ParsedHTTPRequest(
                    method: method,
                    path: path,
                    queryString: queryString,
                    headers: headers,
                    body: decodedBody
                ))
            case .incomplete:
                return .incomplete
            case .invalid(let reason):
                return .invalid(reason)
            }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if remainingData.count < contentLength {
            return .incomplete
        }

        let body = contentLength > 0 ? remainingData.subdata(in: 0..<contentLength) : Data()
        return .complete(ParsedHTTPRequest(
            method: method,
            path: path,
            queryString: queryString,
            headers: headers,
            body: body
        ))
    }

    private enum ChunkedDecodeOutcome {
        case complete(Data)
        case incomplete
        case invalid(String)
    }

    private func decodeChunkedBody(from data: Data) -> ChunkedDecodeOutcome {
        var decoded = Data()
        var cursor = 0
        let crlf = Data([0x0D, 0x0A])

        while true {
            guard let lineRange = data.range(of: crlf, in: cursor..<data.count) else {
                return .incomplete
            }
            let sizeLineData = data.subdata(in: cursor..<lineRange.lowerBound)
            guard let sizeLineString = String(data: sizeLineData, encoding: .utf8) else {
                return .invalid("Invalid chunk size header")
            }
            let hexPart = sizeLineString.split(separator: ";", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
            guard let chunkSize = Int(hexPart, radix: 16) else {
                return .invalid("Malformed chunk size: \(hexPart)")
            }
            cursor = lineRange.upperBound

            if chunkSize == 0 {
                if data.count < cursor + 2 {
                    return .incomplete
                }
                return .complete(decoded)
            }

            if data.count < cursor + chunkSize + 2 {
                return .incomplete
            }
            decoded.append(data.subdata(in: cursor..<(cursor + chunkSize)))
            cursor += chunkSize + 2
        }
    }

    // MARK: - Route Dispatch

    private func handleRequest(_ request: ParsedHTTPRequest, on connection: NWConnection) async {
        // Verify local bearer token when provided or required
        let authHeader = request.headerValue(named: "authorization") ?? ""
        if authHeader != "Bearer \(sessionToken)" {
            sendJSONResponse(on: connection, statusCode: 401, payload: ["error": "unauthorized"])
            return
        }

        let snapshot = await snapshotProvider()

        switch (request.method, request.path) {
        case ("POST", "/agent/openai/v1/responses"),
             ("POST", "/agent/openai/v1/responses/compact"):
            await proxyOpenAIResponses(request: request, snapshot: snapshot, on: connection)

        case ("POST", "/agent/anthropic/v1/messages"):
            await proxyAnthropicMessages(request: request, snapshot: snapshot, on: connection)

        case ("GET", "/agent/web-search"):
            sendJSONResponse(on: connection, statusCode: 200, payload: ["available": true])

        case ("POST", "/agent/web-search"):
            await handleWebSearch(request: request, snapshot: snapshot, on: connection)

        case ("POST", "/codex-thread-launch"):
            let bodyJSON = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let threadID = (bodyJSON["threadId"] as? String)
                ?? (bodyJSON["thread_id"] as? String)
                ?? UUID().uuidString
            sendJSONResponse(
                on: connection,
                statusCode: 200,
                payload: ["ok": true, "threadId": threadID, "local": true]
            )

        case ("POST", "/codex-thread-title"):
            let title = generateLocalThreadTitle(from: request.body)
            sendJSONResponse(
                on: connection,
                statusCode: 200,
                payload: ["ok": true, "title": title]
            )

        case ("GET", "/agent-messages"), ("POST", "/agent-messages"):
            sendJSONResponse(
                on: connection,
                statusCode: 200,
                payload: ["ok": true, "messages": []]
            )

        case ("POST", "/agent/record-agent-launch"):
            sendJSONResponse(
                on: connection,
                statusCode: 200,
                payload: ["ok": true, "recorded": true, "unlimited": true]
            )

        case ("GET", "/me/plan"):
            sendJSONResponse(
                on: connection,
                statusCode: 200,
                payload: [
                    "plan": "local",
                    "tier": "unlimited",
                    "unlimited": true,
                    "remainingTurns": 999_999,
                    "hasActiveSubscription": true
                ]
            )

        default:
            if request.method == "POST" && request.path.hasPrefix("/agent/turn-lease/") {
                sendJSONResponse(
                    on: connection,
                    statusCode: 200,
                    payload: [
                        "ok": true,
                        "granted": true,
                        "leaseId": UUID().uuidString,
                        "unlimited": true
                    ]
                )
                return
            }
            sendJSONResponse(
                on: connection,
                statusCode: 404,
                payload: ["error": "Not found: \(request.method) \(request.path)"]
            )
        }
    }

    // MARK: - OpenAI Responses Proxy

    private func proxyOpenAIResponses(
        request: ParsedHTTPRequest,
        snapshot: ShimRoutingSnapshot,
        on connection: NWConnection
    ) async {
        let isCompact = request.path.hasSuffix("/compact")
        let suffix = isCompact ? "/responses/compact" : "/responses"

        let targetURLString: String
        var authHeaderValue: String?

        switch snapshot.mode {
        case .openCodex:
            let base = trimTrailingSlash(snapshot.openCodexBaseURL)
            targetURLString = "\(base)\(suffix)"
            if !snapshot.openCodexAPIKey.isEmpty {
                authHeaderValue = "Bearer \(snapshot.openCodexAPIKey)"
            }
        case .byok:
            if !snapshot.openaiAPIKey.isEmpty {
                targetURLString = "https://api.openai.com/v1\(suffix)"
                authHeaderValue = "Bearer \(snapshot.openaiAPIKey)"
            } else {
                sendJSONResponse(
                    on: connection,
                    statusCode: 401,
                    payload: ["error": "OpenAI API key is not configured for BYOK mode."]
                )
                return
            }
        case .cloudflareWorker:
            let base = trimTrailingSlash(snapshot.workerBaseURL)
            targetURLString = "\(base)/agent/openai/v1\(suffix)"
            authHeaderValue = request.headerValue(named: "authorization")
        case .nativeAntigravity:
            let base = trimTrailingSlash(snapshot.openCodexBaseURL)
            targetURLString = "\(base)\(suffix)"
            if !snapshot.openCodexAPIKey.isEmpty {
                authHeaderValue = "Bearer \(snapshot.openCodexAPIKey)"
            }
        }

        guard let targetURL = URL(string: targetURLString) else {
            sendJSONResponse(on: connection, statusCode: 400, payload: ["error": "Invalid upstream OpenAI URL: \(targetURLString)"])
            return
        }

        let rewrittenBody = rewriteJSONBody(request.body) { json in
            if let requestedModel = json["model"] as? String {
                json["model"] = translateModelForOpenAI(requestedModel, snapshot: snapshot)
            }
        }

        var upstreamRequest = URLRequest(url: targetURL)
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.httpBody = rewrittenBody
        upstreamRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accept = request.headerValue(named: "accept") {
            upstreamRequest.setValue(accept, forHTTPHeaderField: "Accept")
        }
        if let authHeaderValue, !authHeaderValue.isEmpty {
            upstreamRequest.setValue(authHeaderValue, forHTTPHeaderField: "Authorization")
        }

        streamUpstreamResponse(upstreamRequest: upstreamRequest, to: connection)
    }

    // MARK: - Anthropic Messages Proxy

    private func proxyAnthropicMessages(
        request: ParsedHTTPRequest,
        snapshot: ShimRoutingSnapshot,
        on connection: NWConnection
    ) async {
        let targetURLString: String
        var bearerToken: String?
        var xAPIKey: String?

        switch snapshot.mode {
        case .openCodex:
            let base = trimTrailingSlash(snapshot.openCodexBaseURL)
            targetURLString = "\(base)/messages"
            if !snapshot.openCodexAPIKey.isEmpty {
                bearerToken = snapshot.openCodexAPIKey
            }
        case .byok:
            if !snapshot.anthropicAPIKey.isEmpty {
                targetURLString = "https://api.anthropic.com/v1/messages"
                xAPIKey = snapshot.anthropicAPIKey
            } else {
                sendJSONResponse(
                    on: connection,
                    statusCode: 401,
                    payload: ["error": "Anthropic API key is not configured for BYOK mode."]
                )
                return
            }
        case .cloudflareWorker:
            let base = trimTrailingSlash(snapshot.workerBaseURL)
            targetURLString = "\(base)/agent/anthropic/v1/messages"
            if !snapshot.anthropicAPIKey.isEmpty {
                xAPIKey = snapshot.anthropicAPIKey
            } else {
                bearerToken = sessionToken
            }
        case .nativeAntigravity:
            let base = trimTrailingSlash(snapshot.openCodexBaseURL)
            targetURLString = "\(base)/messages"
            if !snapshot.openCodexAPIKey.isEmpty {
                bearerToken = snapshot.openCodexAPIKey
            }
        }

        guard let targetURL = URL(string: targetURLString) else {
            sendJSONResponse(on: connection, statusCode: 400, payload: ["error": "Invalid upstream Anthropic URL: \(targetURLString)"])
            return
        }

        let isDirectAnthropic = targetURLString.contains("api.anthropic.com")
        let rewrittenBody = rewriteJSONBody(request.body) { json in
            if let requestedModel = json["model"] as? String {
                json["model"] = translateModelForAnthropic(
                    requestedModel,
                    stripProviderPrefix: isDirectAnthropic
                )
            }
        }

        var upstreamRequest = URLRequest(url: targetURL)
        upstreamRequest.httpMethod = "POST"
        upstreamRequest.httpBody = rewrittenBody
        upstreamRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstreamRequest.setValue(
            request.headerValue(named: "anthropic-version") ?? "2023-06-01",
            forHTTPHeaderField: "anthropic-version"
        )
        if let anthropicBeta = request.headerValue(named: "anthropic-beta") {
            upstreamRequest.setValue(anthropicBeta, forHTTPHeaderField: "anthropic-beta")
        }
        if let accept = request.headerValue(named: "accept") {
            upstreamRequest.setValue(accept, forHTTPHeaderField: "Accept")
        }
        if let xAPIKey, !xAPIKey.isEmpty {
            upstreamRequest.setValue(xAPIKey, forHTTPHeaderField: "x-api-key")
        } else if let bearerToken, !bearerToken.isEmpty {
            upstreamRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        streamUpstreamResponse(upstreamRequest: upstreamRequest, to: connection)
    }

    // MARK: - Web Search Proxy (OpenCodex /v1/alpha/search + Brave fallback)

    private func handleWebSearch(
        request: ParsedHTTPRequest,
        snapshot: ShimRoutingSnapshot,
        on connection: NWConnection
    ) async {
        let bodyJSON = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        let query = (bodyJSON["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            sendJSONResponse(on: connection, statusCode: 400, payload: ["error": "query is empty"])
            return
        }
        let count = min(10, max(1, (bodyJSON["count"] as? NSNumber)?.intValue ?? 8))
        let freshness = bodyJSON["freshness"] as? String

        // 1. Try OpenCodex /alpha/search first when configured
        let openCodexBase = trimTrailingSlash(snapshot.openCodexBaseURL)
        if (snapshot.mode == .openCodex || snapshot.mode == .nativeAntigravity),
           let searchURL = URL(string: "\(openCodexBase)/alpha/search") {
            var searchRequest = URLRequest(url: searchURL)
            searchRequest.httpMethod = "POST"
            searchRequest.timeoutInterval = 15
            searchRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !snapshot.openCodexAPIKey.isEmpty {
                searchRequest.setValue("Bearer \(snapshot.openCodexAPIKey)", forHTTPHeaderField: "Authorization")
            }

            var payload: [String: Any] = ["query": query, "count": count]
            if let freshness, !freshness.isEmpty {
                payload["freshness"] = freshness
            }
            searchRequest.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            if let (data, response) = try? await urlSession.data(for: searchRequest),
               let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let normalized = normalizeOpenCodexSearchResponse(data) {
                sendJSONResponse(on: connection, statusCode: 200, payload: normalized)
                return
            }
        }

        // 2. Fallback to Brave Search API if configured
        if !snapshot.braveAPIKey.isEmpty,
           var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search") {
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "extra_snippets", value: "true"),
                URLQueryItem(name: "safesearch", value: "moderate")
            ]
            if let freshness, !freshness.isEmpty {
                queryItems.append(URLQueryItem(name: "freshness", value: freshness))
            }
            components.queryItems = queryItems

            if let braveURL = components.url {
                var braveRequest = URLRequest(url: braveURL)
                braveRequest.httpMethod = "GET"
                braveRequest.timeoutInterval = 15
                braveRequest.setValue(snapshot.braveAPIKey, forHTTPHeaderField: "X-Subscription-Token")
                braveRequest.setValue("application/json", forHTTPHeaderField: "Accept")

                if let (data, response) = try? await urlSession.data(for: braveRequest),
                   let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode),
                   let normalized = normalizeBraveSearchResponse(data, limit: count) {
                    sendJSONResponse(on: connection, statusCode: 200, payload: normalized)
                    return
                }
            }
        }

        // 3. Graceful empty response if neither OpenCodex search nor Brave is available
        sendJSONResponse(
            on: connection,
            statusCode: 200,
            payload: [
                "results": [],
                "text": "No web search results available for \"\(query)\"."
            ]
        )
    }

    private func normalizeOpenCodexSearchResponse(_ data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if json["results"] != nil || json["text"] != nil {
            return json
        }
        if let items = json["data"] as? [[String: Any]] ?? json["items"] as? [[String: Any]] {
            let mapped = items.map { item -> [String: Any] in
                var entry: [String: Any] = [
                    "title": item["title"] as? String ?? (item["url"] as? String ?? ""),
                    "url": item["url"] as? String ?? ""
                ]
                if let snippet = item["snippet"] as? String ?? item["description"] as? String ?? item["text"] as? String {
                    entry["highlights"] = [snippet]
                }
                if let age = item["publishedDate"] as? String ?? item["age"] as? String {
                    entry["age"] = age
                }
                return entry
            }
            return ["results": mapped]
        }
        return nil
    }

    private func normalizeBraveSearchResponse(_ data: Data, limit: Int) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else {
            return nil
        }

        let mapped = results.prefix(limit).map { item -> [String: Any] in
            var highlights: [String] = []
            if let description = item["description"] as? String, !description.isEmpty {
                highlights.append(description)
            }
            if let extraSnippets = item["extra_snippets"] as? [String] {
                highlights.append(contentsOf: extraSnippets.prefix(2))
            }
            var entry: [String: Any] = [
                "title": item["title"] as? String ?? "",
                "url": item["url"] as? String ?? "",
                "highlights": highlights
            ]
            if let age = item["age"] as? String {
                entry["age"] = age
            }
            return entry
        }
        return ["results": mapped]
    }

    // MARK: - Model Translation & Helpers

    private func translateModelForOpenAI(_ model: String, snapshot: ShimRoutingSnapshot) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let heyClickyInternalOpenAIModels: Set<String> = [
            "gpt-6-luna",
            "gpt-6-sol",
            "gpt-6.1-sol",
            "gpt-6.1-terra",
            "gpt-6-astra"
        ]

        let resolved: String
        if heyClickyInternalOpenAIModels.contains(trimmed) || trimmed.isEmpty {
            if snapshot.mode == .byok {
                resolved = snapshot.selectedModel.contains("gpt") ? snapshot.selectedModel : "gpt-4.1"
            } else {
                resolved = snapshot.selectedModel.isEmpty ? "gpt-5.2" : snapshot.selectedModel
            }
        } else {
            resolved = trimmed
        }

        if snapshot.mode == .byok && resolved.hasPrefix("openai/") {
            return String(resolved.dropFirst("openai/".count))
        }
        return resolved
    }

    private func translateModelForAnthropic(_ model: String, stripProviderPrefix: Bool) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliasMap: [String: String] = [
            "claude-opus-5-5": "claude-opus-4-6",
            "claude-sonnet-5-5": "claude-sonnet-4-6",
            "claude-haiku-5-5": "claude-haiku-4-5",
            "claude-fable-5-1": "claude-sonnet-4-6"
        ]
        var resolved = aliasMap[trimmed] ?? trimmed
        if stripProviderPrefix && resolved.hasPrefix("anthropic/") {
            resolved = String(resolved.dropFirst("anthropic/".count))
        }
        return resolved
    }

    private func generateLocalThreadTitle(from body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return "New Thread"
        }

        var candidate = (json["prompt"] as? String)
            ?? (json["text"] as? String)
            ?? (json["input"] as? String)
            ?? ""

        if candidate.isEmpty, let messages = json["messages"] as? [[String: Any]] {
            for message in messages {
                if let content = message["content"] as? String, !content.isEmpty {
                    candidate = content
                    break
                }
            }
        }

        let firstLine = candidate
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "New Thread"

        if firstLine.count <= 60 {
            return firstLine
        }
        let endIndex = firstLine.index(firstLine.startIndex, offsetBy: 57)
        return "\(firstLine[..<endIndex])..."
    }

    private func rewriteJSONBody(_ body: Data, mutate: (inout [String: Any]) -> Void) -> Data {
        guard !body.isEmpty,
              var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return body
        }
        mutate(&json)
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }

    private func trimTrailingSlash(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    // MARK: - HTTP Response Writers

    private func streamUpstreamResponse(upstreamRequest: URLRequest, to connection: NWConnection) {
        StreamingProxyDelegate.start(
            upstreamRequest: upstreamRequest,
            connection: connection,
            queue: queue,
            retryNumber: 0
        )
    }

    private func sendJSONResponse(on connection: NWConnection, statusCode: Int, payload: [String: Any]) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        let headerString = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(headerString.utf8)
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private nonisolated final class StreamingProxyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var hasSentHeaders = false
    private var hasClosed = false
    private let upstreamRequest: URLRequest
    private let retryNumber: Int
    /// Set when an upstream outage response was cancelled and a retry must run once the task completes.
    private var pendingRetryDelaySeconds: TimeInterval?
    var retainedSession: URLSession?

    init(connection: NWConnection, queue: DispatchQueue, upstreamRequest: URLRequest, retryNumber: Int) {
        self.connection = connection
        self.queue = queue
        self.upstreamRequest = upstreamRequest
        self.retryNumber = retryNumber
    }

    /// Starts one upstream attempt. On a 5xx/529 the attempt is dropped before any byte reaches the
    /// client and a new one is scheduled with backoff, so the runner never sees the outage.
    static func start(
        upstreamRequest: URLRequest,
        connection: NWConnection,
        queue: DispatchQueue,
        retryNumber: Int
    ) {
        let delegate = StreamingProxyDelegate(
            connection: connection,
            queue: queue,
            upstreamRequest: upstreamRequest,
            retryNumber: retryNumber
        )
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 1800
        let streamSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        delegate.retainedSession = streamSession
        streamSession.dataTask(with: upstreamRequest).resume()
    }

    private static func publishRetryStatus(_ status: ClickyModelRetryStatus?) {
        Task { @MainActor in
            ClickyJobStore.shared.setModelRetryStatus(status)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 200

        if ClickyModelRetryPolicy.shouldRetry(statusCode: statusCode),
           let retryDelaySeconds = ClickyModelRetryPolicy.delaySeconds(forRetry: retryNumber + 1) {
            stateLock.lock()
            pendingRetryDelaySeconds = retryDelaySeconds
            stateLock.unlock()
            Self.publishRetryStatus(
                ClickyModelRetryStatus(attempt: retryNumber + 1, maximum: ClickyModelRetryPolicy.maximumRetryCount)
            )
            completionHandler(.cancel)
            return
        }
        if retryNumber > 0 {
            // Recovered, or retries ran out and the failure is passed through: stop showing "reconnecting".
            Self.publishRetryStatus(nil)
        }

        let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"

        var headerLines = [
            "HTTP/1.1 \(statusCode) \(reason)",
            "Content-Type: \(contentType)",
            "Transfer-Encoding: chunked",
            "Cache-Control: no-cache",
            "Connection: close"
        ]
        if let gzipHeader = httpResponse?.value(forHTTPHeaderField: "x-clicky-accepts-gzip") {
            headerLines.append("x-clicky-accepts-gzip: \(gzipHeader)")
        }
        let headerData = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        stateLock.lock()
        hasSentHeaders = true
        stateLock.unlock()

        queue.async { [weak self] in
            self?.connection.send(content: headerData, completion: .idempotent)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        var chunk = Data("\(String(data.count, radix: 16))\r\n".utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))

        queue.async { [weak self] in
            self?.connection.send(content: chunk, completion: .idempotent)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        let retryDelaySeconds = pendingRetryDelaySeconds
        stateLock.unlock()

        if let retryDelaySeconds {
            let nextRetryNumber = retryNumber + 1
            let request = upstreamRequest
            let clientConnection = connection
            let workQueue = queue
            retainedSession?.finishTasksAndInvalidate()
            retainedSession = nil
            workQueue.asyncAfter(deadline: .now() + retryDelaySeconds) {
                // The client may have gone away during the backoff; don't start an upstream call nobody reads.
                switch clientConnection.state {
                case .cancelled, .failed:
                    Self.publishRetryStatus(nil)
                    return
                default:
                    break
                }
                Self.start(
                    upstreamRequest: request,
                    connection: clientConnection,
                    queue: workQueue,
                    retryNumber: nextRetryNumber
                )
            }
            return
        }

        if retryNumber > 0 {
            // Final attempt finished (success, error or cancel): clear the "reconnecting" status.
            Self.publishRetryStatus(nil)
        }

        stateLock.lock()
        let sentHeaders = hasSentHeaders
        let alreadyClosed = hasClosed
        hasClosed = true
        stateLock.unlock()

        guard !alreadyClosed else {
            retainedSession?.finishTasksAndInvalidate()
            retainedSession = nil
            return
        }

        if let error, !sentHeaders {
            let errorPayload = (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription]))
                ?? Data("{\"error\":\"Upstream request failed\"}".utf8)
            let header = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: \(errorPayload.count)\r\nConnection: close\r\n\r\n"
            var responseData = Data(header.utf8)
            responseData.append(errorPayload)

            queue.async { [weak self] in
                guard let self else { return }
                self.connection.send(content: responseData, completion: .contentProcessed { _ in
                    self.connection.cancel()
                })
                self.retainedSession?.finishTasksAndInvalidate()
                self.retainedSession = nil
            }
            return
        }

        let endChunk = Data("0\r\n\r\n".utf8)
        queue.async { [weak self] in
            guard let self else { return }
            self.connection.send(content: endChunk, completion: .contentProcessed { _ in
                self.connection.cancel()
            })
            self.retainedSession?.finishTasksAndInvalidate()
            self.retainedSession = nil
        }
    }
}
