import Foundation
import Testing
@testable import Clicky

@MainActor
struct ClickyJobAnnouncementPolicyTests {
    private func makeJob(
        id: String = "job-1",
        outcome: ClickyJobOutcome = .working,
        summary: String? = nil,
        waitsForChrome: Bool = false
    ) -> ClickyJob {
        ClickyJob(id: id, title: "Pay bill", prompt: "pay", folderPath: "/tmp", outcome: outcome, summary: summary, waitsForChrome: waitsForChrome)
    }

    private func events(from previous: ClickyJobRailPhase?, to job: ClickyJob) -> [ClickyJobAnnouncementEvent] {
        let previousPhases: [String: ClickyJobRailPhase]? = previous.map { [job.id: $0] }
        return ClickyJobAnnouncementPolicy.events(previousPhasesByJobID: previousPhases, currentJobs: [job])
    }

    @Test func firstSnapshotAnnouncesNothing() {
        #expect(ClickyJobAnnouncementPolicy.events(previousPhasesByJobID: nil, currentJobs: [makeJob()]).isEmpty)
    }

    @Test func newWorkingJobIsStarted() {
        let result = ClickyJobAnnouncementPolicy.events(previousPhasesByJobID: [:], currentJobs: [makeJob()])
        #expect(result == [.started(jobID: "job-1", jobTitle: "Pay bill")])
    }

    @Test func workingToDoneIsFinishedWithSummary() {
        let result = events(from: .working, to: makeJob(outcome: .done, summary: "  Paid it.  "))
        #expect(result == [.finished(jobID: "job-1", jobTitle: "Pay bill", summary: "Paid it.")])
    }

    @Test func failedAndStoppedAreSilent() {
        #expect(events(from: .working, to: makeJob(outcome: .failed)).isEmpty)
        #expect(events(from: .working, to: makeJob(outcome: .stopped)).isEmpty)
    }

    @Test func rerunAfterDoneIsStarted() {
        let result = events(from: .done, to: makeJob())
        #expect(result == [.started(jobID: "job-1", jobTitle: "Pay bill")])
    }

    @Test func workingToNeedsYouIsAnnounced() {
        let result = events(from: .working, to: makeJob(waitsForChrome: true))
        #expect(result == [.needsYou(jobID: "job-1", jobTitle: "Pay bill")])
    }

    @Test func unchangedPhaseIsSilent() {
        #expect(events(from: .working, to: makeJob()).isEmpty)
    }

    @Test func spokenLineHasNameAndNoIdOrBrackets() {
        let line = ClickyJobAnnouncementPolicy.spokenLine(for: .started(jobID: "job-1", jobTitle: "Pay bill"))
        #expect(line.contains("Pay bill"))
        #expect(!line.contains("["))
        #expect(!line.contains("job-1"))
    }

    @Test func cursorBubbleSkipsStartedAndTruncatesLongSummaries() {
        #expect(ClickyJobAnnouncementPolicy.cursorBubbleText(for: .started(jobID: "a", jobTitle: "T")) == nil)
        let longSummary = String(repeating: "x", count: 500)
        let bubble = ClickyJobAnnouncementPolicy.cursorBubbleText(for: .finished(jobID: "a", jobTitle: "T", summary: longSummary))
        #expect((bubble?.count ?? 0) <= 161)
    }
}
