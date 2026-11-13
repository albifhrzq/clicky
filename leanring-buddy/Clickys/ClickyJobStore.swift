//
//  ClickyJobStore.swift
//  leanring-buddy
//

import Combine
import Foundation

public nonisolated enum ClickyJobOutcome: String, Codable, Equatable, Sendable {
    case working
    case done
    case failed
    case stopped
}

public nonisolated enum ClickyJobRailPhase: String, Codable, Equatable, Sendable {
    case queued
    case working
    case needsYou
    case done
    case failed
    case stopped
}

public nonisolated struct ClickyJobArtifactEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }

    public let path: String
    public var title: String
    public var isLink: Bool
    public var byteCount: Int64?
    public var modifiedAt: Date?

    public init(
        path: String,
        title: String? = nil,
        isLink: Bool = false,
        byteCount: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.title = title
        } else {
            self.title = URL(fileURLWithPath: path).lastPathComponent
        }
        self.isLink = isLink
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public nonisolated struct ClickyJobUserStep: Codable, Equatable, Sendable {
    public var step: String
    public var page: String?
    public var doneWhenURLContains: String?
    public var askedAt: Date

    enum CodingKeys: String, CodingKey {
        case step
        case page
        case doneWhenURLContains
        case askedAt
    }

    public init(
        step: String,
        page: String? = nil,
        doneWhenURLContains: String? = nil,
        askedAt: Date = Date()
    ) {
        self.step = step
        self.page = page
        self.doneWhenURLContains = doneWhenURLContains
        self.askedAt = askedAt
    }
}

public nonisolated struct ClickyJobRun: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(threadID)-\(startedAt.timeIntervalSince1970)" }

    public let threadID: String
    public let startedAt: Date
    public var ask: String
    public var finishedAt: Date?
    public var outcome: ClickyJobOutcome
    public var summary: String?

    enum CodingKeys: String, CodingKey {
        case threadID
        case startedAt
        case ask
        case finishedAt
        case outcome
        case summary
    }

    public init(
        threadID: String,
        startedAt: Date = Date(),
        ask: String,
        finishedAt: Date? = nil,
        outcome: ClickyJobOutcome = .working,
        summary: String? = nil
    ) {
        self.threadID = threadID
        self.startedAt = startedAt
        self.ask = ask
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.summary = summary
    }
}

public nonisolated struct ClickyJob: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var clickySlug: String
    public var title: String
    public var prompt: String
    public var threadID: String
    public var folderPath: String
    public let createdAt: Date
    public var finishedAt: Date?
    public var outcome: ClickyJobOutcome
    public var summary: String?
    public var replyText: String?
    public var artifactEntries: [ClickyJobArtifactEntry]
    public var latestReplyArtifactEntries: [ClickyJobArtifactEntry]
    public var isSeen: Bool
    public var isDismissed: Bool
    public var followedUpOnLaterDay: Bool
    public var isArchived: Bool
    public var cloudColorName: String?
    public var suggestionCardID: String?
    public var nickname: String?
    public var waitsForChrome: Bool
    public var skipsChrome: Bool
    public var runs: [ClickyJobRun]
    public var waitingStep: ClickyJobUserStep?

    enum CodingKeys: String, CodingKey {
        case id
        case clickySlug
        case title
        case prompt
        case threadID
        case folderPath
        case createdAt
        case finishedAt
        case outcome
        case summary
        case replyText
        case artifactEntries
        case latestReplyArtifactEntries
        case isSeen
        case isDismissed
        case followedUpOnLaterDay
        case isArchived
        case cloudColorName
        case suggestionCardID
        case nickname
        case waitsForChrome
        case skipsChrome
        case runs
        case waitingStep
    }

    public init(
        id: String = UUID().uuidString,
        clickySlug: String = "research-buddy",
        title: String,
        prompt: String,
        threadID: String = UUID().uuidString,
        folderPath: String,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        outcome: ClickyJobOutcome = .working,
        summary: String? = nil,
        replyText: String? = nil,
        artifactEntries: [ClickyJobArtifactEntry] = [],
        latestReplyArtifactEntries: [ClickyJobArtifactEntry] = [],
        isSeen: Bool = false,
        isDismissed: Bool = false,
        followedUpOnLaterDay: Bool = false,
        isArchived: Bool = false,
        cloudColorName: String? = nil,
        suggestionCardID: String? = nil,
        nickname: String? = nil,
        waitsForChrome: Bool = false,
        skipsChrome: Bool = false,
        runs: [ClickyJobRun] = [],
        waitingStep: ClickyJobUserStep? = nil
    ) {
        self.id = id
        self.clickySlug = clickySlug
        self.title = title
        self.prompt = prompt
        self.threadID = threadID
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.summary = summary
        self.replyText = replyText
        self.artifactEntries = artifactEntries
        self.latestReplyArtifactEntries = latestReplyArtifactEntries
        self.isSeen = isSeen
        self.isDismissed = isDismissed
        self.followedUpOnLaterDay = followedUpOnLaterDay
        self.isArchived = isArchived
        self.cloudColorName = cloudColorName
        self.suggestionCardID = suggestionCardID
        self.nickname = nickname
        self.waitsForChrome = waitsForChrome
        self.skipsChrome = skipsChrome
        self.runs = runs
        self.waitingStep = waitingStep
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.clickySlug = try container.decodeIfPresent(String.self, forKey: .clickySlug) ?? "research-buddy"
        self.title = try container.decode(String.self, forKey: .title)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.threadID = try container.decode(String.self, forKey: .threadID)
        self.folderPath = try container.decode(String.self, forKey: .folderPath)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.outcome = try container.decodeIfPresent(ClickyJobOutcome.self, forKey: .outcome) ?? .done
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.replyText = try container.decodeIfPresent(String.self, forKey: .replyText)
        self.artifactEntries = try container.decodeIfPresent([ClickyJobArtifactEntry].self, forKey: .artifactEntries) ?? []
        self.latestReplyArtifactEntries = try container.decodeIfPresent([ClickyJobArtifactEntry].self, forKey: .latestReplyArtifactEntries) ?? []
        self.isSeen = try container.decodeIfPresent(Bool.self, forKey: .isSeen) ?? false
        self.isDismissed = try container.decodeIfPresent(Bool.self, forKey: .isDismissed) ?? false
        self.followedUpOnLaterDay = try container.decodeIfPresent(Bool.self, forKey: .followedUpOnLaterDay) ?? false
        self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.cloudColorName = try container.decodeIfPresent(String.self, forKey: .cloudColorName)
        self.suggestionCardID = try container.decodeIfPresent(String.self, forKey: .suggestionCardID)
        self.nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        self.waitsForChrome = try container.decodeIfPresent(Bool.self, forKey: .waitsForChrome) ?? false
        self.skipsChrome = try container.decodeIfPresent(Bool.self, forKey: .skipsChrome) ?? false
        self.runs = try container.decodeIfPresent([ClickyJobRun].self, forKey: .runs) ?? []
        self.waitingStep = try container.decodeIfPresent(ClickyJobUserStep.self, forKey: .waitingStep)
    }

    public var railPhase: ClickyJobRailPhase {
        if waitingStep != nil {
            return .needsYou
        }
        switch outcome {
        case .working:
            return waitsForChrome ? .needsYou : .working
        case .done:
            return .done
        case .failed:
            return .failed
        case .stopped:
            return .stopped
        }
    }
}

public nonisolated struct ClickyRestartInterruptionRecord: Codable, Equatable, Sendable {
    public let slug: String
    public let jobID: String
    public let threadID: String
    public let interruptedAt: Date
    public var isInChat: Bool

    public init(
        slug: String,
        jobID: String,
        threadID: String,
        interruptedAt: Date = Date(),
        isInChat: Bool = false
    ) {
        self.slug = slug
        self.jobID = jobID
        self.threadID = threadID
        self.interruptedAt = interruptedAt
        self.isInChat = isInChat
    }
}

@MainActor
public final class ClickyJobStore: ObservableObject {
    public static let shared = ClickyJobStore()

    public static let jobsDefaultsKey = "clicky.jobs.v1"
    public static let runningTurnsDefaultsKey = "clicky.clickys.runningTurns.v1"

    private let defaults: UserDefaults

    @Published private(set) var jobs: [ClickyJob] = []
    @Published public var jobIDsWithRoutines: Set<String> = []
    @Published private(set) var interruptedTurnsBySlug: [String: ClickyRestartInterruptionRecord] = [:]

    public var activeJobs: [ClickyJob] {
        jobs.filter { job in
            !job.isArchived && !job.isDismissed && job.outcome == .working
        }
    }

    public var visibleJobs: [ClickyJob] {
        jobs.filter { job in
            !job.isArchived && !job.isDismissed
        }
    }

    public var unreadCount: Int {
        visibleJobs.filter { job in
            !job.isSeen && job.outcome != .working
        }.count
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.jobs = Self.loadJobs(from: defaults)
        self.interruptedTurnsBySlug = Self.loadRunningTurns(from: defaults)
    }

    @discardableResult
    public func createJob(
        clickySlug: String,
        title: String,
        prompt: String,
        threadID: String = UUID().uuidString,
        folderPath: String? = nil,
        cloudColorName: String? = nil,
        suggestionCardID: String? = nil,
        waitsForChrome: Bool = false,
        skipsChrome: Bool = false
    ) -> ClickyJob {
        let resolvedFolderPath = folderPath
            ?? ClickyWorkFolderFiles.shared.ensureClickyWorkspace(slug: clickySlug).path

        let initialRun = ClickyJobRun(
            threadID: threadID,
            startedAt: Date(),
            ask: prompt,
            finishedAt: nil,
            outcome: .working,
            summary: nil
        )

        let job = ClickyJob(
            id: UUID().uuidString,
            clickySlug: clickySlug,
            title: title,
            prompt: prompt,
            threadID: threadID,
            folderPath: resolvedFolderPath,
            createdAt: Date(),
            finishedAt: nil,
            outcome: .working,
            summary: nil,
            replyText: nil,
            artifactEntries: [],
            latestReplyArtifactEntries: [],
            isSeen: false,
            isDismissed: false,
            followedUpOnLaterDay: false,
            isArchived: false,
            cloudColorName: cloudColorName,
            suggestionCardID: suggestionCardID,
            nickname: nil,
            waitsForChrome: waitsForChrome,
            skipsChrome: skipsChrome,
            runs: [initialRun],
            waitingStep: nil
        )

        jobs.insert(job, at: 0)
        markTurnRunning(slug: clickySlug, jobID: job.id, threadID: threadID)
        persistJobs()
        ClickyWorkFolderFiles.shared.syncJobArtifactsAndReport(for: job)
        return job
    }

    public func updateJob(id: String, mutate: (inout ClickyJob) -> Void) {
        guard let index = jobs.firstIndex(where: { job in job.id == id }) else { return }
        var updated = jobs[index]
        mutate(&updated)
        jobs[index] = updated
        if updated.outcome != .working {
            clearRunningTurn(forJobID: updated.id)
        }
        persistJobs()
        ClickyWorkFolderFiles.shared.syncJobArtifactsAndReport(for: updated)
    }

    public func updateJob(_ job: ClickyJob) {
        if let index = jobs.firstIndex(where: { existing in existing.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        if job.outcome != .working {
            clearRunningTurn(forJobID: job.id)
        }
        persistJobs()
        ClickyWorkFolderFiles.shared.syncJobArtifactsAndReport(for: job)
    }

    public func appendReply(
        jobID: String,
        replyText: String,
        summary: String? = nil,
        outcome: ClickyJobOutcome? = nil,
        artifactEntries: [ClickyJobArtifactEntry] = []
    ) {
        updateJob(id: jobID) { job in
            let existingReply = (job.replyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if existingReply.isEmpty {
                job.replyText = replyText
            } else if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                job.replyText = existingReply + "\n\n" + replyText
            }

            if let summary, !summary.isEmpty {
                job.summary = summary
            }

            if !artifactEntries.isEmpty {
                job.latestReplyArtifactEntries = artifactEntries
                var existingByPath = Dictionary(
                    job.artifactEntries.map { entry in (entry.path, entry) },
                    uniquingKeysWith: { _, newer in newer }
                )
                for entry in artifactEntries {
                    existingByPath[entry.path] = entry
                }
                job.artifactEntries = Array(existingByPath.values).sorted { left, right in
                    left.path < right.path
                }
            }

            if let outcome {
                job.outcome = outcome
                if outcome != .working {
                    job.finishedAt = Date()
                    if let lastRunIndex = job.runs.indices.last {
                        job.runs[lastRunIndex].finishedAt = job.finishedAt
                        job.runs[lastRunIndex].outcome = outcome
                        job.runs[lastRunIndex].summary = summary ?? job.summary
                    }
                }
            }
        }
    }

    public func beginNewRun(jobID: String, threadID: String, ask: String) {
        updateJob(id: jobID) { job in
            job.threadID = threadID
            job.prompt = ask
            job.outcome = .working
            job.finishedAt = nil
            job.waitingStep = nil
            job.isSeen = false
            job.runs.append(
                ClickyJobRun(
                    threadID: threadID,
                    startedAt: Date(),
                    ask: ask,
                    finishedAt: nil,
                    outcome: .working,
                    summary: nil
                )
            )
            markTurnRunning(slug: job.clickySlug, jobID: job.id, threadID: threadID)
        }
    }

    public func finishLatestRun(jobID: String, outcome: ClickyJobOutcome, summary: String?) {
        updateJob(id: jobID) { job in
            let completionDate = Date()
            job.outcome = outcome
            job.finishedAt = completionDate
            if let summary {
                job.summary = summary
            }
            if let lastRunIndex = job.runs.indices.last {
                job.runs[lastRunIndex].finishedAt = completionDate
                job.runs[lastRunIndex].outcome = outcome
                job.runs[lastRunIndex].summary = summary
            }
        }
    }

    public func markSeen(jobID: String) {
        updateJob(id: jobID) { job in
            job.isSeen = true
        }
    }

    public func dismissJob(jobID: String) {
        updateJob(id: jobID) { job in
            job.isDismissed = true
            job.isSeen = true
        }
    }

    public func archiveJob(jobID: String) {
        updateJob(id: jobID) { job in
            job.isArchived = true
            job.isSeen = true
        }
    }

    public func setWaitingStep(jobID: String, step: ClickyJobUserStep?) {
        updateJob(id: jobID) { job in
            job.waitingStep = step
        }
    }

    public func job(withID id: String) -> ClickyJob? {
        jobs.first { job in job.id == id }
    }

    public func job(forThreadID threadID: String) -> ClickyJob? {
        jobs.first { job in job.threadID == threadID }
    }

    public func jobs(forClickySlug slug: String) -> [ClickyJob] {
        jobs.filter { job in job.clickySlug == slug && !job.isArchived }
    }

    public func findJobs(matchingQuery query: String, limit: Int = 20) -> [ClickyJob] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool = jobs.filter { job in !job.isArchived }
        if trimmed.isEmpty {
            return Array(pool.prefix(limit))
        }
        let tokens = trimmed.split(whereSeparator: { character in character.isWhitespace }).map(String.init)
        let matched = pool.filter { job in
            let searchable = [
                job.title,
                job.prompt,
                job.summary ?? "",
                job.replyText ?? "",
                job.clickySlug
            ].joined(separator: "\n").lowercased()
            return tokens.allSatisfy { token in searchable.contains(token) }
        }
        return Array(matched.prefix(limit))
    }

    public func markInterruptedWorkingJobsOnLaunch() {
        var didChange = false
        let now = Date()

        for index in jobs.indices where jobs[index].outcome == .working {
            jobs[index].outcome = .stopped
            jobs[index].finishedAt = now
            if jobs[index].summary == nil {
                jobs[index].summary = "HeyClicky stopped before the agent task finished."
            }
            if let lastRunIndex = jobs[index].runs.indices.last,
               jobs[index].runs[lastRunIndex].outcome == .working {
                jobs[index].runs[lastRunIndex].outcome = .stopped
                jobs[index].runs[lastRunIndex].finishedAt = now
                jobs[index].runs[lastRunIndex].summary = "stopped before it finished"
            }
            interruptedTurnsBySlug[jobs[index].clickySlug] = ClickyRestartInterruptionRecord(
                slug: jobs[index].clickySlug,
                jobID: jobs[index].id,
                threadID: jobs[index].threadID,
                interruptedAt: now,
                isInChat: true
            )
            didChange = true
        }

        if didChange {
            persistJobs()
            persistRunningTurns()
        }
    }

    private func markTurnRunning(slug: String, jobID: String, threadID: String) {
        interruptedTurnsBySlug[slug] = ClickyRestartInterruptionRecord(
            slug: slug,
            jobID: jobID,
            threadID: threadID,
            interruptedAt: Date(),
            isInChat: false
        )
        persistRunningTurns()
    }

    private func clearRunningTurn(forJobID jobID: String) {
        let keysToRemove = interruptedTurnsBySlug
            .filter { _, record in record.jobID == jobID }
            .map(\.key)
        guard !keysToRemove.isEmpty else { return }
        for key in keysToRemove {
            interruptedTurnsBySlug.removeValue(forKey: key)
        }
        persistRunningTurns()
    }

    private static func loadJobs(from defaults: UserDefaults) -> [ClickyJob] {
        guard let data = defaults.data(forKey: jobsDefaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ClickyJob].self, from: data) {
            return decoded
        }
        let fallbackDecoder = JSONDecoder()
        return (try? fallbackDecoder.decode([ClickyJob].self, from: data)) ?? []
    }

    private func persistJobs() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let encoded = try? encoder.encode(jobs) {
            defaults.set(encoded, forKey: Self.jobsDefaultsKey)
        }
    }

    private static func loadRunningTurns(from defaults: UserDefaults) -> [String: ClickyRestartInterruptionRecord] {
        guard let data = defaults.data(forKey: runningTurnsDefaultsKey) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: ClickyRestartInterruptionRecord].self, from: data)) ?? [:]
    }

    private func persistRunningTurns() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let encoded = try? encoder.encode(interruptedTurnsBySlug) {
            defaults.set(encoded, forKey: Self.runningTurnsDefaultsKey)
        }
    }
}

@MainActor
public final class ClickyJobStepWatcher {
    public static let shared = ClickyJobStepWatcher()

    public var onStepDone: ((ClickyJob, String) -> Void)?
    public var activeURLProvider: (@MainActor () async -> String?)?

    private var timer: Timer?
    private var jobIDsSeenNotDone: Set<String> = []
    private var jobIDsContinued: Set<String> = []
    private var isEvaluating = false

    private let jobStore: ClickyJobStore

    public init(jobStore: ClickyJobStore = .shared) {
        self.jobStore = jobStore
    }

    public func start(pollIntervalSeconds: TimeInterval = 2.0) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.evaluateWaitingJobs()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func resetTracking(forJobID jobID: String) {
        jobIDsSeenNotDone.remove(jobID)
        jobIDsContinued.remove(jobID)
    }

    public func evaluateWaitingJobs() async {
        guard !isEvaluating else { return }
        let waitingJobs = jobStore.jobs.filter { job in
            guard !job.isArchived,
                  !job.isDismissed,
                  let needle = job.waitingStep?.doneWhenURLContains?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !needle.isEmpty else {
                return false
            }
            return true
        }

        guard !waitingJobs.isEmpty else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        let currentURLString: String?
        if let activeURLProvider {
            currentURLString = await activeURLProvider()
        } else {
            currentURLString = await ActiveBrowserSiteReader.captureCurrentBrowserURLString()
        }

        guard let currentURLString, !currentURLString.isEmpty else {
            for job in waitingJobs {
                jobIDsSeenNotDone.insert(job.id)
            }
            return
        }

        let normalizedCurrentURL = currentURLString.lowercased()

        for job in waitingJobs {
            guard !jobIDsContinued.contains(job.id),
                  let needle = job.waitingStep?.doneWhenURLContains?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !needle.isEmpty else {
                continue
            }

            if normalizedCurrentURL.contains(needle.lowercased()) {
                jobIDsContinued.insert(job.id)
                jobStore.setWaitingStep(jobID: job.id, step: nil)
                if let updatedJob = jobStore.job(withID: job.id) {
                    onStepDone?(updatedJob, currentURLString)
                }
            } else {
                jobIDsSeenNotDone.insert(job.id)
            }
        }
    }
}
