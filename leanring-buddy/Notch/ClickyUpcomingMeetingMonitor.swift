//
//  ClickyUpcomingMeetingMonitor.swift
//  Polls EventKit every 60s and shows a notch countdown card 5 minutes before a meeting.
//

import AppKit
import EventKit
import Foundation
import Combine

@MainActor
final class ClickyUpcomingMeetingMonitor {
    static let shared = ClickyUpcomingMeetingMonitor()

    private static let leadTimeSeconds: TimeInterval = 5 * 60
    private static let lingerAfterStartSeconds: TimeInterval = 2 * 60
    private static let pollIntervalSeconds: TimeInterval = 60

    private weak var companionManager: CompanionManager?
    private let eventStore = EKEventStore()
    private var pollTimer: Timer?
    private var toggleObserver: AnyCancellable?
    private var shownEventKeys = Set<String>()
    private var presentedStartDate: Date?

    // MARK: - Pure helper (unit tested)

    /// Prefers the event's own URL, else the first Zoom / Meet / Teams link in location then notes.
    nonisolated static func extractMeetingURL(eventURL: URL?, notes: String?, location: String?) -> URL? {
        // https only: calendar events are untrusted input and must not open arbitrary schemes (file:, custom apps).
        if let eventURL, eventURL.scheme?.lowercased() == "https" { return eventURL }
        let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com"]
        let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in [location, notes] {
            guard let text else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = linkDetector?.matches(in: text, range: range) ?? []
            for match in matches {
                if let url = match.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
                   meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }

    // MARK: - Lifecycle

    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager
        guard toggleObserver == nil else { return }
        // $showUpcomingMeetings emits the current value immediately, which also covers launch.
        toggleObserver = ClickyConfiguration.shared.$showUpcomingMeetings
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                Task { @MainActor [weak self] in
                    isEnabled ? await self?.enableMonitoring() : self?.disableMonitoring()
                }
            }
    }

    private func enableMonitoring() async {
        do {
            let isGranted = try await eventStore.requestFullAccessToEvents()
            guard isGranted else { return denyAccess(reason: "access not granted") }
        } catch {
            return denyAccess(reason: error.localizedDescription)
        }
        guard ClickyConfiguration.shared.showUpcomingMeetings, pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollForUpcomingMeeting() }
        }
        pollForUpcomingMeeting()
    }

    private func denyAccess(reason: String) {
        print("⚠️ Upcoming meetings: calendar access denied (\(reason)); turning the toggle off.")
        ClickyConfiguration.shared.showUpcomingMeetings = false
        // Flipping the toggle off only triggers disableMonitoring() (removeDuplicates), never another
        // access request, so this alert can't loop.
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Calendar access is off"
        alert.informativeText = "Clicky needs Calendar access to show upcoming meetings. You can enable it in System Settings > Privacy & Security > Calendars."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let calendarPrivacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(calendarPrivacySettingsURL)
        }
    }

    private func disableMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        NotchWindowManager.shared.dismissUpcomingMeetingCard()
    }

    private func pollForUpcomingMeeting() {
        let now = Date()

        // Auto-dismiss once the meeting started more than 2 minutes ago.
        if let presentedStartDate, now.timeIntervalSince(presentedStartDate) > Self.lingerAfterStartSeconds {
            NotchWindowManager.shared.dismissUpcomingMeetingCard()
            self.presentedStartDate = nil
        }
        guard companionManager?.onboardingTourController.isActive == false else { return }

        let searchPredicate = eventStore.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(Self.leadTimeSeconds), calendars: nil
        )
        let nextEvent = eventStore.events(matching: searchPredicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
        guard let nextEvent else { return }

        let eventKey = "\(nextEvent.eventIdentifier ?? nextEvent.title ?? "event")|\(nextEvent.startDate.timeIntervalSince1970)"
        guard shownEventKeys.insert(eventKey).inserted else { return }

        presentedStartDate = nextEvent.startDate
        NotchWindowManager.shared.presentUpcomingMeetingCard(
            NotchUpcomingMeetingContent(
                title: nextEvent.title ?? "Meeting",
                startDate: nextEvent.startDate,
                joinURL: Self.extractMeetingURL(eventURL: nextEvent.url, notes: nextEvent.notes, location: nextEvent.location)
            )
        )
    }
}
