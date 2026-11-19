//
//  ClickyMorningSuggestions.swift
//  Shows a greeting plus three LLM-generated agent task ideas in the notch,
//  once per calendar day (after 5am), on launch or wake from sleep.
//

import AppKit
import Foundation
import Combine

/// One suggested agent task. `reason` explains why it was suggested (may be absent for plain-string replies).
nonisolated struct ClickySuggestion: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    let title: String
    let reason: String?
}

@MainActor
final class ClickyMorningSuggestionsMonitor {
    static let shared = ClickyMorningSuggestionsMonitor()

    static let lastShownDefaultsKey = "clicky_last_morning_suggestions_date"
    static let greetings = [
        "good morning! today's to-do list doesn't stand a chance.",
        "good morning beautiful. today's gonna be a good one.",
        "good morning. hope you slept like a rock.",
        "good morning. i'm around if you need me.",
        "good morning. it's a nice day to make something cool.",
        "morning! breakfast first, greatness second.",
        "morning! drink a glass of water before anything else.",
        "morning. fresh day, clean slate.",
        "morning! go grab some coffee, i'll be here.",
        "morning! no rush today, we ease into it.",
        "morning. one thing at a time today. we got this.",
        "morning! small wins today. they add up.",
        "morning! the sun's up and so are we.",
        "morning! whatever today brings, we got it.",
        "yo good morning. glad you're here.",
        "yo, morning. happy to see you."
    ]

    private weak var companionManager: CompanionManager?
    private var wakeObserver: NSObjectProtocol?
    private var isGenerating = false

    // MARK: - Pure helpers (unit tested)

    /// True when the last shown date is on a different calendar day and it is at least 6am.
    nonisolated static func shouldRefresh(lastShown: Date?, now: Date, calendar: Calendar) -> Bool {
        guard calendar.component(.hour, from: now) >= 6 else { return false }
        guard let lastShown else { return true }
        return !calendar.isDate(lastShown, inSameDayAs: now)
    }

    /// Extracts up to 3 suggestions from a JSON array, tolerating ``` fences and stray text.
    /// Accepts `[{"title","reason"}]` (preferred) and falls back to a plain array of strings (reason nil).
    nonisolated static func parseSuggestions(_ raw: String) -> [ClickySuggestion] {
        guard let openingBracket = raw.firstIndex(of: "["),
              let closingBracket = raw.lastIndex(of: "]"),
              openingBracket < closingBracket,
              let jsonData = String(raw[openingBracket...closingBracket]).data(using: .utf8)
        else { return [] }

        nonisolated struct SuggestionReply: Decodable {
            let title: String
            let reason: String?
        }
        let decodedReplies: [SuggestionReply]
        if let objectReplies = try? JSONDecoder().decode([SuggestionReply].self, from: jsonData) {
            decodedReplies = objectReplies
        } else if let stringReplies = try? JSONDecoder().decode([String].self, from: jsonData) {
            decodedReplies = stringReplies.map { SuggestionReply(title: $0, reason: nil) }
        } else {
            return []
        }

        let suggestions = decodedReplies.compactMap { reply -> ClickySuggestion? in
            let trimmedTitle = reply.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { return nil }
            let trimmedReason = reply.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClickySuggestion(title: trimmedTitle, reason: (trimmedReason?.isEmpty ?? true) ? nil : trimmedReason)
        }
        return Array(suggestions.prefix(3))
    }

    /// Prompt addition listing why the user turned earlier suggestions down (empty when there is nothing to say).
    nonisolated static func declinedReasonsPromptBlock(_ declinedReasons: [String]) -> String {
        let usableReasons = declinedReasons
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !usableReasons.isEmpty else { return "" }
        return "The user declined these earlier because: " + usableReasons.joined(separator: "; ")
    }

    // MARK: - Lifecycle

    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshIfNeeded() }
            }
        }
        refreshIfNeeded()
    }

    /// Home's refresh button: regenerates now, ignoring the once-per-day rule (still respects the settings toggle).
    func forceRefresh() {
        guard !isGenerating, ClickyConfiguration.shared.suggestAgentTasks else { return }
        isGenerating = true
        Task { @MainActor in
            defer { isGenerating = false }
            await generateAndPresentSuggestions(presentsInNotch: false)
        }
    }

    func refreshIfNeeded() {
        guard !isGenerating,
              ClickyConfiguration.shared.suggestAgentTasks,
              UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
              companionManager?.onboardingTourController.isActive == false
        else { return }

        let lastShownDate = UserDefaults.standard.object(forKey: Self.lastShownDefaultsKey) as? Date
        guard Self.shouldRefresh(lastShown: lastShownDate, now: Date(), calendar: .current) else { return }

        isGenerating = true
        Task { @MainActor in
            defer { isGenerating = false }
            await generateAndPresentSuggestions()
        }
    }

    private func generateAndPresentSuggestions(canRetryAfterFailure: Bool = true, presentsInNotch: Bool = true) async {
        let systemPrompt = """
        You suggest tasks a personal computer agent could do for the user today. \
        Reply with exactly 3 concrete, short, actionable tasks as a JSON array of objects and nothing else, \
        each shaped {"title": "the task", "reason": "one short sentence on why it suits the user today"}.
        """
        var userPrompt = "Suggest 3 tasks for today."
        if let memoryBlock = UserMemoryStore.shared.formattedUserMemoryPromptBlock() {
            userPrompt += "\n\nWhat you know about the user:\n\(memoryBlock)"
        }

        let declinedBlock = Self.declinedReasonsPromptBlock(ClickySuggestionsStore.shared.declinedReasons)
        if !declinedBlock.isEmpty {
            userPrompt += "\n\n\(declinedBlock)"
        }

        ClickySuggestionsStore.shared.markLoading()
        do {
            let rawResponse = try await UnifiedLLMClient.shared.completeText(
                systemPrompt: systemPrompt, userPrompt: userPrompt, modelOverride: nil
            )
            let suggestions = Self.parseSuggestions(rawResponse)
            guard !suggestions.isEmpty else {
                print("⚠️ Morning suggestions: LLM reply had no parseable suggestions; showing nothing.")
                ClickySuggestionsStore.shared.markFailed()
                return
            }
            ClickySuggestionsStore.shared.replaceTodaysSuggestions(suggestions)
            guard presentsInNotch else { return }
            // Re-check the tour: generation takes seconds and the tour may have started meanwhile.
            guard companionManager?.onboardingTourController.isActive == false else { return }

            UserDefaults.standard.set(Date(), forKey: Self.lastShownDefaultsKey)
            NotchWindowManager.shared.presentMorningSuggestionsCard(
                NotchMorningSuggestionsContent(
                    greeting: Self.greetings.randomElement() ?? Self.greetings[0],
                    suggestions: suggestions
                )
            )
        } catch {
            print("⚠️ Morning suggestions: LLM call failed: \(error.localizedDescription)")
            // Retry exactly once after 60s; isGenerating stays true meanwhile so nothing else races it.
            guard canRetryAfterFailure else {
                ClickySuggestionsStore.shared.markFailed()
                return
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            await generateAndPresentSuggestions(canRetryAfterFailure: false, presentsInNotch: presentsInNotch)
        }
    }
}

// MARK: - Today's suggestions (shown in Home → Suggestions)

@MainActor
final class ClickySuggestionsStore: ObservableObject {
    static let shared = ClickySuggestionsStore()

    enum LoadPhase: Equatable { case idle, loading, failed }

    nonisolated static let todaysSuggestionsDefaultsKey = "clicky_todays_suggestions"
    nonisolated static let declinedReasonsDefaultsKey = "clicky_declined_suggestion_reasons"
    nonisolated static let maximumDeclinedReasonCount = 10

    @Published private(set) var suggestions: [ClickySuggestion]
    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var declinedReasons: [String]
    /// True once suggestions were generated today (even if the user has since cleared them all).
    @Published private(set) var hasGeneratedToday: Bool

    private let userDefaults: UserDefaults

    nonisolated private struct StoredSuggestions: Codable {
        let savedAt: Date
        let suggestions: [ClickySuggestion]
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        suggestions = Self.loadSuggestions(
            from: userDefaults.data(forKey: Self.todaysSuggestionsDefaultsKey), now: Date(), calendar: .current
        )
        hasGeneratedToday = Self.isStoredToday(userDefaults.data(forKey: Self.todaysSuggestionsDefaultsKey), now: Date(), calendar: .current)
        declinedReasons = userDefaults.stringArray(forKey: Self.declinedReasonsDefaultsKey) ?? []
    }

    // MARK: Pure helpers (unit tested)

    /// Decodes stored suggestions, dropping them when they were saved on an earlier calendar day.
    nonisolated static func loadSuggestions(from data: Data?, now: Date, calendar: Calendar) -> [ClickySuggestion] {
        guard let data, let stored = try? JSONDecoder().decode(StoredSuggestions.self, from: data),
              calendar.isDate(stored.savedAt, inSameDayAs: now) else { return [] }
        return stored.suggestions
    }

    nonisolated static func isStoredToday(_ data: Data?, now: Date, calendar: Calendar) -> Bool {
        guard let data, let stored = try? JSONDecoder().decode(StoredSuggestions.self, from: data) else { return false }
        return calendar.isDate(stored.savedAt, inSameDayAs: now)
    }

    /// Appends a non-empty reason (newest last) and keeps only the most recent `maximumCount`.
    nonisolated static func appendingDeclinedReason(_ reason: String, to existingReasons: [String], maximumCount: Int = maximumDeclinedReasonCount) -> [String] {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else { return existingReasons }
        return Array((existingReasons + [trimmedReason]).suffix(maximumCount))
    }

    // MARK: API

    func markLoading() { phase = .loading }
    func markFailed() { phase = .failed }

    func replaceTodaysSuggestions(_ newSuggestions: [ClickySuggestion]) {
        suggestions = newSuggestions
        phase = .idle
        hasGeneratedToday = true
        if let data = try? JSONEncoder().encode(StoredSuggestions(savedAt: Date(), suggestions: newSuggestions)) {
            userDefaults.set(data, forKey: Self.todaysSuggestionsDefaultsKey)
        }
    }

    /// Removes a suggestion once the user acted on it ("Yes, do it") or turned it down.
    func resolve(_ suggestion: ClickySuggestion, declinedBecause reason: String? = nil) {
        let remainingSuggestions = suggestions.filter { $0.id != suggestion.id }
        replaceTodaysSuggestions(remainingSuggestions)
        if let reason {
            declinedReasons = Self.appendingDeclinedReason(reason, to: declinedReasons)
            userDefaults.set(declinedReasons, forKey: Self.declinedReasonsDefaultsKey)
        }
    }
}
