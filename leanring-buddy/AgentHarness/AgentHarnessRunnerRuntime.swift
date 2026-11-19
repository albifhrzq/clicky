//
//  AgentHarnessRunnerRuntime.swift
//  leanring-buddy
//

import Foundation
import Combine

private nonisolated struct RunnerSessionInfo: Sendable {
    let port: UInt16
    let harnessToken: String
}

private nonisolated struct RunnerLaunchConfig: Sendable {
    let runtimeExecutableURL: URL
    let scriptURL: URL
    let stateDirectoryURL: URL
    let harnessToken: String
    let compactModel: String
    let braveAPIKey: String
    let remoteCompactionEnabled: Bool
}

@MainActor
public final class AgentHarnessRunnerRuntime: ObservableObject {
    public static let shared = AgentHarnessRunnerRuntime()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var runnerPort: UInt16?
    @Published public private(set) var activeJobIDs: Set<String> = []
    @Published public private(set) var lastError: String?

    private var controller: RunnerProcessController?
    private var startupTask: Task<RunnerSessionInfo, Error>?
    private let httpClient = RunnerHTTPClient()

    private init() {}

    // MARK: - Public API

    @discardableResult
    public func startTurn(
        threadID: String,
        clickySlug: String,
        prompt: String,
        workspaceURL: URL,
        model: String? = nil,
        mcpServers: [String: Any] = [:],
        skillDirectories: [String] = [],
        instructions: String = "",
        imagePaths: [String] = [],
        onEvent: @MainActor @Sendable @escaping (AgentHarnessEvent) -> Void
    ) async throws -> String {
        let sanitizedJobID = Self.sanitizeJobID(threadID)

        // Ensure workspace directory exists
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        // 1. Start local OpenCodex / BYOK HTTP shim
        let shim = ClickyLocalAgentShim.shared
        let shimBaseURL = try await shim.ensureStarted()
        let shimToken = shim.sessionToken

        // 2. Resolve active model & start Node/Bun harness runner
        let config = ClickyConfiguration.shared
        let persistedAgentModel = UserDefaults.standard.string(forKey: "clicky_selected_agent_model") ?? ""
        let defaultModel = persistedAgentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.selectedModel
            : persistedAgentModel
        let requestedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = (requestedModel?.isEmpty == false ? requestedModel! : defaultModel)

        let sessionInfo = try await ensureRunnerStarted(compactModel: effectiveModel)

        // 3. Build /turn payload matching clicky-harness-runner.js ($f / oI)
        let normalizedMCP = Self.normalizeMCPServers(mcpServers)
        let resolvedUserSkills = skillDirectories.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let resolvedImages = imagePaths.filter { FileManager.default.fileExists(atPath: $0) }

        var payload: [String: Any] = [
            "job": sanitizedJobID,
            "harness": "h1",
            "place": "mac",
            "text": prompt,
            "workspace": workspaceURL.path,
            "model": effectiveModel,
            "instructions": instructions,
            "skills": [],
            "userSkills": resolvedUserSkills,
            "mcp": normalizedMCP,
            "images": resolvedImages,
            "worker": [
                "base": shimBaseURL.absoluteString,
                "sessionToken": shimToken
            ],
            "leaseMetadata": [
                "clicky_slug": clickySlug,
                "clicky_thread_id": threadID
            ],
            // The runner implements note/note_add/note_replace/note_remove/note_tick/note_answer
            // natively when this is present. The file must be named note.md and live in the workspace.
            "note": [
                "tools": true,
                "path": Self.noteFilePath(forSlug: clickySlug, workspaceURL: workspaceURL)
            ]
        ]
        if effectiveModel.isEmpty {
            payload.removeValue(forKey: "model")
        }

        activeJobIDs.insert(sanitizedJobID)
        defer {
            activeJobIDs.remove(sanitizedJobID)
        }

        let turnResponse = try await httpClient.postJSON(
            port: sessionInfo.port,
            path: "/turn",
            token: sessionInfo.harnessToken,
            body: payload
        )

        var afterSeq = (turnResponse["after"] as? NSNumber)?.intValue ?? 0
        let activeTurnRef = turnResponse["turnRef"] as? String

        // 4. Long-poll /events until turn_end arrives or task is cancelled
        while true {
            if Task.isCancelled {
                try? await httpClient.postJSON(
                    port: sessionInfo.port,
                    path: "/cancel",
                    token: sessionInfo.harnessToken,
                    body: ["job": sanitizedJobID]
                )
                throw CancellationError()
            }

            let eventsResponse: [String: Any]
            do {
                eventsResponse = try await httpClient.getEvents(
                    port: sessionInfo.port,
                    jobID: sanitizedJobID,
                    after: afterSeq,
                    waitMs: 20_000,
                    token: sessionInfo.harnessToken
                )
            } catch is CancellationError {
                try? await httpClient.postJSON(
                    port: sessionInfo.port,
                    path: "/cancel",
                    token: sessionInfo.harnessToken,
                    body: ["job": sanitizedJobID]
                )
                throw CancellationError()
            }

            if let latest = (eventsResponse["latest"] as? NSNumber)?.intValue, latest > afterSeq {
                // Keep advancing even if filtered events occurred, while still iterating returned events
                _ = latest
            }

            let rawEvents = eventsResponse["events"] as? [[String: Any]] ?? []
            var completedStatus: (status: String, error: String?)?

            for rawEvent in rawEvents {
                if let seq = (rawEvent["seq"] as? NSNumber)?.intValue, seq > afterSeq {
                    afterSeq = seq
                }
                guard let event = AgentHarnessEvent.from(dictionary: rawEvent) else {
                    continue
                }
                if let activeTurnRef, let eventTurnRef = event.turnRef, eventTurnRef != activeTurnRef {
                    continue
                }

                await onEvent(event)

                if case .turnEnd(let status, let error) = event.payload {
                    completedStatus = (status, error)
                }
            }

            if let completedStatus {
                if completedStatus.status == "failed" {
                    let message = completedStatus.error ?? String(localized: "Agent thread failed.")
                    lastError = message
                    throw AgentHarnessRuntimeError.turnFailed(message)
                }
                return sanitizedJobID
            }
        }
    }

    public func steer(jobID: String, text: String) async throws {
        let sessionInfo = try await ensureRunnerStarted(compactModel: ClickyConfiguration.shared.selectedModel)
        let sanitizedJobID = Self.sanitizeJobID(jobID)
        _ = try await httpClient.postJSON(
            port: sessionInfo.port,
            path: "/steer",
            token: sessionInfo.harnessToken,
            body: [
                "job": sanitizedJobID,
                "text": text
            ]
        )
    }

    public func cancel(jobID: String) async throws {
        guard let controller, let sessionInfo = controller.currentSessionInfo else {
            return
        }
        let sanitizedJobID = Self.sanitizeJobID(jobID)
        _ = try await httpClient.postJSON(
            port: sessionInfo.port,
            path: "/cancel",
            token: sessionInfo.harnessToken,
            body: ["job": sanitizedJobID]
        )
    }

    public func stopRunner() {
        startupTask?.cancel()
        startupTask = nil
        controller?.stop()
        controller = nil
        isRunning = false
        runnerPort = nil
        activeJobIDs.removeAll()
    }

    // MARK: - Runner Lifecycle

    private func ensureRunnerStarted(compactModel: String) async throws -> RunnerSessionInfo {
        if let controller, let existingSession = controller.currentSessionInfo, controller.isProcessRunning {
            return existingSession
        }

        if let startupTask {
            return try await startupTask.value
        }

        let launchConfig = try buildLaunchConfig(compactModel: compactModel)
        let task = Task<RunnerSessionInfo, Error> { [weak self] in
            let processController = RunnerProcessController(
                config: launchConfig,
                onExit: { [weak self] exitCode, stderrText in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isRunning = false
                        self.runnerPort = nil
                        if exitCode != 0 && !stderrText.isEmpty {
                            self.lastError = stderrText
                        }
                    }
                }
            )
            let sessionInfo = try await processController.startAndWaitForReadiness()
            guard let self else {
                processController.stop()
                throw CancellationError()
            }
            self.controller = processController
            self.runnerPort = sessionInfo.port
            self.isRunning = true
            self.lastError = nil
            return sessionInfo
        }

        self.startupTask = task
        do {
            let info = try await task.value
            self.startupTask = nil
            return info
        } catch {
            self.startupTask = nil
            self.isRunning = false
            self.runnerPort = nil
            self.lastError = error.localizedDescription
            throw error
        }
    }

    private func buildLaunchConfig(compactModel: String) throws -> RunnerLaunchConfig {
        let runtimeURL = try Self.resolveRuntimeExecutableURL()
        let rawRunnerURL = try Self.resolveRunnerScriptURL()
        let stateDirectoryURL = try Self.resolveStateDirectoryURL()

        // Node treats .js files without package.json "type": "module" as CommonJS.
        // Symlink as .mjs when executing via Node so the ESM bundle loads cleanly.
        let effectiveScriptURL: URL
        if runtimeURL.lastPathComponent.lowercased() == "bun" {
            effectiveScriptURL = rawRunnerURL
        } else {
            let mjsSymlinkURL = stateDirectoryURL.appendingPathComponent("clicky-harness-runner.mjs")
            if FileManager.default.fileExists(atPath: mjsSymlinkURL.path) {
                try? FileManager.default.removeItem(at: mjsSymlinkURL)
            }
            try FileManager.default.createSymbolicLink(at: mjsSymlinkURL, withDestinationURL: rawRunnerURL)
            effectiveScriptURL = mjsSymlinkURL
        }

        let harnessToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let config = ClickyConfiguration.shared
        let braveKeychain = ClickyKeychainStore.read(key: "clicky_brave_api_key") ?? ""
        let braveEnv = ProcessInfo.processInfo.environment["CLICKY_BRAVE_API_KEY"] ?? ""
        let braveAPIKey = braveKeychain.isEmpty ? braveEnv : braveKeychain

        // Disable OpenAI-only /v1/responses/compact when targeting OpenCodex, Anthropic, or Antigravity
        let useRemoteCompaction = (config.mode == .byok && !config.openaiAPIKey.isEmpty)
            || config.mode == .cloudflareWorker

        return RunnerLaunchConfig(
            runtimeExecutableURL: runtimeURL,
            scriptURL: effectiveScriptURL,
            stateDirectoryURL: stateDirectoryURL,
            harnessToken: harnessToken,
            compactModel: compactModel,
            braveAPIKey: braveAPIKey,
            remoteCompactionEnabled: useRemoteCompaction
        )
    }

    // MARK: - Path & Payload Helpers

    private static func resolveRunnerScriptURL() throws -> URL {
        var searchedPaths: [String] = []

        if let defaultsPath = UserDefaults.standard.string(forKey: "ClickyAgentHarnessRunnerPath")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultsPath.isEmpty {
            searchedPaths.append(defaultsPath)
            if FileManager.default.fileExists(atPath: defaultsPath) {
                return URL(fileURLWithPath: defaultsPath)
            }
        }

        if let envPath = ProcessInfo.processInfo.environment["ClickyAgentHarnessRunnerPath"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envPath.isEmpty {
            searchedPaths.append(envPath)
            if FileManager.default.fileExists(atPath: envPath) {
                return URL(fileURLWithPath: envPath)
            }
        }

        if let bundleURL = Bundle.main.url(forResource: "clicky-harness-runner", withExtension: "js") {
            searchedPaths.append(bundleURL.path)
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                return bundleURL
            }
        }

        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("clicky-harness-runner.js") {
            searchedPaths.append(resourceURL.path)
            if FileManager.default.fileExists(atPath: resourceURL.path) {
                return resourceURL
            }
        }

        let sourceRelativeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("clicky-harness-runner.js")
        searchedPaths.append(sourceRelativeURL.path)
        if FileManager.default.fileExists(atPath: sourceRelativeURL.path) {
            return sourceRelativeURL
        }

        throw AgentHarnessRuntimeError.runnerNotFound(searchedPaths)
    }

    private static func resolveRuntimeExecutableURL() throws -> URL {
        var candidates: [String] = []

        if let defaultsPath = UserDefaults.standard.string(forKey: "ClickyAgentHarnessNodePath")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultsPath.isEmpty {
            candidates.append(defaultsPath)
        }

        if let envPath = ProcessInfo.processInfo.environment["ClickyAgentHarnessNodePath"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envPath.isEmpty {
            candidates.append(envPath)
        }

        if let resourceDir = Bundle.main.resourceURL {
            candidates.append(resourceDir.appendingPathComponent("bun").path)
            candidates.append(resourceDir.appendingPathComponent("node").path)
        }
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDir.appendingPathComponent("bun").path)
            candidates.append(executableDir.appendingPathComponent("node").path)
        }

        let home = NSHomeDirectory()
        candidates.append(contentsOf: [
            "\(home)/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "\(home)/.nvm/current/bin/node"
        ])

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let pathDirectories = pathEnv.split(separator: ":").map(String.init)
            for binaryName in ["bun", "node"] {
                for directory in pathDirectories {
                    candidates.append((directory as NSString).appendingPathComponent(binaryName))
                }
            }
        }

        var deduplicatedCandidates: [String] = []
        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty {
            if seen.insert(candidate).inserted {
                deduplicatedCandidates.append(candidate)
            }
        }

        for candidate in deduplicatedCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw AgentHarnessRuntimeError.runtimeNotFound(deduplicatedCandidates)
    }

    private static func resolveStateDirectoryURL() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let stateDirectory = appSupport
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("AgentHarnessState", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        return stateDirectory
    }

    /// Prefers the canonical per-slug note.md, but falls back to the turn workspace so the
    /// runner's "must live under the workspace" rule always holds.
    static func noteFilePath(forSlug clickySlug: String, workspaceURL: URL) -> String {
        let canonicalNoteURL = ClickyWorkFolderFiles.shared.noteMarkdownURL(forSlug: clickySlug)
        // Trailing "/" so "/ws" does not match the sibling "/ws-other".
        if canonicalNoteURL.path.hasPrefix(workspaceURL.path + "/") {
            return canonicalNoteURL.path
        }
        return workspaceURL.appendingPathComponent("note.md", isDirectory: false).path
    }

    private static func sanitizeJobID(_ rawJobID: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let mappedScalars = rawJobID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : Character("_")
        }
        var sanitized = String(mappedScalars)
        if sanitized.isEmpty {
            sanitized = "job_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        }
        if sanitized.count > 100 {
            sanitized = String(sanitized.prefix(100))
        }
        return sanitized
    }

    private static func normalizeMCPServers(_ mcpServers: [String: Any]) -> [[String: Any]] {
        if let explicitServers = mcpServers["servers"] as? [[String: Any]] {
            return explicitServers
        }
        var normalized: [[String: Any]] = []
        for (serverName, rawConfig) in mcpServers {
            guard var serverDict = rawConfig as? [String: Any] else { continue }
            if serverDict["name"] == nil {
                serverDict["name"] = serverName
            }
            normalized.append(serverDict)
        }
        return normalized
    }
}

// MARK: - Nonisolated Process & HTTP Helpers

private nonisolated final class RunnerProcessController: @unchecked Sendable {
    private let config: RunnerLaunchConfig
    private let onExit: @Sendable (Int32, String) -> Void
    private let lock = NSLock()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var sessionInfo: RunnerSessionInfo?
    private var readinessContinuation: CheckedContinuation<RunnerSessionInfo, Error>?
    private var hasCompletedReadiness = false

    init(config: RunnerLaunchConfig, onExit: @escaping @Sendable (Int32, String) -> Void) {
        self.config = config
        self.onExit = onExit
    }

    var currentSessionInfo: RunnerSessionInfo? {
        lock.lock()
        defer { lock.unlock() }
        return sessionInfo
    }

    var isProcessRunning: Bool {
        lock.lock()
        let proc = process
        lock.unlock()
        return proc?.isRunning ?? false
    }

    func startAndWaitForReadiness() async throws -> RunnerSessionInfo {
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.readinessContinuation = continuation
            self.hasCompletedReadiness = false
            lock.unlock()

            let childProcess = Process()
            childProcess.executableURL = config.runtimeExecutableURL
            childProcess.arguments = [config.scriptURL.path]

            var environment = ProcessInfo.processInfo.environment
            environment["CLICKY_HARNESS_TOKEN"] = config.harnessToken
            environment["CLICKY_HARNESS_STATE"] = config.stateDirectoryURL.path
            environment["CLICKY_ALLOW_ANY_MODEL"] = "1"
            if !config.compactModel.isEmpty {
                environment["CLICKY_COMPACT_MODEL"] = config.compactModel
            }
            if !config.braveAPIKey.isEmpty {
                environment["CLICKY_BRAVE_API_KEY"] = config.braveAPIKey
            }
            environment["H1_REMOTE_COMPACTION"] = config.remoteCompactionEnabled ? "1" : "0"
            childProcess.environment = environment

            let inPipe = Pipe()
            let outPipe = Pipe()
            let errPipe = Pipe()
            childProcess.standardInput = inPipe
            childProcess.standardOutput = outPipe
            childProcess.standardError = errPipe

            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.consumeStdoutChunk(chunk)
            }

            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.consumeStderrChunk(chunk)
            }

            childProcess.terminationHandler = { [weak self] terminated in
                self?.handleTermination(status: terminated.terminationStatus)
            }

            lock.lock()
            self.process = childProcess
            self.stdinPipe = inPipe
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe
            lock.unlock()

            do {
                try childProcess.run()
            } catch {
                self.completeReadiness(with: .failure(error))
                return
            }

            // Timeout guard for readiness line
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15.0) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let pending = !self.hasCompletedReadiness
                self.lock.unlock()
                if pending {
                    self.stop()
                    self.completeReadiness(with: .failure(AgentHarnessRuntimeError.readinessTimeout))
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let proc = process
        let inPipe = stdinPipe
        let outPipe = stdoutPipe
        let errPipe = stderrPipe
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        sessionInfo = nil
        lock.unlock()

        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        try? inPipe?.fileHandleForWriting.close()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    private func consumeStdoutChunk(_ chunk: Data) {
        lock.lock()
        stdoutBuffer.append(chunk)
        let newline = Data([0x0A])
        var lines: [String] = []
        while let range = stdoutBuffer.range(of: newline) {
            let lineData = stdoutBuffer.subdata(in: 0..<range.lowerBound)
            stdoutBuffer.removeSubrange(0..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let alreadyReady = hasCompletedReadiness
        lock.unlock()

        if alreadyReady {
            return
        }

        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["ready"] as? Bool) == true,
                  let portNumber = (json["port"] as? NSNumber)?.uint16Value,
                  portNumber > 0 else {
                continue
            }

            let info = RunnerSessionInfo(port: portNumber, harnessToken: config.harnessToken)
            lock.lock()
            self.sessionInfo = info
            lock.unlock()
            completeReadiness(with: .success(info))
            return
        }
    }

    private func consumeStderrChunk(_ chunk: Data) {
        lock.lock()
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 16_384 {
            stderrBuffer.removeFirst(stderrBuffer.count - 16_384)
        }
        lock.unlock()
    }

    private func handleTermination(status: Int32) {
        lock.lock()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        let stderrText = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pending = !hasCompletedReadiness
        sessionInfo = nil
        lock.unlock()

        if pending {
            completeReadiness(with: .failure(AgentHarnessRuntimeError.runnerExitedEarly(status, stderrText)))
        }
        onExit(status, stderrText)
    }

    private func completeReadiness(with result: Result<RunnerSessionInfo, Error>) {
        lock.lock()
        guard !hasCompletedReadiness, let continuation = readinessContinuation else {
            lock.unlock()
            return
        }
        hasCompletedReadiness = true
        readinessContinuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

private nonisolated final class RunnerHTTPClient: @unchecked Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func postJSON(
        port: UInt16,
        path: String,
        token: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentHarnessRuntimeError.invalidRunnerResponse("Non-HTTP response from \(path)")
        }

        let responseText = String(data: data, encoding: .utf8) ?? ""
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AgentHarnessRuntimeError.httpError(httpResponse.statusCode, responseText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentHarnessRuntimeError.invalidRunnerResponse(responseText)
        }
        return json
    }

    func getEvents(
        port: UInt16,
        jobID: String,
        after: Int,
        waitMs: Int,
        token: String
    ) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/events"
        components.queryItems = [
            URLQueryItem(name: "job", value: jobID),
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "wait", value: String(waitMs))
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentHarnessRuntimeError.invalidRunnerResponse("Non-HTTP response from /events")
        }

        let responseText = String(data: data, encoding: .utf8) ?? ""
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AgentHarnessRuntimeError.httpError(httpResponse.statusCode, responseText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentHarnessRuntimeError.invalidRunnerResponse(responseText)
        }
        return json
    }
}
