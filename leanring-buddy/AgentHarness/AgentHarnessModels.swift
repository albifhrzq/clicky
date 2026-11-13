//
//  AgentHarnessModels.swift
//  leanring-buddy
//

import Foundation

public nonisolated struct AgentPlanStep: Sendable, Equatable, Codable {
    public let step: String
    public let status: String

    public init(step: String, status: String) {
        self.step = step
        self.status = status
    }
}

public nonisolated struct AgentMCPServerStatus: Sendable, Equatable, Codable {
    public let server: String
    public let ok: Bool
    public let tools: Int
    public let error: String?

    public init(server: String, ok: Bool, tools: Int, error: String? = nil) {
        self.server = server
        self.ok = ok
        self.tools = tools
        self.error = error
    }
}

public nonisolated struct AgentTurnStats: Sendable, Equatable, Codable {
    public let rounds: Int
    public let modelMs: Int
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let toolCalls: Int
    public let toolErrors: Int
    public let earlyStarts: Int
    public let compactions: Int

    public init(
        rounds: Int = 0,
        modelMs: Int = 0,
        inputTokens: Int = 0,
        cachedTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        toolCalls: Int = 0,
        toolErrors: Int = 0,
        earlyStarts: Int = 0,
        compactions: Int = 0
    ) {
        self.rounds = rounds
        self.modelMs = modelMs
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.toolCalls = toolCalls
        self.toolErrors = toolErrors
        self.earlyStarts = earlyStarts
        self.compactions = compactions
    }
}

public nonisolated struct AgentParsedCompletion: Sendable, Equatable {
    public let rawText: String
    public let summary: String?
    public let answer: String?
    public let artifacts: [String]
    public let artifactsRaw: String?
    public let doneTitle: String?
    public let nextActions: [String]
    public let nextActionsRaw: String?
    public let routine: String?
    public let computerUseRequest: String?
    public let waitFor: String?
    public let learned: String?
    public let displayBody: String

    public init(
        rawText: String,
        summary: String? = nil,
        answer: String? = nil,
        artifacts: [String] = [],
        artifactsRaw: String? = nil,
        doneTitle: String? = nil,
        nextActions: [String] = [],
        nextActionsRaw: String? = nil,
        routine: String? = nil,
        computerUseRequest: String? = nil,
        waitFor: String? = nil,
        learned: String? = nil,
        displayBody: String? = nil
    ) {
        self.rawText = rawText
        self.summary = summary
        self.answer = answer
        self.artifacts = artifacts
        self.artifactsRaw = artifactsRaw
        self.doneTitle = doneTitle
        self.nextActions = nextActions
        self.nextActionsRaw = nextActionsRaw
        self.routine = routine
        self.computerUseRequest = computerUseRequest
        self.waitFor = waitFor
        self.learned = learned
        self.displayBody = displayBody ?? answer ?? summary ?? rawText
    }
}

public nonisolated enum AgentCompletionXMLParser {
    private static let knownTagNames: [String] = [
        "SUMMARY",
        "ANSWER",
        "ARTIFACTS",
        "DONE_TITLE",
        "NEXT_ACTIONS",
        "ROUTINE",
        "COMPUTER_USE_REQUEST",
        "WAIT_FOR",
        "LEARNED"
    ]

    public static func parse(_ rawText: String) -> AgentParsedCompletion {
        let summary = extractTag("SUMMARY", from: rawText)
        let answer = extractTag("ANSWER", from: rawText)
        let artifactsRaw = extractTag("ARTIFACTS", from: rawText)
        let doneTitle = extractTag("DONE_TITLE", from: rawText)
        let nextActionsRaw = extractTag("NEXT_ACTIONS", from: rawText)
        let routine = extractTag("ROUTINE", from: rawText)
        let computerUseRequest = extractTag("COMPUTER_USE_REQUEST", from: rawText)
        let waitFor = extractTag("WAIT_FOR", from: rawText)
        let learned = extractTag("LEARNED", from: rawText)

        let artifacts = parseListItems(from: artifactsRaw)
        let nextActions = parseListItems(from: nextActionsRaw)
        let stripped = stripKnownTags(from: rawText)
        let preferredDisplay = [answer, summary, stripped.isEmpty ? rawText.trimmingCharacters(in: .whitespacesAndNewlines) : stripped]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""

        return AgentParsedCompletion(
            rawText: rawText,
            summary: summary,
            answer: answer,
            artifacts: artifacts,
            artifactsRaw: artifactsRaw,
            doneTitle: doneTitle,
            nextActions: nextActions,
            nextActionsRaw: nextActionsRaw,
            routine: routine,
            computerUseRequest: computerUseRequest,
            waitFor: waitFor,
            learned: learned,
            displayBody: preferredDisplay
        )
    }

    public static func extractTag(_ tagName: String, from text: String) -> String? {
        let escapedTag = NSRegularExpression.escapedPattern(for: tagName)
        let pattern = "<\(escapedTag)(?:\\s[^>]*)?>([\\s\\S]*?)</\(escapedTag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let contentRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let extracted = String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? nil : extracted
    }

    private static func parseListItems(from rawBlock: String?) -> [String] {
        guard let rawBlock, !rawBlock.isEmpty else {
            return []
        }

        // Support either nested <item>/<artifact>/<action> elements or newline/bullet-separated text
        let nestedTagPattern = "<(?:item|artifact|action|path)(?:\\s[^>]*)?>([\\s\\S]*?)</(?:item|artifact|action|path)>"
        if let regex = try? NSRegularExpression(pattern: nestedTagPattern, options: [.caseInsensitive]) {
            let range = NSRange(rawBlock.startIndex..<rawBlock.endIndex, in: rawBlock)
            let matches = regex.matches(in: rawBlock, options: [], range: range)
            if !matches.isEmpty {
                return matches.compactMap { match in
                    guard match.numberOfRanges >= 2,
                          let contentRange = Range(match.range(at: 1), in: rawBlock) else {
                        return nil
                    }
                    let cleaned = String(rawBlock[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return cleaned.isEmpty ? nil : cleaned
                }
            }
        }

        return rawBlock
            .components(separatedBy: .newlines)
            .map { line in
                var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in ["- ", "* ", "• "] {
                    if trimmed.hasPrefix(prefix) {
                        trimmed = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
    }

    private static func stripKnownTags(from text: String) -> String {
        var cleaned = text
        for tagName in knownTagNames {
            let escapedTag = NSRegularExpression.escapedPattern(for: tagName)
            let pattern = "<\(escapedTag)(?:\\s[^>]*)?>[\\s\\S]*?</\(escapedTag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public nonisolated struct AgentHarnessEvent: Sendable, Equatable {
    public nonisolated enum Payload: Sendable, Equatable {
        case commentary(text: String)
        case thinking(text: String)
        case tool(phase: String, id: String, name: String, server: String?, command: String?, query: String?, url: String?)
        case batch(id: String, searchesCount: Int, searchesDone: Int, searchesQuery: String?, siteCount: Int, sitesDone: Int)
        case plan(steps: [AgentPlanStep])
        case compacted
        case note(phase: String, path: String, text: String?)
        case appsUnreachable
        case toolsListed(servers: [AgentMCPServerStatus])
        case log(text: String)
        case answer(text: String, parsed: AgentParsedCompletion)
        case stats(AgentTurnStats)
        case turnEnd(status: String, error: String?)
        case unknown(kind: String, rawJSON: String)
    }

    public let seq: Int
    public let timestamp: Date
    public let turnRef: String?
    public let payload: Payload

    public init(seq: Int, timestamp: Date, turnRef: String?, payload: Payload) {
        self.seq = seq
        self.timestamp = timestamp
        self.turnRef = turnRef
        self.payload = payload
    }

    public static func from(dictionary: [String: Any]) -> AgentHarnessEvent? {
        guard let kind = dictionary["kind"] as? String else {
            return nil
        }

        let seq = (dictionary["seq"] as? NSNumber)?.intValue ?? 0
        let epochMs = (dictionary["t"] as? NSNumber)?.doubleValue ?? (Date().timeIntervalSince1970 * 1000.0)
        let timestamp = Date(timeIntervalSince1970: epochMs / 1000.0)
        let turnRef = dictionary["turnRef"] as? String

        let payload: Payload
        switch kind {
        case "commentary":
            payload = .commentary(text: dictionary["text"] as? String ?? "")
        case "thinking":
            payload = .thinking(text: dictionary["text"] as? String ?? "")
        case "tool":
            payload = .tool(
                phase: dictionary["phase"] as? String ?? "start",
                id: dictionary["id"] as? String ?? "",
                name: dictionary["name"] as? String ?? "",
                server: dictionary["server"] as? String,
                command: dictionary["command"] as? String,
                query: dictionary["query"] as? String,
                url: dictionary["url"] as? String
            )
        case "batch":
            let searches = dictionary["searches"] as? [String: Any] ?? [:]
            payload = .batch(
                id: dictionary["id"] as? String ?? "",
                searchesCount: (searches["count"] as? NSNumber)?.intValue ?? 0,
                searchesDone: (searches["done"] as? NSNumber)?.intValue ?? 0,
                searchesQuery: searches["query"] as? String,
                siteCount: (dictionary["siteCount"] as? NSNumber)?.intValue ?? 0,
                sitesDone: (dictionary["sitesDone"] as? NSNumber)?.intValue ?? 0
            )
        case "plan":
            let rawPlan = dictionary["plan"] as? [[String: Any]] ?? []
            let steps = rawPlan.map { entry in
                AgentPlanStep(
                    step: entry["step"] as? String ?? "",
                    status: entry["status"] as? String ?? "pending"
                )
            }
            payload = .plan(steps: steps)
        case "compaction", "compacted":
            payload = .compacted
        case "note":
            payload = .note(
                phase: dictionary["phase"] as? String ?? "saved",
                path: dictionary["path"] as? String ?? "",
                text: dictionary["text"] as? String
            )
        case "apps_unreachable":
            payload = .appsUnreachable
        case "tools_listed":
            let rawServers = dictionary["servers"] as? [[String: Any]] ?? []
            let servers = rawServers.map { entry in
                AgentMCPServerStatus(
                    server: entry["server"] as? String ?? "",
                    ok: entry["ok"] as? Bool ?? false,
                    tools: (entry["tools"] as? NSNumber)?.intValue ?? 0,
                    error: entry["error"] as? String
                )
            }
            payload = .toolsListed(servers: servers)
        case "log":
            payload = .log(text: dictionary["text"] as? String ?? "")
        case "answer":
            let text = dictionary["text"] as? String ?? ""
            payload = .answer(text: text, parsed: AgentCompletionXMLParser.parse(text))
        case "stats":
            let stats = AgentTurnStats(
                rounds: (dictionary["rounds"] as? NSNumber)?.intValue ?? 0,
                modelMs: (dictionary["modelMs"] as? NSNumber)?.intValue ?? 0,
                inputTokens: (dictionary["inputTokens"] as? NSNumber)?.intValue ?? 0,
                cachedTokens: (dictionary["cachedTokens"] as? NSNumber)?.intValue ?? 0,
                outputTokens: (dictionary["outputTokens"] as? NSNumber)?.intValue ?? 0,
                reasoningTokens: (dictionary["reasoningTokens"] as? NSNumber)?.intValue ?? 0,
                toolCalls: (dictionary["toolCalls"] as? NSNumber)?.intValue ?? 0,
                toolErrors: (dictionary["toolErrors"] as? NSNumber)?.intValue ?? 0,
                earlyStarts: (dictionary["earlyStarts"] as? NSNumber)?.intValue ?? 0,
                compactions: (dictionary["compactions"] as? NSNumber)?.intValue ?? 0
            )
            payload = .stats(stats)
        case "turn_end":
            payload = .turnEnd(
                status: dictionary["status"] as? String ?? "completed",
                error: dictionary["error"] as? String
            )
        default:
            let jsonData = (try? JSONSerialization.data(withJSONObject: dictionary)) ?? Data()
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            payload = .unknown(kind: kind, rawJSON: jsonString)
        }

        return AgentHarnessEvent(seq: seq, timestamp: timestamp, turnRef: turnRef, payload: payload)
    }
}

public nonisolated enum AgentHarnessRuntimeError: LocalizedError, Sendable {
    case runnerNotFound([String])
    case runtimeNotFound([String])
    case runnerExitedEarly(Int32, String)
    case readinessTimeout
    case invalidRunnerResponse(String)
    case httpError(Int, String)
    case turnFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runnerNotFound(let searchedPaths):
            return "Could not locate clicky-harness-runner.js. Searched: \(searchedPaths.joined(separator: ", "))"
        case .runtimeNotFound(let searchedPaths):
            return "Could not locate bun or node runtime. Searched: \(searchedPaths.joined(separator: ", "))"
        case .runnerExitedEarly(let code, let stderr):
            return "Agent harness runner exited early (code \(code)): \(stderr)"
        case .readinessTimeout:
            return "Timed out waiting for agent harness runner readiness line."
        case .invalidRunnerResponse(let detail):
            return "Invalid response from agent harness runner: \(detail)"
        case .httpError(let statusCode, let body):
            return "Agent harness HTTP error \(statusCode): \(body)"
        case .turnFailed(let reason):
            return "Agent turn failed: \(reason)"
        }
    }
}
