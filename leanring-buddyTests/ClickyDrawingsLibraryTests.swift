//
//  ClickyDrawingsLibraryTests.swift
//  Pure-logic tests for the wave 2b home + drawing work.
//

import Foundation
import CoreGraphics
import Testing
@testable import Clicky

struct ClickyDrawingsLibraryTests {
    // MARK: recording clock

    @Test func formattedClockUsesMinutesAndPaddedSeconds() {
        #expect(ClickyDrawingRecordingState.formattedClock(0) == "0:00")
        #expect(ClickyDrawingRecordingState.formattedClock(65.9) == "1:05")
        #expect(ClickyDrawingRecordingState.formattedClock(-3) == "0:00")
        #expect(ClickyDrawingRecordingState.formattedClock(.nan) == "0:00")
    }

    @Test func formattedProgressNeverShowsTotalBelowElapsed() {
        #expect(ClickyDrawingRecordingState.formattedProgress(elapsedSeconds: 12, totalSeconds: 40) == "0:12 / 0:40")
        #expect(ClickyDrawingRecordingState.formattedProgress(elapsedSeconds: 50, totalSeconds: 40) == "0:50 / 0:50")
    }

    // MARK: big card transform

    @Test func bigCardTransformCentresCardAndCapsScale() {
        let transform = ScreenAnnotationManager.bigCardTransform(
            box: CGRect(x: 0, y: 0, width: 100, height: 100), screenSize: CGSize(width: 1000, height: 800)
        )
        #expect(transform[0] == 2.2)
        #expect(transform[1] == 500 - 50 * 2.2)
        #expect(transform[2] == 400 - 50 * 2.2)
    }

    // MARK: suggestions

    @Test func parseSuggestionsReadsTitleAndReason() {
        let raw = "```json\n[{\"title\": \" Tidy Downloads \", \"reason\": \"It has 400 files.\"}, {\"title\": \"Plan week\"}]\n```"
        let suggestions = ClickyMorningSuggestionsMonitor.parseSuggestions(raw)
        #expect(suggestions.map(\.title) == ["Tidy Downloads", "Plan week"])
        #expect(suggestions.map(\.reason) == ["It has 400 files.", nil])
    }

    @Test func parseSuggestionsFallsBackToPlainStringsWithoutReason() {
        let suggestions = ClickyMorningSuggestionsMonitor.parseSuggestions("[\"a\",\"b\"]")
        #expect(suggestions.map(\.title) == ["a", "b"])
        #expect(suggestions.allSatisfy { $0.reason == nil })
    }

    @Test func declinedReasonsPromptBlockListsReasonsOrIsEmpty() {
        #expect(ClickyMorningSuggestionsMonitor.declinedReasonsPromptBlock(["  ", ""]) == "")
        #expect(ClickyMorningSuggestionsMonitor.declinedReasonsPromptBlock(["too long", "not today"])
            == "The user declined these earlier because: too long; not today")
    }

    @Test func appendingDeclinedReasonKeepsNewestAndIgnoresBlank() {
        #expect(ClickySuggestionsStore.appendingDeclinedReason("  ", to: ["a"]) == ["a"])
        #expect(ClickySuggestionsStore.appendingDeclinedReason("c", to: ["a", "b"], maximumCount: 2) == ["b", "c"])
    }

    @Test func loadSuggestionsDropsYesterdaysSuggestions() throws {
        struct Stored: Codable { let savedAt: Date; let suggestions: [ClickySuggestion] }
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let items = [ClickySuggestion(title: "x", reason: "y")]
        let todayData = try JSONEncoder().encode(Stored(savedAt: now, suggestions: items))
        let yesterdayData = try JSONEncoder().encode(Stored(savedAt: yesterday, suggestions: items))
        #expect(ClickySuggestionsStore.loadSuggestions(from: todayData, now: now, calendar: calendar).map(\.title) == ["x"])
        #expect(ClickySuggestionsStore.loadSuggestions(from: yesterdayData, now: now, calendar: calendar).isEmpty)
        #expect(ClickySuggestionsStore.loadSuggestions(from: nil, now: now, calendar: calendar).isEmpty)
    }
}
