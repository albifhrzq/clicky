//
//  ClickyCompanionHandoff.swift
//  leanring-buddy
//
//  Lets the companion hand work to a background agent job ([AGENT:...]) or to drive
//  mode ([DRIVE:...]). Starting a job asks first unless "Ask before starting jobs" is off;
//  driving always asks.
//

import Foundation
import Combine

nonisolated struct ClickyHandoffRequest: Identifiable, Equatable, Sendable {
    enum Kind: Sendable, Equatable {
        /// A background agent job.
        case agent
        /// One step on the user's Mac, done by Clicky driving the mouse and keyboard.
        case drive
    }

    let id: UUID
    let kind: Kind
    let task: String
    let clickySlug: String?

    init(id: UUID = UUID(), kind: Kind, task: String, clickySlug: String? = nil) {
        self.id = id
        self.kind = kind
        self.task = task
        self.clickySlug = clickySlug
    }
}

/// Where a handoff came from. Decides whether "Ask before starting jobs = off" may start it without a card.
nonisolated enum ClickyHandoffSource: Sendable, Equatable {
    /// A tag in a reply to the user's own typed or spoken message.
    case replyTag(userText: String)
    /// A button inside a drawing: model-authored, so it always asks.
    case drawingButton
    /// The realtime voice tool, called right after the user spoke (no screen content in that session).
    case realtimeTool
}

nonisolated enum ClickyHandoffOutcome: Sendable, Equatable {
    case started
    case awaitingConfirmation
    case rejected(reason: String)
}

nonisolated enum ClickyHandoffPolicy {
    /// Words that show the USER asked for work to be done (English + Indonesian). Screen text alone can't trigger auto-start.
    static let workRequestPhrases = [
        "background", "job", "agent", "research", "look into", "find out", "work on", "take care of",
        "do it for me", "for me", "set up", "organize", "write a", "draft",
        "latar belakang", "agen", "riset", "kerjakan", "carikan", "cari tahu", "tolong", "buatkan", "jalankan", "urus"
    ]

    static func userAskedForWork(_ userText: String) -> Bool {
        let lowered = userText.lowercased()
        return workRequestPhrases.contains { lowered.contains($0) }
    }

    /// True when an agent job may start without the confirmation card.
    static func shouldStartWithoutAsking(source: ClickyHandoffSource, askBeforeStartingJobs: Bool) -> Bool {
        guard !askBeforeStartingJobs else { return false }
        switch source {
        case .replyTag(let userText): return userAskedForWork(userText)
        case .drawingButton: return false
        case .realtimeTool: return true
        }
    }
}

nonisolated enum ClickyHandoffTagParser {
    static let maximumTaskLength = 500

    // [AGENT:<slug>:<task>] or [DRIVE:<step>]; the task may not contain a closing bracket.
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"\[\s*(AGENT|DRIVE)\s*:([^\]]*)\]"#,
        options: [.caseInsensitive]
    )

    /// Removes every handoff tag from `responseText` and returns the first valid one as a request.
    static func parse(from responseText: String) -> (text: String, request: ClickyHandoffRequest?) {
        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = tagPattern.matches(in: responseText, range: fullRange)
        guard !matches.isEmpty else { return (responseText, nil) }

        var firstRequest: ClickyHandoffRequest?
        for match in matches where firstRequest == nil {
            guard let kindRange = Range(match.range(at: 1), in: responseText),
                  let bodyRange = Range(match.range(at: 2), in: responseText) else { continue }
            let body = String(responseText[bodyRange])
            if responseText[kindRange].uppercased() == "AGENT" {
                // Slug is everything before the first colon; the task is the rest.
                guard let colonIndex = body.firstIndex(of: ":") else { continue }
                let slug = cleaned(String(body[..<colonIndex]))
                let task = cleaned(String(body[body.index(after: colonIndex)...]))
                guard !task.isEmpty else { continue }
                let resolvedSlug = (slug.isEmpty || slug.lowercased() == "none") ? nil : slug
                firstRequest = ClickyHandoffRequest(kind: .agent, task: task, clickySlug: resolvedSlug)
            } else {
                let task = cleaned(body)
                guard !task.isEmpty else { continue }
                firstRequest = ClickyHandoffRequest(kind: .drive, task: task)
            }
        }

        let strippedText = tagPattern
            .stringByReplacingMatches(in: responseText, range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (strippedText, firstRequest)
    }

    /// While a reply streams, hides a handoff tag that has started but not closed yet.
    static func hidingPartialTag(in streamingText: String) -> String {
        // Find the last "[" that starts (a prefix of) [AGENT or [DRIVE and has no "]" after it.
        // A plain "[" inside the task text (e.g. "[AGENT:none:fix the [foo") must not hide less than the tag.
        var searchEnd = streamingText.endIndex
        while let openBracketIndex = streamingText[..<searchEnd].lastIndex(of: "[") {
            let tail = streamingText[openBracketIndex...]
            let tagWord = String(tail.dropFirst().prefix(5)).uppercased()
            let looksLikeTagStart = !tagWord.isEmpty
                && ("AGENT".hasPrefix(tagWord) || "DRIVE".hasPrefix(tagWord))
            if looksLikeTagStart {
                guard !tail.contains("]") else { return streamingText }
                return String(streamingText[..<openBracketIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            searchEnd = openBracketIndex
        }
        return streamingText
    }

    static func cleaned(_ rawText: String) -> String {
        let withoutControlCharacters = rawText.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        let trimmed = withoutControlCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumTaskLength))
    }
}

nonisolated enum ClickyHandoffPromptReference {
    static func section(for channel: ClickyCompanionChannel) -> String {
        switch channel {
        case .text, .voice:
            return """

            HANDING OFF WORK
            - When the user asks for work that takes a while or should run in the background (research, writing a document, organizing files, anything multi-step on websites or apps), say one short sentence that you're starting it, then end the reply with [AGENT:none:<clear, self-contained task for the agent>]. A job can take minutes; tell them they'll see it in the notch.
            - For a single concrete action on their Mac that they want you to do for them right now (click or type in an app), end the reply with [DRIVE:<the one step>].
            - Never emit a tag unless the user asked for that work. At most one tag per reply. Tags are never spoken aloud.
            """
        case .realtime:
            return """

            HANDING OFF WORK
            - Call start_background_job(task) for work that takes a while or should run in the background (research, writing a document, organizing files, multi-step work on websites or apps). Say one short sentence that you're starting it; it can take minutes and they'll see it in the notch.
            - Call use_screen(request) for anything about the screen, pointing, or drawing.
            - Only call these when the user asked for that work.
            """
        }
    }
}

/// Extensions can't hold stored properties, so the chat row that offered the pending handoff lives here.
@MainActor
private enum ClickyPendingHandoffContext {
    static var assistantMessageID: UUID?
}

extension CompanionManager {
    private static let handoffConfirmationTimeoutSeconds: UInt64 = 180

    /// Entry point for every handoff (reply tags, drawing buttons, realtime tools).
    /// `assistantMessageID` is the chat row that offered it, for the activity ledger.
    @discardableResult
    func handleHandoffRequest(
        _ request: ClickyHandoffRequest,
        assistantMessageID: UUID?,
        source: ClickyHandoffSource
    ) -> ClickyHandoffOutcome {
        let busyReason: String?
        if pendingHandoffRequest != nil {
            busyReason = String(localized: "Another job is already waiting for your OK in the notch.")
        } else if onboardingTourController.isActive {
            busyReason = String(localized: "I can't start a job during the tour.")
        } else if ClickyTakeOverController.shared.phase != .idle {
            busyReason = String(localized: "I'm already driving your Mac.")
        } else {
            busyReason = nil
        }
        if let busyReason {
            if let assistantMessageID {
                appendActivity(to: assistantMessageID, [busyReason])
            }
            return .rejected(reason: busyReason)
        }

        switch request.kind {
        case .agent:
            guard !request.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                chatMessages.append(ClickyChatMessage(
                    role: "assistant",
                    text: String(localized: "I couldn't start a job for that, so nothing was started. Ask me again and I'll start one.")
                ))
                return .rejected(reason: String(localized: "I couldn't start a job for that, so nothing was started."))
            }
            let mayStartWithoutAsking = ClickyHandoffPolicy.shouldStartWithoutAsking(
                source: source,
                askBeforeStartingJobs: ClickyConfiguration.shared.askBeforeStartingJobs
            )
            if !mayStartWithoutAsking {
                pendingHandoffRequest = request
                ClickyPendingHandoffContext.assistantMessageID = assistantMessageID
                let requestID = request.id
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: Self.handoffConfirmationTimeoutSeconds * 1_000_000_000)
                    guard let self, self.pendingHandoffRequest?.id == requestID else { return }
                    self.declinePendingHandoff()
                }
                return .awaitingConfirmation
            } else {
                startHandoffJob(request, assistantMessageID: assistantMessageID)
                return .started
            }
        case .drive:
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ledgerLine: String
                do {
                    _ = try await ClickyTakeOverController.shared.runMacStep(
                        step: request.task,
                        shortTitle: nil,
                        reason: nil
                    )
                    ledgerLine = String(localized: "Drove your Mac")
                } catch {
                    ledgerLine = error.localizedDescription
                }
                if let assistantMessageID {
                    self.appendActivity(to: assistantMessageID, [ledgerLine])
                }
            }
            // Drive always shows its own consent card first.
            return .awaitingConfirmation
        }
    }

    func approvePendingHandoff() {
        guard let request = pendingHandoffRequest else { return }
        let assistantMessageID = ClickyPendingHandoffContext.assistantMessageID
        pendingHandoffRequest = nil
        ClickyPendingHandoffContext.assistantMessageID = nil
        startHandoffJob(request, assistantMessageID: assistantMessageID)
    }

    func declinePendingHandoff() {
        pendingHandoffRequest = nil
        ClickyPendingHandoffContext.assistantMessageID = nil
    }

    private func startHandoffJob(_ request: ClickyHandoffRequest, assistantMessageID: UUID?) {
        let resolvedSlug = request.clickySlug
            ?? assistantMessageID.flatMap { id in chatMessages.first(where: { $0.id == id })?.clickySlug }
        startBackgroundAgentTask(prompt: request.task, clickySlug: resolvedSlug)
        if let assistantMessageID {
            appendActivity(to: assistantMessageID, [String(localized: "Started a background job")])
        }
    }
}
