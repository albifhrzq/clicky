import Foundation
import Testing
@testable import Clicky

struct ClickyNotchExtrasTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    @Test func shouldRefreshIsFalseOnSameDay() {
        #expect(!ClickyMorningSuggestionsMonitor.shouldRefresh(lastShown: date(17, 8), now: date(17, 12), calendar: calendar))
    }

    @Test func shouldRefreshIsFalseNextDayBeforeSixAM() {
        #expect(!ClickyMorningSuggestionsMonitor.shouldRefresh(lastShown: date(17, 8), now: date(18, 5), calendar: calendar))
    }

    @Test func shouldRefreshIsTrueNextDayAfterSixAM() {
        #expect(ClickyMorningSuggestionsMonitor.shouldRefresh(lastShown: date(17, 8), now: date(18, 6), calendar: calendar))
    }

    @Test func shouldRefreshIsTrueWhenNeverShown() {
        #expect(ClickyMorningSuggestionsMonitor.shouldRefresh(lastShown: nil, now: date(18, 9), calendar: calendar))
    }

    @Test func parseSuggestionsHandlesFencedJSON() {
        let raw = "```json\n[\"a\", \"b\", \"c\"]\n```"
        #expect(ClickyMorningSuggestionsMonitor.parseSuggestions(raw).map(\.title) == ["a", "b", "c"])
    }

    @Test func parseSuggestionsHandlesStrayTextAndTrimsAndDropsEmpties() {
        let raw = "Sure! Here you go: [\"  a  \", \"\", \"b\"] hope that helps"
        #expect(ClickyMorningSuggestionsMonitor.parseSuggestions(raw).map(\.title) == ["a", "b"])
    }

    @Test func parseSuggestionsTruncatesToThree() {
        #expect(ClickyMorningSuggestionsMonitor.parseSuggestions("[\"1\",\"2\",\"3\",\"4\"]").map(\.title) == ["1", "2", "3"])
    }

    @Test func parseSuggestionsReturnsEmptyForGarbage() {
        #expect(ClickyMorningSuggestionsMonitor.parseSuggestions("no json here").isEmpty)
    }

    @Test func extractMeetingURLPrefersEventURL() {
        let eventURL = URL(string: "https://example.com/e")!
        let result = ClickyUpcomingMeetingMonitor.extractMeetingURL(
            eventURL: eventURL, notes: "https://zoom.us/j/1", location: nil)
        #expect(result == eventURL)
    }

    @Test func extractMeetingURLFindsZoomInNotes() {
        let result = ClickyUpcomingMeetingMonitor.extractMeetingURL(
            eventURL: nil, notes: "Join: https://us02web.zoom.us/j/123 thanks", location: nil)
        #expect(result?.absoluteString == "https://us02web.zoom.us/j/123")
    }

    @Test func extractMeetingURLFindsTeamsInLocation() {
        let result = ClickyUpcomingMeetingMonitor.extractMeetingURL(
            eventURL: nil, notes: nil, location: "https://teams.microsoft.com/l/meetup-join/abc")
        #expect(result?.host == "teams.microsoft.com")
    }

    @Test func extractMeetingURLRejectsNonHTTPSEventURL() {
        let result = ClickyUpcomingMeetingMonitor.extractMeetingURL(
            eventURL: URL(string: "file:///Applications/Calculator.app")!, notes: nil, location: nil)
        #expect(result == nil)
    }

    @Test func extractMeetingURLRejectsHTTPMeetingLink() {
        let result = ClickyUpcomingMeetingMonitor.extractMeetingURL(
            eventURL: nil, notes: "http://zoom.us/j/1", location: nil)
        #expect(result == nil)
    }

    @Test func extractMeetingURLReturnsNilWhenNoMeetingLink() {
        #expect(ClickyUpcomingMeetingMonitor.extractMeetingURL(
            eventURL: nil, notes: "see https://example.com", location: "Room 4") == nil)
    }
}
