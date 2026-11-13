//
//  ClickyUploadApproval.swift
//  leanring-buddy
//
//  v1.1.3 browser upload security & consent gate:
//  - Unconditionally blocks private paths (~/.ssh, ~/.gnupg, Keychains, .env/key/pem/p12,
//    browser profiles, and app settings).
//  - Auto-approves files inside the active Clicky job workspace folder.
//  - Prompts user once per turn for external files unless alwaysApproveFileUploads is enabled.
//

import Combine
import Foundation

// MARK: - Types

nonisolated public enum UploadApprovalDecision: String, Sendable, Equatable {
    case approveOnce = "approve_once"
    case approveTurn = "approve_turn"
    case alwaysApprove = "always_approve"
    case decline = "decline"

    public var isApproved: Bool {
        switch self {
        case .approveOnce, .approveTurn, .alwaysApprove:
            return true
        case .decline:
            return false
        }
    }
}

nonisolated public struct UploadApprovalRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let jobTitle: String
    public let files: [String]
    public let site: String
    public let requestedAt: Date

    public init(
        id: UUID = UUID(),
        jobTitle: String,
        files: [String],
        site: String,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.jobTitle = jobTitle
        self.files = files
        self.site = site
        self.requestedAt = requestedAt
    }
}

nonisolated public enum UploadPathValidationResult: Equatable, Sendable {
    case allowedWorkspaceFile(resolvedPath: String)
    case requiresExternalApproval(resolvedPath: String)
    case blockedPrivatePath(resolvedPath: String, reason: String)
    case invalidPath(path: String, reason: String)
}

// MARK: - Approval Controller

@MainActor
public final class ClickyUploadApproval: ObservableObject {
    public static let shared = ClickyUploadApproval()

    public static let maxFilesPerUpload = 10
    public static let maxSingleFileBytes: Int64 = 100 * 1024 * 1024
    public static let maxCombinedUploadBytes: Int64 = 100 * 1024 * 1024
    private static let promptTimeoutSeconds: TimeInterval = 120.0

    @Published public private(set) var pendingRequest: UploadApprovalRequest?
    @Published public private(set) var isAsking: Bool = false

    public var activeTurnID: String = "default-turn"
    public var activeWorkspaceURL: URL?

    public var onApprovalRequested: ((UploadApprovalRequest) -> Void)?

    private var turnDecisionsByTurnID: [String: UploadApprovalDecision] = [:]
    private var pendingContinuation: CheckedContinuation<UploadApprovalDecision, Never>?
    private var pendingRequestID: UUID?

    private init() {}

    // MARK: - Turn Lifecycle

    public func beginTurn(turnID: String, workspaceURL: URL?) {
        activeTurnID = turnID
        activeWorkspaceURL = workspaceURL
    }

    public func endTurn(turnID: String? = nil) {
        let targetTurn = turnID ?? activeTurnID
        turnDecisionsByTurnID.removeValue(forKey: targetTurn)
        if pendingRequest != nil, targetTurn == activeTurnID {
            resolvePending(.decline)
        }
    }

    public func clearTurnCache() {
        turnDecisionsByTurnID.removeAll()
    }

    // MARK: - Private Path Security Validator (v1.1.3)

    /// Validates a single local path against private path rules and workspace exemption.
    nonisolated public func validatePath(
        _ rawPath: String,
        workspaceURL: URL?
    ) -> UploadPathValidationResult {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalidPath(path: rawPath, reason: "Empty file path.")
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .invalidPath(path: rawPath, reason: "upload needs absolute file paths.")
        }

        let rawURL = URL(fileURLWithPath: expanded).standardizedFileURL
        let resolvedURL = rawURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPath = resolvedURL.path

        // Check both the unresolved and symlink-resolved paths against private locations
        // so symlinks inside a workspace cannot bypass private path protections.
        if let blockReason = privatePathBlockReason(forPath: rawURL.path, workspaceURL: workspaceURL)
            ?? privatePathBlockReason(forPath: resolvedPath, workspaceURL: workspaceURL) {
            return .blockedPrivatePath(resolvedPath: resolvedPath, reason: blockReason)
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            return .invalidPath(path: resolvedPath, reason: "No file at \(resolvedPath).")
        }
        guard !isDirectory.boolValue else {
            return .invalidPath(path: resolvedPath, reason: "\(resolvedPath) is not a regular file; upload takes files.")
        }
        guard fileManager.isReadableFile(atPath: resolvedPath) else {
            return .invalidPath(path: resolvedPath, reason: "HeyClicky can't read \(resolvedPath).")
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath),
           let fileSize = attributes[.size] as? NSNumber,
           fileSize.int64Value > Self.maxSingleFileBytes {
            return .invalidPath(path: resolvedPath, reason: "\(resolvedURL.lastPathComponent) is larger than 100 MB.")
        }

        if let workspaceURL {
            let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
            if isPath(resolvedPath, insideDirectory: resolvedWorkspace.path) {
                return .allowedWorkspaceFile(resolvedPath: resolvedPath)
            }
        }

        return .requiresExternalApproval(resolvedPath: resolvedPath)
    }

    /// Validates an array of paths; returns blocked/invalid errors before asking the user.
    nonisolated public func validateUploadPaths(
        _ paths: [String],
        workspaceURL: URL?
    ) -> (results: [UploadPathValidationResult], blockingError: String?) {
        if paths.count > Self.maxFilesPerUpload {
            return ([], "upload needs paths: 1 to \(Self.maxFilesPerUpload) absolute file paths.")
        }

        var results: [UploadPathValidationResult] = []
        var totalBytes: Int64 = 0
        let fileManager = FileManager.default

        for path in paths {
            let result = validatePath(path, workspaceURL: workspaceURL)
            results.append(result)

            switch result {
            case .blockedPrivatePath(let resolvedPath, _):
                return (results, "\(resolvedPath) is in a private place (keys, keychains, browser profiles or app settings), so it is never uploaded.")
            case .invalidPath(_, let reason):
                return (results, reason)
            case .allowedWorkspaceFile(let resolvedPath), .requiresExternalApproval(let resolvedPath):
                if let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath),
                   let size = attributes[.size] as? NSNumber {
                    totalBytes += size.int64Value
                }
            }
        }

        if totalBytes > Self.maxCombinedUploadBytes {
            return (results, "These files are larger than 100 MB together. Upload fewer at a time.")
        }

        return (results, nil)
    }

    nonisolated private func privatePathBlockReason(forPath candidatePath: String, workspaceURL: URL?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let normalized = URL(fileURLWithPath: candidatePath).standardizedFileURL.path
        let lowercased = normalized.lowercased()
        let fileName = URL(fileURLWithPath: normalized).lastPathComponent.lowercased()
        let pathExtension = URL(fileURLWithPath: normalized).pathExtension.lowercased()

        // 1. Sensitive directories under $HOME
        let blockedHomeRelativePrefixes = [
            ".ssh",
            ".gnupg",
            ".aws",
            ".azure",
            ".kube",
            ".docker",
            ".config/gcloud",
            ".config/gh",
            ".codex",
            "Library/Keychains",
            "Library/Cookies",
            "Library/Safari",
            "Library/Preferences",
            "Library/Application Support/Google",
            "Library/Application Support/Chromium",
            "Library/Application Support/BraveSoftware",
            "Library/Application Support/Microsoft Edge",
            "Library/Application Support/Arc",
            "Library/Application Support/Vivaldi",
            "Library/Application Support/Firefox"
        ]

        for relativePrefix in blockedHomeRelativePrefixes {
            let blockedDirectory = (home as NSString).appendingPathComponent(relativePrefix)
            if isPath(normalized, insideDirectory: blockedDirectory) {
                return "Private directory \(relativePrefix) is blocked."
            }
        }

        // System-wide Keychains
        if isPath(normalized, insideDirectory: "/Library/Keychains")
            || isPath(normalized, insideDirectory: "/System/Library/Keychains") {
            return "System Keychains are blocked."
        }

        // 2. App settings directories (exempting files explicitly inside the active Clicky job workspace)
        let appSupportDirectories = [
            (home as NSString).appendingPathComponent("Library/Application Support/Clicky"),
            (home as NSString).appendingPathComponent("Library/Application Support/HeyClicky")
        ]
        for appDir in appSupportDirectories {
            if isPath(normalized, insideDirectory: appDir) {
                let isInsideActiveWorkspace: Bool
                if let workspaceURL {
                    let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
                    isInsideActiveWorkspace = isPath(normalized, insideDirectory: resolvedWorkspace)
                } else {
                    isInsideActiveWorkspace = false
                }
                if !isInsideActiveWorkspace {
                    return "App settings directory is blocked."
                }
            }
        }

        // 3. Sensitive file names & extensions (.env, .key, .pem, .p12, credentials)
        let blockedExactFileNames: Set<String> = [
            ".env",
            ".netrc",
            ".git-credentials",
            ".npmrc",
            ".pypirc",
            ".pgpass",
            "id_rsa",
            "id_dsa",
            "id_ecdsa",
            "id_ed25519"
        ]
        if blockedExactFileNames.contains(fileName) || fileName.hasPrefix(".env.") {
            return "Sensitive file '\(fileName)' is blocked."
        }

        let blockedExtensions: Set<String> = [
            "key",
            "pem",
            "p12",
            "pfx",
            "jks",
            "keystore",
            "kdbx",
            "keychain",
            "keychain-db",
            "mobileprovision"
        ]
        if blockedExtensions.contains(pathExtension) {
            return "Sensitive key/certificate file extension '.\(pathExtension)' is blocked."
        }

        // Catch browser profile paths anywhere on disk (e.g., custom profile locations)
        if lowercased.contains("/nativeMessagingHosts/".lowercased())
            || lowercased.contains("/browserbridge/") {
            return "Browser bridge configuration is blocked."
        }

        return nil
    }

    nonisolated private func isPath(_ path: String, insideDirectory directory: String) -> Bool {
        let cleanPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let cleanDir = URL(fileURLWithPath: directory).standardizedFileURL.path
        if cleanPath == cleanDir { return true }
        let prefix = cleanDir.hasSuffix("/") ? cleanDir : cleanDir + "/"
        return cleanPath.hasPrefix(prefix)
    }

    // MARK: - Approval Request Flow

    public func requestApproval(
        files: [String],
        site: String,
        jobTitle: String
    ) async -> UploadApprovalDecision {
        // 1. Validate all concrete file paths first (blocks private paths unconditionally)
        var externalFiles: [String] = []
        var hasDescriptiveOnlyEntry = false

        for entry in files {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let looksLikePath = trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed == "~"
            if !looksLikePath {
                hasDescriptiveOnlyEntry = true
                externalFiles.append(trimmed)
                continue
            }

            let validation = validatePath(trimmed, workspaceURL: activeWorkspaceURL)
            switch validation {
            case .blockedPrivatePath:
                return .decline
            case .invalidPath:
                return .decline
            case .allowedWorkspaceFile:
                // Workspace exemption: files inside the active job folder auto-approve
                continue
            case .requiresExternalApproval(let resolvedPath):
                externalFiles.append(resolvedPath)
            }
        }

        // If every supplied file was inside the active job workspace, auto-approve without prompting
        if !files.isEmpty && externalFiles.isEmpty && !hasDescriptiveOnlyEntry {
            return .approveOnce
        }

        // 2. Global user setting check
        if ClickyConfiguration.shared.alwaysApproveFileUploads {
            return .alwaysApprove
        }

        // 3. Per-turn approval cache check
        if let cachedDecision = turnDecisionsByTurnID[activeTurnID] {
            return cachedDecision
        }

        // 4. Reject if another approval card is already waiting for user input
        if pendingRequest != nil {
            return .decline
        }

        let displayFiles = externalFiles.isEmpty ? ["files from outside your job folder"] : externalFiles
        let displaySite = site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "a website" : site
        let displayTitle = jobTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "HeyClicky" : jobTitle

        let request = UploadApprovalRequest(
            jobTitle: displayTitle,
            files: displayFiles,
            site: displaySite
        )
        let requestID = request.id

        pendingRequest = request
        isAsking = true
        pendingRequestID = requestID
        onApprovalRequested?(request)

        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<UploadApprovalDecision, Never>) in
            pendingContinuation = continuation

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.promptTimeoutSeconds * 1_000_000_000))
                guard let self else { return }
                if self.pendingRequestID == requestID {
                    self.resolvePending(.decline)
                }
            }
        }

        switch decision {
        case .approveOnce:
            break
        case .approveTurn:
            turnDecisionsByTurnID[activeTurnID] = .approveTurn
        case .alwaysApprove:
            ClickyConfiguration.shared.alwaysApproveFileUploads = true
            turnDecisionsByTurnID[activeTurnID] = .alwaysApprove
        case .decline:
            turnDecisionsByTurnID[activeTurnID] = .decline
        }

        return decision
    }

    public func resolvePending(_ decision: UploadApprovalDecision) {
        pendingRequest = nil
        isAsking = false
        pendingRequestID = nil

        if let continuation = pendingContinuation {
            pendingContinuation = nil
            continuation.resume(returning: decision)
        }
    }

    // MARK: - MCP Tool Handler

    public func handleMCPToolCall(_ arguments: [String: Any]) async -> ClickyMCPToolResult {
        let rawFiles = arguments["files"] as? [String] ?? []
        let site = (arguments["site"] as? String)
            ?? (arguments["tabId"].map { "tab \($0)" })
            ?? "a website"
        let jobTitle = (arguments["jobTitle"] as? String) ?? "Current Job"

        // Check for private paths first so we can return the exact security message
        for entry in rawFiles {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed == "~" {
                let validation = validatePath(trimmed, workspaceURL: activeWorkspaceURL)
                if case .blockedPrivatePath(let resolvedPath, _) = validation {
                    return ClickyMCPToolResult.error(
                        "\(resolvedPath) is in a private place (keys, keychains, browser profiles or app settings), so it is never uploaded.",
                        extra: ["decision": "blocked_private_path", "allowed": false]
                    )
                }
                if case .invalidPath(_, let reason) = validation {
                    return ClickyMCPToolResult.error(
                        reason,
                        extra: ["decision": "invalid_path", "allowed": false]
                    )
                }
            }
        }

        if pendingRequest != nil {
            return ClickyMCPToolResult.error(
                "HeyClicky is asking the user something else right now. Try this again in a moment.",
                extra: ["decision": "busy", "allowed": false]
            )
        }

        let decision = await requestApproval(files: rawFiles, site: site, jobTitle: jobTitle)
        if decision.isApproved {
            return ClickyMCPToolResult.text(
                "Upload what this job needs until your turn ends; nothing more will ask.",
                structuredContent: [
                    "allowed": true,
                    "decision": decision.rawValue
                ]
            )
        } else {
            let fileSummary = rawFiles.isEmpty ? "files from outside your job folder" : rawFiles.joined(separator: ", ")
            return ClickyMCPToolResult.error(
                "The user said no to adding \(fileSummary) to \(site) this turn. Don't try again or copy the file somewhere else to get around this. Carry on without it and say what's still needed.",
                extra: [
                    "allowed": false,
                    "decision": decision.rawValue
                ]
            )
        }
    }
}
