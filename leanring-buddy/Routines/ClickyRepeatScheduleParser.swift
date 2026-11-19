//
//  ClickyRepeatScheduleParser.swift
//  leanring-buddy
//
//  Pure parser for the free-text `schedule` argument of the `repeat_this_job` MCP tool,
//  e.g. "every 30 minutes", "every hour", "daily at 9:00", "weekdays at 08:30",
//  "mon,wed,fri at 17:00".
//

import Foundation

public nonisolated struct ClickyParsedRepeatSchedule: Equatable, Sendable {
    public var everyMinutes: Int?
    /// 24-hour "HH:mm", the format `ClickyRoutineScheduler.parseMinuteOfDay` expects.
    public var timeString: String?
    /// Short day names ("mon", "tue", ...), the format `ClickyRoutineScheduler.parseWeekdays` expects.
    public var days: [String]?
}

public nonisolated enum ClickyRepeatScheduleParser {
    private static let weekdayNames = ["mon", "tue", "wed", "thu", "fri"]
    private static let weekendNames = ["sat", "sun"]
    private static let dayNameByToken: [String: String] = [
        "sun": "sun", "sunday": "sun", "mon": "mon", "monday": "mon",
        "tue": "tue", "tues": "tue", "tuesday": "tue", "wed": "wed", "wednesday": "wed",
        "thu": "thu", "thur": "thu", "thurs": "thu", "thursday": "thu",
        "fri": "fri", "friday": "fri", "sat": "sat", "saturday": "sat"
    ]

    /// Returns nil when nothing schedule-like could be recognized.
    public static func parse(_ rawSchedule: String) -> ClickyParsedRepeatSchedule? {
        var remainingText = rawSchedule.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainingText.isEmpty else { return nil }

        var parsedSchedule = ClickyParsedRepeatSchedule()

        // 1. Interval: "every 30 minutes", "every 2 hours", "every hour", "hourly", "every 3 days".
        if let intervalMatch = firstMatch(#"every\s+(\d+)?\s*(minute|min|hour|hr|day)s?\b"#, in: remainingText) {
            let unitText = intervalMatch.group(2, in: remainingText) ?? ""
            var count = 1
            if let countText = intervalMatch.group(1, in: remainingText) {
                // Digits that don't fit an Int must not silently become "every 1 ...".
                guard let parsedCount = Int(countText) else { return nil }
                count = parsedCount
            }
            let minutesPerUnit = unitText.hasPrefix("h") ? 60 : (unitText.hasPrefix("d") ? 1440 : 1)
            let (totalMinutes, didOverflow) = count.multipliedReportingOverflow(by: minutesPerUnit)
            guard !didOverflow else { return nil }
            parsedSchedule.everyMinutes = totalMinutes
            remainingText.replaceSubrange(intervalMatch.range(in: remainingText), with: " ")
        } else if remainingText.contains("hourly") {
            parsedSchedule.everyMinutes = 60
        } else if remainingText.contains("daily") {
            // "daily at 9:00" keeps the time; a bare "daily" is once per day.
            parsedSchedule.everyMinutes = 1440
        }

        // 2. Time of day: "at 9", "at 9:30 pm", "17:00", "5pm".
        let timeMatches = allMatches(#"(\bat\s+)?\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#, in: remainingText)
        for timeMatch in timeMatches {
            let hasAtWord = timeMatch.group(1, in: remainingText) != nil
            let minuteText = timeMatch.group(3, in: remainingText)
            let meridiem = timeMatch.group(4, in: remainingText)
            guard hasAtWord || minuteText != nil || meridiem != nil,
                  var hour = timeMatch.group(2, in: remainingText).flatMap({ Int($0) }) else { continue }
            let minute = minuteText.flatMap { Int($0) } ?? 0
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
            guard (0...23).contains(hour), (0...59).contains(minute) else { continue }
            parsedSchedule.timeString = String(format: "%02d:%02d", hour, minute)
            break
        }

        // 3. Days: "weekdays", "weekends", or a list of day names.
        let dayTokens = remainingText.split(whereSeparator: { !$0.isLetter }).map(String.init)
        if dayTokens.contains("weekdays") || dayTokens.contains("weekday") {
            parsedSchedule.days = weekdayNames
        } else if dayTokens.contains("weekends") || dayTokens.contains("weekend") {
            parsedSchedule.days = weekendNames
        } else {
            var namedDays: [String] = []
            for token in dayTokens {
                if let shortName = dayNameByToken[token], !namedDays.contains(shortName) {
                    namedDays.append(shortName)
                }
            }
            if !namedDays.isEmpty { parsedSchedule.days = namedDays }
        }

        let recognizedAnything = parsedSchedule.everyMinutes != nil
            || parsedSchedule.timeString != nil
            || parsedSchedule.days != nil
        return recognizedAnything ? parsedSchedule : nil
    }

    // MARK: - Regex helpers

    private struct RegexMatch {
        let result: NSTextCheckingResult

        func range(in text: String) -> Range<String.Index> {
            Range(result.range, in: text)!
        }

        func group(_ index: Int, in text: String) -> String? {
            guard index < result.numberOfRanges,
                  let groupRange = Range(result.range(at: index), in: text) else { return nil }
            return String(text[groupRange])
        }
    }

    private static func allMatches(_ pattern: String, in text: String) -> [RegexMatch] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: fullRange).map { RegexMatch(result: $0) }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> RegexMatch? {
        allMatches(pattern, in: text).first
    }
}
