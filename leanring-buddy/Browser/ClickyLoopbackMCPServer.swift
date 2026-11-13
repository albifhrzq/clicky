//
//  ClickyLoopbackMCPServer.swift
//  leanring-buddy
//
//  Local HTTP JSON-RPC 2.0 MCP server on 127.0.0.1:0 for ClickyBrowserHost
//  and local agent tools (browser_poll, browser_reply, upload_approval,
//  mac_step, repeat_this_job, find_jobs, read_job, note*, reveal_artifact).
//

import AppKit
import Foundation
import Network
import Security

// MARK: - Sendable JSON Containers

nonisolated public struct ClickyMCPToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    public func toDictionary() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }
}

nonisolated public struct ClickyMCPToolResult: @unchecked Sendable {
    public let content: [[String: Any]]
    public let structuredContent: [String: Any]
    public let isError: Bool

    public init(
        content: [[String: Any]]? = nil,
        structuredContent: [String: Any] = [:],
        isError: Bool = false
    ) {
        self.structuredContent = structuredContent
        self.isError = isError
        if let content {
            self.content = content
        } else if let jsonData = try? JSONSerialization.data(withJSONObject: structuredContent, options: [.sortedKeys]),
                  let jsonText = String(data: jsonData, encoding: .utf8) {
            self.content = [["type": "text", "text": jsonText]]
        } else {
            self.content = [["type": "text", "text": "{}"]]
        }
    }

    public static func text(_ message: String, structuredContent: [String: Any] = [:], isError: Bool = false) -> ClickyMCPToolResult {
        var mergedStructured = structuredContent
        if mergedStructured.isEmpty {
            mergedStructured = isError ? ["error": message] : ["message": message]
        }
        return ClickyMCPToolResult(
            content: [["type": "text", "text": message]],
            structuredContent: mergedStructured,
            isError: isError
        )
    }

    public static func error(_ message: String, extra: [String: Any] = [:]) -> ClickyMCPToolResult {
        var structured = extra
        structured["error"] = message
        return ClickyMCPToolResult(
            content: [["type": "text", "text": message]],
            structuredContent: structured,
            isError: true
        )
    }
}

// MARK: - Loopback HTTP Transport

nonisolated public enum ClickyLoopbackServerError: LocalizedError {
    case listenerFailed(Error)
    case listenerTimedOut
    case missingPort

    public var errorDescription: String? {
        switch self {
        case .listenerFailed(let error):
            return "Loopback HTTP listener failed: \(error.localizedDescription)"
        case .listenerTimedOut:
            return "Loopback HTTP listener timed out waiting to become ready."
        case .missingPort:
            return "Loopback HTTP listener did not resolve a local port."
        }
    }
}

nonisolated private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false

    func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasFired { return false }
        hasFired = true
        return true
    }
}

nonisolated private final class ClickyLoopbackHTTPServer: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: @unchecked Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        static func json(status: Int, object: Any) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
            return Response(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
    }

    private let bearerToken: String
    private let path: String
    private let queue = DispatchQueue(label: "com.humansongs.clicky.loopback-mcp", qos: .userInitiated)
    private let handler: @Sendable (Request) async -> Response
    private let lock = NSLock()
    private var listener: NWListener?
    private var resolvedPort: UInt16?
    private var openConnections: [ObjectIdentifier: NWConnection] = [:]

    init(
        bearerToken: String,
        path: String = "/mcp",
        handler: @escaping @Sendable (Request) async -> Response
    ) {
        self.bearerToken = bearerToken
        self.path = path
        self.handler = handler
    }

    func start() throws -> UInt16 {
        lock.lock()
        if let existingPort = resolvedPort {
            lock.unlock()
            return existingPort
        }
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        parameters.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: parameters)
        let readySemaphore = DispatchSemaphore(value: 0)
        let onceFlag = OnceFlag()
        var startResult: Result<UInt16, Error> = .failure(ClickyLoopbackServerError.listenerTimedOut)

        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let portValue = newListener.port?.rawValue, portValue > 0 {
                    if onceFlag.tryFire() {
                        startResult = .success(portValue)
                        readySemaphore.signal()
                    }
                } else if onceFlag.tryFire() {
                    startResult = .failure(ClickyLoopbackServerError.missingPort)
                    readySemaphore.signal()
                }
            case .failed(let error):
                if onceFlag.tryFire() {
                    startResult = .failure(ClickyLoopbackServerError.listenerFailed(error))
                    readySemaphore.signal()
                }
                self?.stop()
            case .cancelled:
                if onceFlag.tryFire() {
                    startResult = .failure(ClickyLoopbackServerError.missingPort)
                    readySemaphore.signal()
                }
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        lock.lock()
        self.listener = newListener
        lock.unlock()

        newListener.start(queue: queue)

        let waitResult = readySemaphore.wait(timeout: .now() + 5.0)
        if waitResult == .timedOut {
            stop()
            throw ClickyLoopbackServerError.listenerTimedOut
        }

        let port = try startResult.get()
        lock.lock()
        self.resolvedPort = port
        lock.unlock()
        return port
    }

    func stop() {
        lock.lock()
        let activeListener = listener
        listener = nil
        resolvedPort = nil
        let connections = Array(openConnections.values)
        openConnections.removeAll()
        lock.unlock()

        activeListener?.cancel()
        for connection in connections {
            connection.cancel()
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        openConnections[identifier] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeConnection(identifier)
            default:
                break
            }
        }

        connection.start(queue: queue)
        readHTTPRequest(on: connection, accumulatedData: Data())
    }

    private func removeConnection(_ identifier: ObjectIdentifier) {
        lock.lock()
        openConnections.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func readHTTPRequest(on connection: NWConnection, accumulatedData: Data) {
        let maxRequestBytes = 16 * 1024 * 1024
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                self.removeConnection(ObjectIdentifier(connection))
                return
            }

            var buffer = accumulatedData
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
            }

            if buffer.count > maxRequestBytes {
                self.sendHTTPResponse(
                    Response.json(status: 400, object: ["error": "Request too large"]),
                    on: connection
                )
                return
            }

            if let parsedRequest = self.parseCompleteHTTPRequest(from: buffer) {
                self.dispatchParsedRequest(parsedRequest, on: connection)
                return
            }

            if isComplete {
                self.sendHTTPResponse(
                    Response.json(status: 400, object: ["error": "Incomplete HTTP request"]),
                    on: connection
                )
                return
            }

            self.readHTTPRequest(on: connection, accumulatedData: buffer)
        }
    }

    private func parseCompleteHTTPRequest(from data: Data) -> Request? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let headerRange = data.range(of: separator) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return nil
        }

        let method = String(requestParts[0]).uppercased()
        let rawPath = String(requestParts[1])
        let cleanPath = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStartIndex = headerRange.upperBound
        let availableBodyBytes = data.count - bodyStartIndex
        if availableBodyBytes < contentLength {
            return nil
        }

        let bodyEndIndex = bodyStartIndex + max(0, contentLength)
        let bodyData = data.subdata(in: bodyStartIndex..<bodyEndIndex)
        return Request(method: method, path: cleanPath, headers: headers, body: bodyData)
    }

    private func dispatchParsedRequest(_ request: Request, on connection: NWConnection) {
        if !isAuthorized(headers: request.headers) {
            sendHTTPResponse(
                Response.json(status: 401, object: ["error": "unauthorized"]),
                on: connection
            )
            return
        }

        if request.path != path {
            sendHTTPResponse(
                Response.json(status: 404, object: ["error": "Not Found"]),
                on: connection
            )
            return
        }

        if request.method != "POST" {
            sendHTTPResponse(
                Response.json(status: 405, object: ["error": "method_not_allowed"]),
                on: connection
            )
            return
        }

        Task { [handler] in
            let response = await handler(request)
            self.sendHTTPResponse(response, on: connection)
        }
    }

    private func isAuthorized(headers: [String: String]) -> Bool {
        guard let authorizationHeader = headers["authorization"] else {
            return false
        }
        let prefix = "Bearer "
        guard authorizationHeader.hasPrefix(prefix) else {
            return false
        }
        let candidateToken = String(authorizationHeader.dropFirst(prefix.count))
        return constantTimeEquals(candidateToken, bearerToken)
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else {
            return false
        }
        var diff: UInt8 = 0
        for index in 0..<lhsBytes.count {
            diff |= lhsBytes[index] ^ rhsBytes[index]
        }
        return diff == 0
    }

    private func sendHTTPResponse(_ response: Response, on connection: NWConnection) {
        let reasonPhrase: String
        switch response.status {
        case 200: reasonPhrase = "OK"
        case 202: reasonPhrase = "Accepted"
        case 400: reasonPhrase = "Bad Request"
        case 401: reasonPhrase = "Unauthorized"
        case 404: reasonPhrase = "Not Found"
        case 405: reasonPhrase = "Method Not Allowed"
        default: reasonPhrase = "Status"
        }

        var headerLines = [
            "HTTP/1.1 \(response.status) \(reasonPhrase)",
            "Content-Length: \(response.body.count)",
            "Cache-Control: no-store",
            "Connection: close"
        ]
        for (key, value) in response.headers {
            headerLines.append("\(key): \(value)")
        }

        let headerBlock = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var payload = Data(headerBlock.utf8)
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.removeConnection(ObjectIdentifier(connection))
        })
    }
}

// MARK: - Loopback MCP Server

@MainActor
public final class ClickyLoopbackMCPServer {
    public static let shared = ClickyLoopbackMCPServer()

    public typealias ToolHandler = @MainActor @Sendable (_ arguments: [String: Any]) async throws -> ClickyMCPToolResult

    private struct RegisteredTool {
        let definition: ClickyMCPToolDefinition
        let handler: ToolHandler
    }

    public private(set) var port: UInt16?
    public let bearerToken: String

    private var httpServer: ClickyLoopbackHTTPServer?
    private var tools: [String: RegisteredTool] = [:]
    private var hasRegisteredDefaults = false

    public var isRunning: Bool {
        port != nil
    }

    public var endpointURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/mcp")
    }

    public var connectionFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clicky/BrowserBridge/connection.json", isDirectory: false)
    }

    private init() {
        self.bearerToken = Self.generateRandomBearerToken()
    }

    // MARK: - Lifecycle

    public func start() throws {
        if port != nil {
            try writeConnectionFile()
            return
        }

        registerDefaultToolsIfNeeded()

        let server = ClickyLoopbackHTTPServer(bearerToken: bearerToken, path: "/mcp") { [weak self] request in
            guard let self else {
                return ClickyLoopbackHTTPServer.Response.json(
                    status: 500,
                    object: ["error": "Server deallocated"]
                )
            }
            return await self.handleMCPHTTPRequest(body: request.body)
        }

        let boundPort = try server.start()
        self.httpServer = server
        self.port = boundPort
        try writeConnectionFile()
    }

    public func stop() {
        httpServer?.stop()
        httpServer = nil
        port = nil
        removeConnectionFileIfOwned()
    }

    // MARK: - Tool Registration

    public func registerTool(
        name: String,
        description: String,
        inputSchema: [String: Any],
        handler: @escaping ToolHandler
    ) {
        let definition = ClickyMCPToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
        tools[name] = RegisteredTool(definition: definition, handler: handler)
    }

    public func unregisterTool(name: String) {
        tools.removeValue(forKey: name)
    }

    public func registeredToolDefinitions() -> [ClickyMCPToolDefinition] {
        tools.keys.sorted().compactMap { tools[$0]?.definition }
    }

    // MARK: - Default Tool Wiring

    private func registerDefaultToolsIfNeeded() {
        guard !hasRegisteredDefaults else { return }
        hasRegisteredDefaults = true

        // 1. browser_poll (ClickyBrowserHost long-poll)
        registerTool(
            name: "browser_poll",
            description: "Long-poll for pending browser extension commands and report active browser session state.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "session": ["type": "string"],
                    "profile": ["type": "string"],
                    "browser": ["type": "string"],
                    "extension": ["type": "string"],
                    "tabId": ["type": "integer"],
                    "selected": ["type": "boolean"]
                ]
            ]
        ) { arguments in
            let resultDictionary = await ClickyBrowserBridge.shared.handleBrowserPoll(arguments: arguments)
            return ClickyMCPToolResult(structuredContent: resultDictionary, isError: false)
        }

        // 2. browser_reply (ClickyBrowserHost command completion)
        registerTool(
            name: "browser_reply",
            description: "Deliver the result or error of a browser command executed by the extension.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "commandId": ["type": "string"],
                    "session": ["type": "string"],
                    "tabId": ["type": "integer"],
                    "result": ["type": "object"],
                    "error": ["type": "string"]
                ]
            ]
        ) { arguments in
            let resultDictionary = ClickyBrowserBridge.shared.handleBrowserReply(arguments: arguments)
            return ClickyMCPToolResult(structuredContent: resultDictionary, isError: false)
        }

        // 3. upload_approval (v1.1.3 upload security & user confirmation card)
        registerTool(
            name: "upload_approval",
            description: "Request user approval before uploading files from outside the active job workspace.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "files": [
                        "type": "array",
                        "items": ["type": "string"]
                    ],
                    "tabId": ["type": "integer"],
                    "site": ["type": "string"],
                    "jobTitle": ["type": "string"]
                ]
            ]
        ) { arguments in
            await ClickyUploadApproval.shared.handleMCPToolCall(arguments)
        }

        // 4. mac_step (Computer-use takeover consent & screen step)
        registerTool(
            name: "mac_step",
            description: "Ask the user for consent and perform a single on-screen step on their Mac while they watch.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "step": ["type": "string"],
                    "shortTitle": ["type": "string"],
                    "reason": ["type": "string"]
                ],
                "required": ["step"]
            ]
        ) { arguments in
            await ClickyTakeOverController.shared.handleMacStepToolCall(arguments)
        }

        // 5. reveal_artifact (Reveal generated deliverable in Finder)
        registerTool(
            name: "reveal_artifact",
            description: "Reveal a local deliverable file in Finder.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string"]
                ],
                "required": ["path"]
            ]
        ) { arguments in
            self.handleRevealArtifact(arguments: arguments)
        }

        // 6. Delegate placeholders for Lane B/C tools so tools/list advertises them
        // and external modules can overwrite them via registerTool(...)
        registerPlaceholderTool(
            name: "repeat_this_job",
            description: "Make this job repeat on a schedule, or update/pause/resume/stop its routine.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "schedule": ["type": "string"],
                    "prompt": ["type": "string"],
                    "action": ["type": "string"],
                    "ran_now": ["type": "boolean"],
                    "job_id": ["type": "string"]
                ]
            ]
        )

        registerPlaceholderTool(
            name: "find_jobs",
            description: "Search earlier HeyClicky jobs by topic, title, site, or file.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer"]
                ]
            ]
        )

        registerPlaceholderTool(
            name: "read_job",
            description: "Read the report or conversation of an earlier job by job_id.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "job_id": ["type": "string"],
                    "detail": ["type": "string"]
                ],
                "required": ["job_id"]
            ]
        )

        let noteToolSchemas: [(String, String, [String: Any])] = [
            ("note", "Write or replace the full job note markdown.", ["type": "object", "properties": ["md": ["type": "string"]], "required": ["md"]]),
            ("note_add", "Append markdown lines to the job note after a heading or row.", ["type": "object", "properties": ["after": ["type": "string"], "md": ["type": "string"]], "required": ["md"]]),
            ("note_replace", "Replace an exact line or segment in the job note.", ["type": "object", "properties": ["find": ["type": "string"], "md": ["type": "string"]], "required": ["find", "md"]]),
            ("note_remove", "Remove or strike through a line in the job note.", ["type": "object", "properties": ["find": ["type": "string"], "why": ["type": "string"]], "required": ["find"]]),
            ("note_tick", "Mark a plan checkbox item as done and optionally advance {now}.", ["type": "object", "properties": ["item": ["type": "string"], "next": ["type": "string"]], "required": ["item"]]),
            ("note_answer", "Set the answer summary banner at the top of the job note.", ["type": "object", "properties": ["line": ["type": "string"], "big": ["type": "string"], "aside": ["type": "string"]], "required": ["line"]])
        ]
        for (toolName, toolDescription, schema) in noteToolSchemas {
            registerPlaceholderTool(name: toolName, description: toolDescription, inputSchema: schema)
        }
    }

    private func registerPlaceholderTool(name: String, description: String, inputSchema: [String: Any]) {
        registerTool(name: name, description: description, inputSchema: inputSchema) { _ in
            ClickyMCPToolResult.error("not_implemented", extra: ["toolName": name])
        }
    }

    // MARK: - Built-in reveal_artifact

    private func handleRevealArtifact(arguments: [String: Any]) -> ClickyMCPToolResult {
        guard let rawPath = (arguments["path"] as? String ?? arguments["filePath"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return ClickyMCPToolResult.error("reveal_artifact needs a path.")
        }

        if let parsedURL = URL(string: rawPath),
           let scheme = parsedURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return ClickyMCPToolResult.error("\(rawPath) is a URL, not a local file to reveal.")
        }

        let expandedPath = (rawPath as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return ClickyMCPToolResult.text(
                "Opened \(fileURL.path) in Finder.",
                structuredContent: [
                    "opened": true,
                    "fileExists": true,
                    "openedPath": fileURL.path
                ]
            )
        }

        var probeURL = fileURL.deletingLastPathComponent()
        while probeURL.path != "/" && !fileManager.fileExists(atPath: probeURL.path) {
            probeURL = probeURL.deletingLastPathComponent()
        }

        if fileManager.fileExists(atPath: probeURL.path) {
            NSWorkspace.shared.open(probeURL)
            return ClickyMCPToolResult.text(
                "The file was missing, so I opened the nearest existing folder for \(fileURL.path) in Finder.",
                structuredContent: [
                    "opened": true,
                    "fileExists": false,
                    "openedPath": probeURL.path
                ]
            )
        }

        return ClickyMCPToolResult.error(
            "Could not reveal \(fileURL.path).",
            extra: ["opened": false, "fileExists": false]
        )
    }

    // MARK: - JSON-RPC 2.0 Router

    private func handleMCPHTTPRequest(body: Data) async -> ClickyLoopbackHTTPServer.Response {
        guard let parsedObject = try? JSONSerialization.jsonObject(with: body, options: []),
              let requestDict = parsedObject as? [String: Any] else {
            return ClickyLoopbackHTTPServer.Response.json(
                status: 400,
                object: jsonRPCError(id: NSNull(), code: -32700, message: "Parse error")
            )
        }

        let requestID = requestDict["id"]
        guard let method = requestDict["method"] as? String else {
            return ClickyLoopbackHTTPServer.Response.json(
                status: 400,
                object: jsonRPCError(id: requestID ?? NSNull(), code: -32600, message: "Invalid Request")
            )
        }

        switch method {
        case "initialize":
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.3"
            let result: [String: Any] = [
                "protocolVersion": "2025-03-26",
                "capabilities": [
                    "tools": [String: Any]()
                ],
                "serverInfo": [
                    "name": "HeyClicky",
                    "version": appVersion
                ]
            ]
            return ClickyLoopbackHTTPServer.Response.json(
                status: 200,
                object: jsonRPCResult(id: requestID ?? NSNull(), result: result)
            )

        case "notifications/initialized":
            if let requestID {
                return ClickyLoopbackHTTPServer.Response.json(
                    status: 200,
                    object: jsonRPCResult(id: requestID, result: [:])
                )
            }
            return ClickyLoopbackHTTPServer.Response(status: 202)

        case "ping":
            return ClickyLoopbackHTTPServer.Response.json(
                status: 200,
                object: jsonRPCResult(id: requestID ?? NSNull(), result: [:])
            )

        case "tools/list":
            let toolList = registeredToolDefinitions().map { $0.toDictionary() }
            return ClickyLoopbackHTTPServer.Response.json(
                status: 200,
                object: jsonRPCResult(id: requestID ?? NSNull(), result: ["tools": toolList])
            )

        case "tools/call":
            let params = requestDict["params"] as? [String: Any] ?? [:]
            guard let toolName = params["name"] as? String, !toolName.isEmpty else {
                return ClickyLoopbackHTTPServer.Response.json(
                    status: 400,
                    object: jsonRPCError(id: requestID ?? NSNull(), code: -32602, message: "Missing tool name")
                )
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let registered = resolveTool(named: toolName) else {
                return ClickyLoopbackHTTPServer.Response.json(
                    status: 200,
                    object: jsonRPCResult(
                        id: requestID ?? NSNull(),
                        result: [
                            "content": [["type": "text", "text": "Unknown tool."]],
                            "structuredContent": ["error": "Unknown tool.", "toolName": toolName],
                            "isError": true
                        ]
                    )
                )
            }

            do {
                let toolResult = try await registered.handler(arguments)
                return ClickyLoopbackHTTPServer.Response.json(
                    status: 200,
                    object: jsonRPCResult(
                        id: requestID ?? NSNull(),
                        result: [
                            "content": toolResult.content,
                            "structuredContent": toolResult.structuredContent,
                            "isError": toolResult.isError
                        ]
                    )
                )
            } catch {
                return ClickyLoopbackHTTPServer.Response.json(
                    status: 200,
                    object: jsonRPCResult(
                        id: requestID ?? NSNull(),
                        result: [
                            "content": [["type": "text", "text": error.localizedDescription]],
                            "structuredContent": ["error": error.localizedDescription],
                            "isError": true
                        ]
                    )
                )
            }

        default:
            return ClickyLoopbackHTTPServer.Response.json(
                status: 200,
                object: jsonRPCError(id: requestID ?? NSNull(), code: -32601, message: "Method not found")
            )
        }
    }

    private func resolveTool(named name: String) -> RegisteredTool? {
        if let exact = tools[name] {
            return exact
        }
        // Support wildcard handler registration such as "note*" if external caller registers one
        if name.hasPrefix("note"), let wildcard = tools["note*"] {
            return wildcard
        }
        return nil
    }

    private func jsonRPCResult(id: Any, result: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
    }

    private func jsonRPCError(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }

    // MARK: - connection.json Persistence

    private func writeConnectionFile() throws {
        guard let port else {
            throw ClickyLoopbackServerError.missingPort
        }
        let targetURL = connectionFileURL
        let directoryURL = targetURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let payload: [String: Any] = [
            "port": Int(port),
            "token": bearerToken
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try jsonData.write(to: targetURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
    }

    private func removeConnectionFileIfOwned() {
        let targetURL = connectionFileURL
        guard let data = try? Data(contentsOf: targetURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileToken = json["token"] as? String,
              fileToken == bearerToken else {
            return
        }
        try? FileManager.default.removeItem(at: targetURL)
    }

    private nonisolated static func generateRandomBearerToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
