//
//  ClickyBrowserBridge.swift
//  leanring-buddy
//
//  Manages NativeMessagingHosts manifests (com.heyclicky.browser.json),
//  tracks live Chromium extension sessions, and dispatches browser commands
//  over browser_poll / browser_reply via ClickyLoopbackMCPServer.
//

import AppKit
import Combine
import Foundation

// MARK: - Types & Errors

nonisolated public struct ClickyBrowserNativeHostSetupError: Error, Sendable, Equatable {
    public let browserName: String
    public let folderPath: String
    public let underlyingDescription: String

    public init(browserName: String, folderPath: String, underlying: Error) {
        self.browserName = browserName
        self.folderPath = folderPath
        self.underlyingDescription = underlying.localizedDescription
    }
}

nonisolated public enum ClickyBrowserBridgeError: LocalizedError, Sendable {
    case notConnected
    case commandTimedOut(name: String, seconds: TimeInterval)
    case remoteCommandFailed(String)
    case connectionChanged
    case helperMissing(path: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Chrome isn't connected."
        case .commandTimedOut(let name, let seconds):
            return "Browser command '\(name)' timed out after \(Int(seconds))s."
        case .remoteCommandFailed(let message):
            return message
        case .connectionChanged:
            return "Browser connection changed. Start a new turn."
        case .helperMissing(let path):
            return "Bundled ClickyBrowserHost helper missing at \(path)."
        }
    }
}

nonisolated public struct ClickyBrowserSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let session: String
    public let profile: String
    public let browser: String
    public let extensionVersion: String
    public let tabId: Int?
    public let selected: Bool
    public let lastSeen: Date

    public init(
        session: String,
        profile: String,
        browser: String,
        extensionVersion: String,
        tabId: Int?,
        selected: Bool,
        lastSeen: Date = Date()
    ) {
        self.id = session
        self.session = session
        self.profile = profile
        self.browser = browser
        self.extensionVersion = extensionVersion
        self.tabId = tabId
        self.selected = selected
        self.lastSeen = lastSeen
    }
}

nonisolated public struct ClickyChromiumBrowserDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let bundleIdentifiers: [String]
    public let applicationSupportSubpath: String
    public let extensionsPageURL: String
    public let isPrimaryTarget: Bool

    public func nativeMessagingHostsDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportSubpath, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
    }

    public func manifestURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        nativeMessagingHostsDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("com.heyclicky.browser.json", isDirectory: false)
    }

    public func userDataDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportSubpath, isDirectory: true)
    }
}

// MARK: - Bridge

@MainActor
public final class ClickyBrowserBridge: ObservableObject {
    public static let shared = ClickyBrowserBridge()

    public static let nativeHostName = "com.heyclicky.browser"
    public static let defaultExtensionID = "bphdnlcghkpiaoiplkhfofpfboddahce"

    private static let hasConnectedDefaultsKey = "clicky.browserConnection.hasConnected.v1"
    private static let lastBrowserDefaultsKey = "clicky.browserConnection.lastBrowser.v1"
    private static let selectedProfileDefaultsKey = "clicky.browserConnection.profile.v1"
    private static let pollLongWaitSeconds: TimeInterval = 20.0
    private static let sessionStaleSeconds: TimeInterval = 40.0

    public static let supportedBrowsers: [ClickyChromiumBrowserDescriptor] = [
        ClickyChromiumBrowserDescriptor(
            id: "google-chrome",
            displayName: "Google Chrome",
            bundleIdentifiers: ["com.google.Chrome"],
            applicationSupportSubpath: "Google/Chrome",
            extensionsPageURL: "chrome://extensions/",
            isPrimaryTarget: true
        ),
        ClickyChromiumBrowserDescriptor(
            id: "brave",
            displayName: "Brave",
            bundleIdentifiers: ["com.brave.Browser"],
            applicationSupportSubpath: "BraveSoftware/Brave-Browser",
            extensionsPageURL: "brave://extensions/",
            isPrimaryTarget: true
        ),
        ClickyChromiumBrowserDescriptor(
            id: "microsoft-edge",
            displayName: "Microsoft Edge",
            bundleIdentifiers: ["com.microsoft.edgemac"],
            applicationSupportSubpath: "Microsoft Edge",
            extensionsPageURL: "edge://extensions/",
            isPrimaryTarget: true
        ),
        ClickyChromiumBrowserDescriptor(
            id: "arc",
            displayName: "Arc",
            bundleIdentifiers: ["company.thebrowser.Browser"],
            applicationSupportSubpath: "Arc/User Data",
            extensionsPageURL: "arc://extensions/",
            isPrimaryTarget: true
        ),
        ClickyChromiumBrowserDescriptor(
            id: "vivaldi",
            displayName: "Vivaldi",
            bundleIdentifiers: ["com.vivaldi.Vivaldi"],
            applicationSupportSubpath: "Vivaldi",
            extensionsPageURL: "vivaldi://extensions/",
            isPrimaryTarget: true
        ),
        ClickyChromiumBrowserDescriptor(
            id: "chrome-beta",
            displayName: "Chrome Beta",
            bundleIdentifiers: ["com.google.Chrome.beta"],
            applicationSupportSubpath: "Google/Chrome Beta",
            extensionsPageURL: "chrome://extensions/",
            isPrimaryTarget: false
        ),
        ClickyChromiumBrowserDescriptor(
            id: "chrome-dev",
            displayName: "Chrome Dev",
            bundleIdentifiers: ["com.google.Chrome.dev"],
            applicationSupportSubpath: "Google/Chrome Dev",
            extensionsPageURL: "chrome://extensions/",
            isPrimaryTarget: false
        ),
        ClickyChromiumBrowserDescriptor(
            id: "chrome-canary",
            displayName: "Chrome Canary",
            bundleIdentifiers: ["com.google.Chrome.canary"],
            applicationSupportSubpath: "Google/Chrome Canary",
            extensionsPageURL: "chrome://extensions/",
            isPrimaryTarget: false
        ),
        ClickyChromiumBrowserDescriptor(
            id: "chromium",
            displayName: "Chromium",
            bundleIdentifiers: ["org.chromium.Chromium"],
            applicationSupportSubpath: "Chromium",
            extensionsPageURL: "chrome://extensions/",
            isPrimaryTarget: false
        )
    ]

    // MARK: Published State

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var connectedBrowsers: [String] = []
    @Published public private(set) var activeSessions: [ClickyBrowserSession] = []
    @Published public private(set) var profiles: [String] = []
    @Published public var selectedProfile: String? {
        didSet {
            UserDefaults.standard.set(selectedProfile, forKey: Self.selectedProfileDefaultsKey)
        }
    }
    @Published public private(set) var statusMessage: String = "Not connected"
    @Published public private(set) var hasEverConnected: Bool
    @Published public private(set) var lastBrowserName: String?
    @Published public private(set) var nativeHostSetupErrors: [ClickyBrowserNativeHostSetupError] = []
    @Published public private(set) var isBundledHelperPresent: Bool = false

    public var onExtensionConnected: ((ClickyBrowserSession) -> Void)?
    public var onConnectionChanged: ((Bool) -> Void)?

    // MARK: Internal Queues & Waiters

    private struct QueuedCommand {
        let id: String
        let name: String
        let arguments: [String: Any]
        let targetSession: String?
        let queuedAt: Date

        func toHostPayload(session: ClickyBrowserSession) -> [String: Any] {
            [
                "hasCommand": true,
                "ready": true,
                "app": true,
                "selected": session.selected,
                "id": id,
                "name": name,
                "operation": name,
                "arguments": arguments,
                "command": [
                    "id": id,
                    "name": name,
                    "operation": name,
                    "arguments": arguments
                ]
            ]
        }
    }

    private struct PollWaiter {
        let waiterID: UUID
        let session: String
        let continuation: CheckedContinuation<[String: Any], Never>
    }

    private struct PendingReply {
        let commandID: String
        let commandName: String
        let sessionID: String?
        let continuation: CheckedContinuation<[String: Any], Error>
    }

    private var sessionsByID: [String: ClickyBrowserSession] = [:]
    private var activePollWaiters: [String: PollWaiter] = [:]
    private var queuedCommands: [QueuedCommand] = []
    private var pendingReplies: [String: PendingReply] = [:]
    private var sweepTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        self.hasEverConnected = defaults.bool(forKey: Self.hasConnectedDefaultsKey)
        self.lastBrowserName = defaults.string(forKey: Self.lastBrowserDefaultsKey)
        self.selectedProfile = defaults.string(forKey: Self.selectedProfileDefaultsKey)
    }

    // MARK: - Lifecycle

    public func start() {
        installNativeMessagingHosts()
        do {
            try ClickyLoopbackMCPServer.shared.start()
        } catch {
            statusMessage = "Loopback server failed: \(error.localizedDescription)"
        }
        startSweepTaskIfNeeded()
    }

    public func stop() {
        sweepTask?.cancel()
        sweepTask = nil

        for (_, waiter) in activePollWaiters {
            waiter.continuation.resume(returning: ["selected": false, "app": false])
        }
        activePollWaiters.removeAll()

        for (_, pending) in pendingReplies {
            pending.continuation.resume(throwing: ClickyBrowserBridgeError.connectionChanged)
        }
        pendingReplies.removeAll()
        queuedCommands.removeAll()
        sessionsByID.removeAll()
        refreshPublishedSessionState()

        ClickyLoopbackMCPServer.shared.stop()
    }

    // MARK: - Native Messaging Host Installation

    public var bundledHelperPath: String {
        Bundle.main.bundlePath + "/Contents/Helpers/ClickyBrowserHost"
    }

    public func resolvedExtensionIDs() -> [String] {
        var origins: [String] = []
        if let idURL = Bundle.main.url(forResource: "ClickyBrowserExtensionID", withExtension: "txt"),
           let text = try? String(contentsOf: idURL, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                origins.append(trimmed)
            }
        }
        if origins.isEmpty {
            origins.append(Self.defaultExtensionID)
        }
        if let devURL = Bundle.main.url(forResource: "ClickyBrowserExtensionDevelopmentID", withExtension: "txt"),
           let devText = try? String(contentsOf: devURL, encoding: .utf8) {
            let trimmed = devText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !origins.contains(trimmed) {
                origins.append(trimmed)
            }
        }
        return origins
    }

    public func installNativeMessagingHosts() {
        let fileManager = FileManager.default
        let helperPath = bundledHelperPath
        isBundledHelperPresent = fileManager.isExecutableFile(atPath: helperPath)

        let allowedOrigins = resolvedExtensionIDs().map { "chrome-extension://\($0)/" }
        let manifestObject: [String: Any] = [
            "name": Self.nativeHostName,
            "description": "HeyClicky browser connection",
            "path": helperPath,
            "type": "stdio",
            "allowed_origins": allowedOrigins
        ]

        guard let manifestData = try? JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }

        var errors: [ClickyBrowserNativeHostSetupError] = []

        for browser in Self.supportedBrowsers {
            let userDataExists = fileManager.fileExists(atPath: browser.userDataDirectory().path)
            let appInstalled = isBrowserInstalled(browser)
            // Always write the 5 primary browser manifests (Chrome, Brave, Edge, Arc, Vivaldi);
            // write secondary variants (Beta/Dev/Canary/Chromium) when present.
            guard browser.isPrimaryTarget || userDataExists || appInstalled else {
                continue
            }

            let hostsDirectory = browser.nativeMessagingHostsDirectory()
            let manifestURL = browser.manifestURL()

            do {
                try fileManager.createDirectory(at: hostsDirectory, withIntermediateDirectories: true, attributes: nil)
                if let existingData = try? Data(contentsOf: manifestURL), existingData == manifestData {
                    continue
                }
                try manifestData.write(to: manifestURL, options: [.atomic])
            } catch {
                errors.append(
                    ClickyBrowserNativeHostSetupError(
                        browserName: browser.displayName,
                        folderPath: hostsDirectory.path,
                        underlying: error
                    )
                )
            }
        }

        nativeHostSetupErrors = errors
    }

    public func verifyNativeMessagingHosts() -> [String: Bool] {
        let fileManager = FileManager.default
        let expectedPath = bundledHelperPath
        let expectedOrigin = "chrome-extension://\(resolvedExtensionIDs().first ?? Self.defaultExtensionID)/"

        var results: [String: Bool] = [:]
        for browser in Self.supportedBrowsers where browser.isPrimaryTarget {
            let manifestURL = browser.manifestURL()
            guard let data = try? Data(contentsOf: manifestURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hostPath = json["path"] as? String,
                  let origins = json["allowed_origins"] as? [String],
                  hostPath == expectedPath,
                  origins.contains(expectedOrigin),
                  fileManager.fileExists(atPath: manifestURL.path) else {
                results[browser.displayName] = false
                continue
            }
            results[browser.displayName] = true
        }
        return results
    }

    public func installedChromiumBrowsers() -> [ClickyChromiumBrowserDescriptor] {
        let fileManager = FileManager.default
        return Self.supportedBrowsers.filter { browser in
            isBrowserInstalled(browser) || fileManager.fileExists(atPath: browser.userDataDirectory().path)
        }
    }

    public func isBrowserInstalled(_ browser: ClickyChromiumBrowserDescriptor) -> Bool {
        for bundleID in browser.bundleIdentifiers {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Command Dispatch (App -> Extension)

    public func dispatchBrowserCommand(
        name: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        try await dispatchBrowserCommand(name: name, arguments: arguments, session: nil, timeoutSeconds: 60.0)
    }

    public func dispatchBrowserCommand(
        name: String,
        arguments: [String: Any],
        session targetSessionID: String? = nil,
        timeoutSeconds: TimeInterval = 60.0
    ) async throws -> [String: Any] {
        sweepStaleSessions()

        guard let targetSession = selectTargetSession(preferredSessionID: targetSessionID) else {
            throw ClickyBrowserBridgeError.notConnected
        }

        let commandID = UUID().uuidString
        let command = QueuedCommand(
            id: commandID,
            name: name,
            arguments: arguments,
            targetSession: targetSession.session,
            queuedAt: Date()
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { replyContinuation in
                pendingReplies[commandID] = PendingReply(
                    commandID: commandID,
                    commandName: name,
                    sessionID: targetSession.session,
                    continuation: replyContinuation
                )

                // Wake a waiting browser_poll immediately if one is parked for this session
                if let waiter = activePollWaiters.removeValue(forKey: targetSession.session) {
                    waiter.continuation.resume(returning: command.toHostPayload(session: targetSession))
                } else {
                    queuedCommands.append(command)
                }

                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(1.0, timeoutSeconds) * 1_000_000_000))
                    guard let self else { return }
                    if let timedOutReply = self.pendingReplies.removeValue(forKey: commandID) {
                        self.queuedCommands.removeAll { $0.id == commandID }
                        timedOutReply.continuation.resume(
                            throwing: ClickyBrowserBridgeError.commandTimedOut(name: name, seconds: timeoutSeconds)
                        )
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.queuedCommands.removeAll { $0.id == commandID }
                if let cancelled = self.pendingReplies.removeValue(forKey: commandID) {
                    cancelled.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    // MARK: - Host Poll & Reply Handlers (Extension -> App)

    public func handleBrowserPoll(arguments: [String: Any]) async -> [String: Any] {
        let sessionID = nonEmptyString(arguments["session"])
            ?? nonEmptyString(arguments["profile"])
            ?? "default"
        let profile = nonEmptyString(arguments["profile"]) ?? "Default"
        let browser = nonEmptyString(arguments["browser"]) ?? "Google Chrome"
        let extensionVersion = nonEmptyString(arguments["extension"]) ?? "unknown"
        let tabId = intValue(arguments["tabId"])
        let selected = (arguments["selected"] as? Bool) ?? isSessionSelected(sessionID: sessionID, profile: profile)

        let wasConnected = isConnected
        let isNewSession = sessionsByID[sessionID] == nil

        let updatedSession = ClickyBrowserSession(
            session: sessionID,
            profile: profile,
            browser: browser,
            extensionVersion: extensionVersion,
            tabId: tabId,
            selected: selected,
            lastSeen: Date()
        )
        sessionsByID[sessionID] = updatedSession
        recordConnectionMetadata(browser: browser)
        refreshPublishedSessionState()

        if isNewSession {
            onExtensionConnected?(updatedSession)
        }
        if !wasConnected && isConnected {
            onConnectionChanged?(true)
        }

        // Check if there is already a queued command for this session
        if let commandIndex = queuedCommands.firstIndex(where: { $0.targetSession == nil || $0.targetSession == sessionID }) {
            let command = queuedCommands.remove(at: commandIndex)
            return command.toHostPayload(session: updatedSession)
        }

        // Supersede any existing poll waiter for this session before parking
        if let previousWaiter = activePollWaiters.removeValue(forKey: sessionID) {
            previousWaiter.continuation.resume(returning: heartbeatPayload(for: updatedSession))
        }

        let waiterID = UUID()
        let result: [String: Any] = await withCheckedContinuation { continuation in
            activePollWaiters[sessionID] = PollWaiter(
                waiterID: waiterID,
                session: sessionID,
                continuation: continuation
            )

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.pollLongWaitSeconds * 1_000_000_000))
                guard let self else { return }
                if let currentWaiter = self.activePollWaiters[sessionID],
                   currentWaiter.waiterID == waiterID {
                    self.activePollWaiters.removeValue(forKey: sessionID)
                    let latestSession = self.sessionsByID[sessionID] ?? updatedSession
                    currentWaiter.continuation.resume(returning: self.heartbeatPayload(for: latestSession))
                }
            }
        }

        // Refresh lastSeen when poll returns
        if var latest = sessionsByID[sessionID] {
            latest = ClickyBrowserSession(
                session: latest.session,
                profile: latest.profile,
                browser: latest.browser,
                extensionVersion: latest.extensionVersion,
                tabId: latest.tabId,
                selected: latest.selected,
                lastSeen: Date()
            )
            sessionsByID[sessionID] = latest
        }

        return result
    }

    public func handleBrowserReply(arguments: [String: Any]) -> [String: Any] {
        if let sessionID = nonEmptyString(arguments["session"]), var session = sessionsByID[sessionID] {
            session = ClickyBrowserSession(
                session: session.session,
                profile: session.profile,
                browser: session.browser,
                extensionVersion: session.extensionVersion,
                tabId: intValue(arguments["tabId"]) ?? session.tabId,
                selected: session.selected,
                lastSeen: Date()
            )
            sessionsByID[sessionID] = session
        }

        let commandID = nonEmptyString(arguments["id"])
            ?? nonEmptyString(arguments["commandId"])
            ?? nonEmptyString(arguments["requestId"])

        guard let commandID, let pending = pendingReplies.removeValue(forKey: commandID) else {
            return ["ok": false, "reason": "unknown_command_id"]
        }

        if let errorText = nonEmptyString(arguments["error"]) {
            pending.continuation.resume(throwing: ClickyBrowserBridgeError.remoteCommandFailed(errorText))
        } else if let resultDict = arguments["result"] as? [String: Any] {
            pending.continuation.resume(returning: resultDict)
        } else {
            var fallback = arguments
            fallback.removeValue(forKey: "id")
            fallback.removeValue(forKey: "commandId")
            fallback.removeValue(forKey: "requestId")
            pending.continuation.resume(returning: fallback)
        }

        return ["ok": true]
    }

    // MARK: - Helpers

    private func selectTargetSession(preferredSessionID: String?) -> ClickyBrowserSession? {
        if let preferredSessionID, let exact = sessionsByID[preferredSessionID] {
            return exact
        }
        let sorted = sessionsByID.values.sorted { lhs, rhs in
            if lhs.selected != rhs.selected { return lhs.selected }
            return lhs.lastSeen > rhs.lastSeen
        }
        return sorted.first
    }

    private func isSessionSelected(sessionID: String, profile: String) -> Bool {
        if let selectedProfile, !selectedProfile.isEmpty {
            return selectedProfile == profile || selectedProfile == sessionID
        }
        return sessionsByID.isEmpty || sessionsByID[sessionID]?.selected == true
    }

    private func heartbeatPayload(for session: ClickyBrowserSession) -> [String: Any] {
        [
            "selected": session.selected,
            "app": true,
            "ready": true
        ]
    }

    private func recordConnectionMetadata(browser: String) {
        let defaults = UserDefaults.standard
        if !hasEverConnected {
            hasEverConnected = true
            defaults.set(true, forKey: Self.hasConnectedDefaultsKey)
        }
        if lastBrowserName != browser {
            lastBrowserName = browser
            defaults.set(browser, forKey: Self.lastBrowserDefaultsKey)
        }
    }

    private func refreshPublishedSessionState() {
        let orderedSessions = sessionsByID.values.sorted { $0.lastSeen > $1.lastSeen }
        activeSessions = orderedSessions

        var seenBrowsers = Set<String>()
        var uniqueBrowsers: [String] = []
        var seenProfiles = Set<String>()
        var uniqueProfiles: [String] = []

        for session in orderedSessions {
            if seenBrowsers.insert(session.browser).inserted {
                uniqueBrowsers.append(session.browser)
            }
            if seenProfiles.insert(session.profile).inserted {
                uniqueProfiles.append(session.profile)
            }
        }

        connectedBrowsers = uniqueBrowsers
        profiles = uniqueProfiles

        let connectedNow = !orderedSessions.isEmpty
        if isConnected != connectedNow {
            isConnected = connectedNow
        }

        if let primary = uniqueBrowsers.first {
            statusMessage = "Chrome connected (\(primary))"
        } else {
            statusMessage = "Not connected"
        }
    }

    private func startSweepTaskIfNeeded() {
        guard sweepTask == nil else { return }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.sweepStaleSessions()
            }
        }
    }

    private func sweepStaleSessions() {
        let now = Date()
        var removedSessionIDs: [String] = []

        for (sessionID, session) in sessionsByID {
            let hasActivePoll = activePollWaiters[sessionID] != nil
            if !hasActivePoll && now.timeIntervalSince(session.lastSeen) > Self.sessionStaleSeconds {
                removedSessionIDs.append(sessionID)
            }
        }

        guard !removedSessionIDs.isEmpty else { return }
        let wasConnected = isConnected
        for sessionID in removedSessionIDs {
            sessionsByID.removeValue(forKey: sessionID)
        }
        refreshPublishedSessionState()
        if wasConnected && !isConnected {
            onConnectionChanged?(false)
        }
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let numVal = value as? NSNumber { return numVal.intValue }
        return nil
    }
}
