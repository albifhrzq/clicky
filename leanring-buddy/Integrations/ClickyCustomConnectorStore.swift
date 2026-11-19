//
//  ClickyCustomConnectorStore.swift
//  leanring-buddy
//
//  User-defined MCP connectors (hosted URL or a command on this Mac). The connector list
//  lives in UserDefaults; every secret (token, env values, extra headers) lives only in
//  the Keychain and is never logged. OAuth sign-in is intentionally deferred.
//

import Combine
import Foundation

// MARK: - Model

nonisolated enum ClickyConnectorTransport: String, Codable, Sendable, CaseIterable {
    case command
    case remote
}

nonisolated struct ClickyCustomConnector: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var transport: ClickyConnectorTransport
    var command: String
    var arguments: [String]
    var url: String
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        transport: ClickyConnectorTransport,
        command: String = "",
        arguments: [String] = [],
        url: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.isEnabled = isEnabled
    }

    /// Key used in the `mcpServers` dictionary and as the runner's server name.
    var serverKey: String { ClickyConnectorParsing.serverKey(forName: name) }
}

nonisolated struct ClickyKeyValuePair: Equatable, Sendable {
    let key: String
    let value: String
}

// MARK: - Validation issues (user-facing copy)

nonisolated enum ClickyConnectorIssue: Equatable, Sendable {
    case missingName
    case reservedName
    case duplicateName
    case invalidURL
    case credentialsInURL
    case missingCommand
    case invalidHeaderName(String)
    case invalidEnvironmentName(String)
    case environmentNameInUse(connectorName: String, key: String)
    case commandNotFound(String)
    case unbalancedQuotes
    case keychainSaveFailed
    case missingAPIKey

    var message: String {
        switch self {
        case .missingName:
            return String(localized: "Give the connector a name.")
        case .reservedName:
            return String(localized: "That name is reserved. Pick a name that doesn't start with clicky.")
        case .duplicateName:
            return String(localized: "You already have a connector with that name.")
        case .invalidURL:
            return String(localized: "Enter the server's full URL, starting with https://.")
        case .credentialsInURL:
            return String(localized: "Remove credentials from the URL and use the authentication fields.")
        case .missingCommand:
            return String(localized: "Enter the command that starts the server.")
        case .invalidHeaderName(let key):
            return String(localized: "\"\(key)\" is not a valid header name.")
        case .invalidEnvironmentName(let key):
            return String(localized: "\"\(key)\" is not a valid environment variable name.")
        case .environmentNameInUse(let connectorName, let key):
            return String(localized: "\(connectorName) already uses \(key). Use different environment variable names or remove that connector first.")
        case .commandNotFound(let command):
            return String(localized: "\"\(command)\" wasn't found on this Mac. Use the full path, or install it first.")
        case .unbalancedQuotes:
            return String(localized: "The arguments have an unclosed quote.")
        case .keychainSaveFailed:
            return String(localized: "Your Mac's keychain didn't save this connector's sign-in. Unlock your login keychain and try again.")
        case .missingAPIKey:
            return String(localized: "Paste the API key, or pick a different authentication.")
        }
    }
}

/// Non-blocking notes shown next to the form.
nonisolated enum ClickyConnectorWarning: Equatable, Sendable {
    case plainHTTP

    var message: String {
        switch self {
        case .plainHTTP:
            return String(localized: "This server uses plain http, so its traffic is not encrypted.")
        }
    }
}

// MARK: - Pure parsers & validators

nonisolated enum ClickyConnectorParsing {
    static let reservedNamePrefix = "clicky"

    /// Lowercased slug of the display name; stable and safe as an MCP server name.
    static func serverKey(forName name: String) -> String {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var slug = ""
        var previousWasSeparator = false
        for character in lowered {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
                previousWasSeparator = false
            } else if !previousWasSeparator && !slug.isEmpty {
                slug.append("-")
                previousWasSeparator = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    /// Shell-style tokenizer: whitespace separates, single/double quotes group,
    /// backslash escapes outside single quotes. Returns nil on an unclosed quote.
    static func tokenizeArguments(_ text: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var activeQuote: Character?
        var isEscaping = false

        for character in text {
            if isEscaping {
                current.append(character)
                hasToken = true
                isEscaping = false
                continue
            }
            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                } else if character == "\\" && quote == "\"" {
                    isEscaping = true
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\"", "'":
                activeQuote = character
                hasToken = true
            case "\\":
                isEscaping = true
            case " ", "\t", "\n", "\r":
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                current.append(character)
                hasToken = true
            }
        }
        if activeQuote != nil || isEscaping { return nil }
        if hasToken { tokens.append(current) }
        return tokens
    }

    static func isValidEnvironmentName(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let isLetterOrUnderscore: (Unicode.Scalar) -> Bool = {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "_"
        }
        guard isLetterOrUnderscore(first) else { return false }
        return key.unicodeScalars.allSatisfy { isLetterOrUnderscore($0) || ($0.value >= 48 && $0.value <= 57) }
    }

    static func isValidHeaderName(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let allowedPunctuation = Set("!#$%&'*+-.^_`|~")
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || allowedPunctuation.contains($0)) }
    }

    /// One `KEY=value` per line. Blank lines and `#` comments are skipped.
    static func parseEnvironment(_ text: String) -> (pairs: [ClickyKeyValuePair], issue: ClickyConnectorIssue?) {
        var pairs: [ClickyKeyValuePair] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard parts.count == 2, isValidEnvironmentName(key) else {
                return (pairs, .invalidEnvironmentName(key.isEmpty ? line : key))
            }
            pairs.append(ClickyKeyValuePair(key: key, value: parts[1].trimmingCharacters(in: .whitespaces)))
        }
        return (pairs, nil)
    }

    /// One `Header: value` per line.
    static func parseHeaders(_ text: String) -> (pairs: [ClickyKeyValuePair], issue: ClickyConnectorIssue?) {
        var pairs: [ClickyKeyValuePair] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard parts.count == 2, isValidHeaderName(key) else {
                return (pairs, .invalidHeaderName(key.isEmpty ? line : key))
            }
            pairs.append(ClickyKeyValuePair(key: key, value: parts[1].trimmingCharacters(in: .whitespaces)))
        }
        return (pairs, nil)
    }

    /// Returns the first problem with the display name, or nil.
    static func validateName(_ name: String, editingID: String?, existing: [ClickyCustomConnector]) -> ClickyConnectorIssue? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = serverKey(forName: trimmed)
        if trimmed.isEmpty || key.isEmpty { return .missingName }
        // "clicky" is the built-in server; "clicky_" names also suppress the runner's
        // "couldn't reach one of your connectors" note.
        if trimmed.lowercased().hasPrefix(reservedNamePrefix) || key.lowercased().hasPrefix(reservedNamePrefix) { return .reservedName }
        let clash = existing.contains { $0.id != editingID && $0.serverKey == key }
        return clash ? .duplicateName : nil
    }

    /// Validates a remote URL. Errors are blocking; `.plainHTTP` is only a warning.
    static func validateRemoteURL(_ rawURL: String) -> (issue: ClickyConnectorIssue?, warning: ClickyConnectorWarning?) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else {
            return (.invalidURL, nil)
        }
        if components.user != nil || components.password != nil { return (.credentialsInURL, nil) }
        let secretQueryNames: Set<String> = ["token", "access_token", "api_key", "apikey", "key", "secret", "password"]
        if (components.queryItems ?? []).contains(where: { secretQueryNames.contains($0.name.lowercased()) }) {
            return (.credentialsInURL, nil)
        }
        return (nil, scheme == "http" ? .plainHTTP : nil)
    }

    /// Environment names already used by other connectors (cross-connector clash check).
    static func environmentClash(
        newKeys: [String],
        editingID: String?,
        existingKeysByConnector: [(connector: ClickyCustomConnector, keys: [String])]
    ) -> ClickyConnectorIssue? {
        for entry in existingKeysByConnector where entry.connector.id != editingID {
            if let shared = newKeys.first(where: { entry.keys.contains($0) }) {
                return .environmentNameInUse(connectorName: entry.connector.name, key: shared)
            }
        }
        return nil
    }
}

// MARK: - 30-minute "Not now" gate (pure)

nonisolated enum ClickyNotNowGate {
    static let blockDuration: TimeInterval = 30 * 60
    /// Shown to the agent when an upload request is auto-declined because of an earlier "Not now".
    static let agentDeclineMessage = "The user chose Not now for file uploads recently; don't ask again for a while."

    static func isBlocked(blockedAt: Date?, now: Date = Date()) -> Bool {
        guard let blockedAt else { return false }
        let elapsed = now.timeIntervalSince(blockedAt)
        return elapsed >= 0 && elapsed < blockDuration
    }
}

// MARK: - Command resolution

nonisolated enum ClickyConnectorCommandResolver {
    /// Absolute paths (or ~/) are checked directly. Anything else is looked up through a
    /// login shell so PATH entries from the user's profile (nvm, homebrew) are honoured.
    static func resolve(_ command: String) async -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // The command name is passed as $0 so it is never interpreted by the shell.
            process.arguments = ["-lc", "command -v -- \"$0\"", trimmed]
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lastLine = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return lastLine.hasPrefix("/") ? lastLine : nil
        }.value
    }
}

// MARK: - Store

@MainActor
final class ClickyCustomConnectorStore: ObservableObject {
    static let shared = ClickyCustomConnectorStore()

    private static let defaultsKey = "clicky.customConnectors.v1"

    @Published private(set) var connectors: [ClickyCustomConnector]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([ClickyCustomConnector].self, from: data) {
            connectors = decoded
        } else {
            connectors = []
        }
    }

    // Keychain account names (secrets never touch UserDefaults).
    private static func tokenKey(_ id: String) -> String { "mcp.\(id).token" }
    private static func envKey(_ id: String) -> String { "mcp.\(id).env" }
    private static func headersKey(_ id: String) -> String { "mcp.\(id).headers" }

    func token(for id: String) -> String { ClickyKeychainStore.read(key: Self.tokenKey(id)) ?? "" }
    func environmentText(for id: String) -> String { ClickyKeychainStore.read(key: Self.envKey(id)) ?? "" }
    func headersText(for id: String) -> String { ClickyKeychainStore.read(key: Self.headersKey(id)) ?? "" }

    /// Environment variable names (not values) for the cross-connector clash check.
    func environmentNamesByConnector() -> [(connector: ClickyCustomConnector, keys: [String])] {
        connectors.map { connector in
            (connector, ClickyConnectorParsing.parseEnvironment(environmentText(for: connector.id)).pairs.map(\.key))
        }
    }

    /// Validates everything, then writes the connector and its secrets.
    /// Returns the first blocking issue, or nil on success.
    func save(
        _ connector: ClickyCustomConnector,
        token: String,
        environmentText: String,
        headersText: String,
        requiresToken: Bool
    ) async -> ClickyConnectorIssue? {
        var candidate = connector
        candidate.name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)

        if let issue = ClickyConnectorParsing.validateName(candidate.name, editingID: candidate.id, existing: connectors) {
            return issue
        }
        let headerResult = ClickyConnectorParsing.parseHeaders(headersText)
        let environmentResult = ClickyConnectorParsing.parseEnvironment(environmentText)

        switch candidate.transport {
        case .remote:
            candidate.url = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines)
            candidate.command = ""
            candidate.arguments = []
            if let issue = ClickyConnectorParsing.validateRemoteURL(candidate.url).issue { return issue }
            if let issue = headerResult.issue { return issue }
            if requiresToken && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingAPIKey }
        case .command:
            candidate.url = ""
            candidate.command = candidate.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.command.isEmpty { return .missingCommand }
            if let issue = environmentResult.issue { return issue }
            if let issue = ClickyConnectorParsing.environmentClash(
                newKeys: environmentResult.pairs.map(\.key),
                editingID: candidate.id,
                existingKeysByConnector: environmentNamesByConnector()
            ) { return issue }
            // Store the resolved absolute path: the runner's PATH is not the user's login PATH.
            guard let resolvedCommand = await ClickyConnectorCommandResolver.resolve(candidate.command) else {
                return .commandNotFound(candidate.command)
            }
            candidate.command = resolvedCommand
        }

        let isRemote = candidate.transport == .remote
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let didSaveSecrets =
            ClickyKeychainStore.save(key: Self.tokenKey(candidate.id), value: isRemote ? trimmedToken : "")
            && ClickyKeychainStore.save(key: Self.headersKey(candidate.id), value: isRemote ? headersText : "")
            && ClickyKeychainStore.save(key: Self.envKey(candidate.id), value: isRemote ? "" : environmentText)
        guard didSaveSecrets else { return .keychainSaveFailed }

        var updated = connectors
        if let index = updated.firstIndex(where: { $0.id == candidate.id }) {
            updated[index] = candidate
        } else {
            updated.append(candidate)
        }
        persist(updated)
        return nil
    }

    func setEnabled(_ isEnabled: Bool, for id: String) {
        persist(connectors.map { connector in
            var copy = connector
            if copy.id == id { copy.isEnabled = isEnabled }
            return copy
        })
    }

    func delete(id: String) {
        ClickyKeychainStore.delete(key: Self.tokenKey(id))
        ClickyKeychainStore.delete(key: Self.envKey(id))
        ClickyKeychainStore.delete(key: Self.headersKey(id))
        persist(connectors.filter { $0.id != id })
    }

    private func persist(_ updated: [ClickyCustomConnector]) {
        connectors = updated
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Entries merged into the `mcpServers` dictionary handed to the agent runner.
    /// `optional: true` lets a job continue when a user's own server is unreachable.
    func agentMCPServerEntries() -> [String: [String: Any]] {
        var entries: [String: [String: Any]] = [:]
        for connector in connectors where connector.isEnabled {
            let key = connector.serverKey
            guard !key.isEmpty, !key.hasPrefix("clicky") else { continue }
            var entry: [String: Any] = ["name": key, "optional": true]
            switch connector.transport {
            case .remote:
                guard !connector.url.isEmpty else { continue }
                entry["url"] = connector.url
                let tokenValue = token(for: connector.id)
                if !tokenValue.isEmpty { entry["token"] = tokenValue }
                let headers = ClickyConnectorParsing.parseHeaders(headersText(for: connector.id)).pairs
                if !headers.isEmpty {
                    entry["headers"] = Dictionary(headers.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
                }
            case .command:
                guard !connector.command.isEmpty else { continue }
                entry["command"] = connector.command
                if !connector.arguments.isEmpty { entry["args"] = connector.arguments }
                let environment = ClickyConnectorParsing.parseEnvironment(environmentText(for: connector.id)).pairs
                if !environment.isEmpty {
                    entry["env"] = Dictionary(environment.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
                }
            }
            entries[key] = entry
        }
        return entries
    }
}
