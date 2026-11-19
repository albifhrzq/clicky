import Foundation

/// A background-job transition worth telling the user about.
/// `jobTitle` already holds the display name (nickname if set, else title).
nonisolated enum ClickyJobAnnouncementEvent: Equatable, Sendable {
    case started(jobID: String, jobTitle: String)
    case finished(jobID: String, jobTitle: String, summary: String?)
    case needsYou(jobID: String, jobTitle: String)
}

// ponytail: fixed templates + the job SUMMARY replace the official live model-written line.
// Upgrade path: inject the event into an active realtime voice session so the model words it.
nonisolated enum ClickyJobAnnouncementPolicy {
    private static let maximumJobNameLength = 60
    private static let maximumCursorBubbleLength = 160
    private static let activePhases: Set<ClickyJobRailPhase> = [.working, .queued, .needsYou]

    static func phasesByJobID(_ jobs: [ClickyJob]) -> [String: ClickyJobRailPhase] {
        var phasesByJobID: [String: ClickyJobRailPhase] = [:]
        for job in jobs { phasesByJobID[job.id] = job.railPhase }
        return phasesByJobID
    }

    /// `previousPhasesByJobID == nil` is the first snapshot after launch: restored jobs are never announced.
    static func events(
        previousPhasesByJobID: [String: ClickyJobRailPhase]?,
        currentJobs: [ClickyJob]
    ) -> [ClickyJobAnnouncementEvent] {
        guard let previousPhasesByJobID else { return [] }

        var announcementEvents: [ClickyJobAnnouncementEvent] = []
        for job in currentJobs where !job.isArchived && !job.isDismissed {
            let jobDisplayName = displayName(for: job)
            let currentPhase = job.railPhase
            let previousPhase = previousPhasesByJobID[job.id]

            if let previousPhase {
                if previousPhase == currentPhase { continue }
                switch currentPhase {
                case .working, .queued:
                    // Only a re-run (job was idle) counts; needsYou -> working is just resuming.
                    if !activePhases.contains(previousPhase) {
                        announcementEvents.append(.started(jobID: job.id, jobTitle: jobDisplayName))
                    }
                case .needsYou:
                    announcementEvents.append(.needsYou(jobID: job.id, jobTitle: jobDisplayName))
                case .done:
                    if activePhases.contains(previousPhase) {
                        announcementEvents.append(.finished(jobID: job.id, jobTitle: jobDisplayName, summary: trimmedSummary(of: job)))
                    }
                case .failed, .stopped:
                    break
                }
            } else if currentPhase == .working || currentPhase == .queued {
                announcementEvents.append(.started(jobID: job.id, jobTitle: jobDisplayName))
            }
        }
        return announcementEvents
    }

    static func spokenLine(for event: ClickyJobAnnouncementEvent) -> String {
        switch event {
        case .started(_, let jobTitle):
            return String(localized: "\(jobTitle) is on it.")
        case .finished(_, let jobTitle, let summary):
            if let summary, !summary.isEmpty {
                return String(localized: "\(jobTitle) is done. \(summary)")
            }
            return String(localized: "\(jobTitle) is done.")
        case .needsYou(_, let jobTitle):
            return String(localized: "\(jobTitle) needs you.")
        }
    }

    /// Cursor bubbles are only for finished / needs-you.
    static func cursorBubbleText(for event: ClickyJobAnnouncementEvent) -> String? {
        switch event {
        case .started:
            return nil
        case .finished(_, _, let summary):
            let bubbleText = (summary?.isEmpty == false ? summary : nil) ?? spokenLine(for: event)
            if bubbleText.count <= maximumCursorBubbleLength { return bubbleText }
            return String(bubbleText.prefix(maximumCursorBubbleLength)) + "…"
        case .needsYou:
            return spokenLine(for: event)
        }
    }

    private static func displayName(for job: ClickyJob) -> String {
        let trimmedNickname = job.nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawName = trimmedNickname.isEmpty ? job.title.trimmingCharacters(in: .whitespacesAndNewlines) : trimmedNickname
        if rawName.count <= maximumJobNameLength { return rawName }
        return String(rawName.prefix(maximumJobNameLength)) + "…"
    }

    private static func trimmedSummary(of job: ClickyJob) -> String? {
        let trimmed = job.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
