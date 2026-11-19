import Foundation
import Testing
@testable import Clicky

struct ClickyAgentsLogicTests {
    // MARK: - 1-hour attention expiry

    @Test func attentionIsStillFlaggedJustBeforeOneHour() {
        let raisedAt = Date(timeIntervalSince1970: 1_000)
        #expect(!ClickyAttentionExpiry.hasExpired(raisedAt: raisedAt, now: raisedAt.addingTimeInterval(3_599)))
    }

    @Test func attentionExpiresAfterOneHour() {
        let raisedAt = Date(timeIntervalSince1970: 1_000)
        #expect(ClickyAttentionExpiry.hasExpired(raisedAt: raisedAt, now: raisedAt.addingTimeInterval(3_600)))
    }

    @Test func expiredWaitingStepNoLongerNeedsYou() {
        let raisedAt = Date(timeIntervalSince1970: 1_000)
        let job = ClickyJob(
            title: "Pay bill",
            prompt: "pay",
            folderPath: "/tmp",
            waitingStep: ClickyJobUserStep(step: "Sign in", askedAt: raisedAt)
        )
        #expect(job.isWaitingStepFlagged(now: raisedAt.addingTimeInterval(60)))
        #expect(!job.isWaitingStepFlagged(now: raisedAt.addingTimeInterval(3_700)))
    }

    // MARK: - Retry backoff

    @Test func backoffScheduleIsTwoFiveFifteenThirty() {
        #expect(ClickyModelRetryPolicy.backoffDelaysSeconds == [2, 5, 15, 30])
        #expect(ClickyModelRetryPolicy.delaySeconds(forRetry: 1) == 2)
        #expect(ClickyModelRetryPolicy.delaySeconds(forRetry: 4) == 30)
    }

    @Test func retriesStopAfterFour() {
        #expect(ClickyModelRetryPolicy.delaySeconds(forRetry: 5) == nil)
        #expect(ClickyModelRetryPolicy.delaySeconds(forRetry: 0) == nil)
    }

    @Test func onlyServerErrorsAndOverloadAreRetried() {
        #expect(ClickyModelRetryPolicy.shouldRetry(statusCode: 500))
        #expect(ClickyModelRetryPolicy.shouldRetry(statusCode: 529))
        #expect(!ClickyModelRetryPolicy.shouldRetry(statusCode: 429))
        #expect(!ClickyModelRetryPolicy.shouldRetry(statusCode: 200))
    }

    // MARK: - Handoff chip verbs

    @Test func chipKindFollowsFileTypeOrUrl() {
        #expect(ClickyHandoffChipKind.kind(forPath: "/a/report.pdf", isLink: false) == .pdf)
        #expect(ClickyHandoffChipKind.kind(forPath: "/a/data.xlsx", isLink: false) == .sheet)
        #expect(ClickyHandoffChipKind.kind(forPath: "/a/deck.pptx", isLink: false) == .slides)
        #expect(ClickyHandoffChipKind.kind(forPath: "/a/clip.mp4", isLink: false) == .video)
        #expect(ClickyHandoffChipKind.kind(forPath: "https://example.com/x", isLink: true) == .page)
        #expect(ClickyHandoffChipKind.kind(forPath: "/a/out/", isLink: false) == .folder)
        #expect(ClickyHandoffChipKind.kind(forPath: "/a/blob.bin", isLink: false) == .file)
    }

    // MARK: - Archive guard

    @MainActor
    @Test func archiveIsRefusedWhileJobIsWorking() {
        let suiteName = "ClickyAgentsLogicTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ClickyJobStore(defaults: defaults)
        let job = store.createJob(clickySlug: "research-buddy", title: "T", prompt: "p", folderPath: NSTemporaryDirectory())

        #expect(!store.archiveJob(jobID: job.id))
        #expect(store.job(withID: job.id)?.isArchived == false)

        store.finishLatestRun(jobID: job.id, outcome: .done, summary: "ok")
        #expect(store.archiveJob(jobID: job.id))
        #expect(store.job(withID: job.id)?.isArchived == true)
    }
}
