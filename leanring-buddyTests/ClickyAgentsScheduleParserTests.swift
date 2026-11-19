import Foundation
import Testing
@testable import Clicky

struct ClickyAgentsScheduleParserTests {
    @Test func overflowingIntervalReturnsNilInsteadOfEveryOne() {
        #expect(ClickyRepeatScheduleParser.parse("every 99999999999999999999 minutes") == nil)
    }

    @Test func parsesMinuteInterval() {
        #expect(ClickyRepeatScheduleParser.parse("every 30 minutes")?.everyMinutes == 30)
    }

    @Test func parsesEveryHour() {
        #expect(ClickyRepeatScheduleParser.parse("Every hour")?.everyMinutes == 60)
    }

    @Test func parsesHourCount() {
        #expect(ClickyRepeatScheduleParser.parse("every 2 hours")?.everyMinutes == 120)
    }

    @Test func parsesDailyAtTime() {
        let parsed = ClickyRepeatScheduleParser.parse("daily at 9:00")
        #expect(parsed?.timeString == "09:00")
        #expect(parsed?.days == nil)
    }

    @Test func parsesWeekdaysAtTime() {
        let parsed = ClickyRepeatScheduleParser.parse("weekdays at 08:30")
        #expect(parsed?.timeString == "08:30")
        #expect(parsed?.days == ["mon", "tue", "wed", "thu", "fri"])
    }

    @Test func parsesDayListAtTime() {
        let parsed = ClickyRepeatScheduleParser.parse("mon,wed,fri at 17:00")
        #expect(parsed?.days == ["mon", "wed", "fri"])
        #expect(parsed?.timeString == "17:00")
    }

    @Test func parsesPmTime() {
        #expect(ClickyRepeatScheduleParser.parse("every monday at 5pm")?.timeString == "17:00")
    }

    @Test func intervalNumberIsNotMistakenForTime() {
        #expect(ClickyRepeatScheduleParser.parse("every 30 minutes")?.timeString == nil)
    }

    @Test func returnsNilForGibberish() {
        #expect(ClickyRepeatScheduleParser.parse("whenever you feel like it") == nil)
    }

    @Test func rejectsInvalidTime() {
        #expect(ClickyRepeatScheduleParser.parse("at 25:99")?.timeString == nil)
    }
}
