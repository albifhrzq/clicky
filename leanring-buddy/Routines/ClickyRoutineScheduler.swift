//
//  ClickyRoutineScheduler.swift
//  leanring-buddy
//

import AppKit
import Combine
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Network

public nonisolated enum ClickyRoutineRunTrigger: String, Codable, Sendable {
    case scheduled
    case manual
}

public nonisolated enum ClickyRoutineRunOutcome: Equatable, Sendable {
    case succeeded(summary: String?)
    case failed(summary: String?, transientConnectivity: Bool)
    case skippedBusy
}

public nonisolated struct ClickyRoutine: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var clickySlug: String?
    public var jobID: String?
    public var title: String
    public var taskPrompt: String
    public var intervalSeconds: TimeInterval
    public let createdAt: Date
    public var isPaused: Bool
    public var nextRunAt: Date?
    public var runCount: Int
    public var lastRunStartedAt: Date?
    public var lastRunFinishedAt: Date?
    public var lastRunSummary: String?
    public var lastRunFailed: Bool
    public var pendingRetryAt: Date?
    public var lastRunTaskIdentifier: String?
    public var consecutiveFailedRunCount: Int
    public var waitingForNetworkSince: Date?
    public var scheduledMinuteOfDay: Int?
    public var scheduledWeekday: Int?
    public var scheduledWeekdays: [Int]?

    enum CodingKeys: String, CodingKey {
        case id
        case clickySlug
        case jobID
        case title
        case taskPrompt
        case intervalSeconds
        case createdAt
        case isPaused
        case nextRunAt
        case runCount
        case lastRunStartedAt
        case lastRunFinishedAt
        case lastRunSummary
        case lastRunFailed
        case pendingRetryAt
        case lastRunTaskIdentifier
        case consecutiveFailedRunCount
        case waitingForNetworkSince
        case scheduledMinuteOfDay
        case scheduledWeekday
        case scheduledWeekdays
    }

    public var intervalMinutes: Int {
        get { max(1, Int((intervalSeconds / 60.0).rounded())) }
        set { intervalSeconds = TimeInterval(max(1, newValue) * 60) }
    }

    public init(
        id: String = UUID().uuidString,
        clickySlug: String? = nil,
        jobID: String? = nil,
        title: String,
        taskPrompt: String,
        intervalMinutes: Int = 1440,
        createdAt: Date = Date(),
        isPaused: Bool = false,
        nextRunAt: Date? = nil,
        runCount: Int = 0,
        lastRunStartedAt: Date? = nil,
        lastRunFinishedAt: Date? = nil,
        lastRunSummary: String? = nil,
        lastRunFailed: Bool = false,
        pendingRetryAt: Date? = nil,
        lastRunTaskIdentifier: String? = nil,
        consecutiveFailedRunCount: Int = 0,
        waitingForNetworkSince: Date? = nil,
        scheduledMinuteOfDay: Int? = nil,
        scheduledWeekday: Int? = nil,
        scheduledWeekdays: [Int]? = nil
    ) {
        self.id = id
        self.clickySlug = clickySlug
        self.jobID = jobID
        self.title = title
        self.taskPrompt = taskPrompt
        self.intervalSeconds = TimeInterval(max(1, intervalMinutes) * 60)
        self.createdAt = createdAt
        self.isPaused = isPaused
        self.runCount = runCount
        self.lastRunStartedAt = lastRunStartedAt
        self.lastRunFinishedAt = lastRunFinishedAt
        self.lastRunSummary = lastRunSummary
        self.lastRunFailed = lastRunFailed
        self.pendingRetryAt = pendingRetryAt
        self.lastRunTaskIdentifier = lastRunTaskIdentifier
        self.consecutiveFailedRunCount = consecutiveFailedRunCount
        self.waitingForNetworkSince = waitingForNetworkSince
        self.scheduledMinuteOfDay = scheduledMinuteOfDay
        self.scheduledWeekday = scheduledWeekday
        self.scheduledWeekdays = scheduledWeekdays
        if let nextRunAt {
            self.nextRunAt = nextRunAt
        } else {
            self.nextRunAt = computeNextRunDate(after: createdAt)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.clickySlug = try container.decodeIfPresent(String.self, forKey: .clickySlug)
        self.jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        self.title = try container.decode(String.self, forKey: .title)
        self.taskPrompt = try container.decode(String.self, forKey: .taskPrompt)
        self.intervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .intervalSeconds) ?? 86_400
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        self.nextRunAt = try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
        self.runCount = try container.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        self.lastRunStartedAt = try container.decodeIfPresent(Date.self, forKey: .lastRunStartedAt)
        self.lastRunFinishedAt = try container.decodeIfPresent(Date.self, forKey: .lastRunFinishedAt)
        self.lastRunSummary = try container.decodeIfPresent(String.self, forKey: .lastRunSummary)
        self.lastRunFailed = try container.decodeIfPresent(Bool.self, forKey: .lastRunFailed) ?? false
        self.pendingRetryAt = try container.decodeIfPresent(Date.self, forKey: .pendingRetryAt)
        self.lastRunTaskIdentifier = try container.decodeIfPresent(String.self, forKey: .lastRunTaskIdentifier)
        self.consecutiveFailedRunCount = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailedRunCount) ?? 0
        self.waitingForNetworkSince = try container.decodeIfPresent(Date.self, forKey: .waitingForNetworkSince)
        self.scheduledMinuteOfDay = try container.decodeIfPresent(Int.self, forKey: .scheduledMinuteOfDay)
        self.scheduledWeekday = try container.decodeIfPresent(Int.self, forKey: .scheduledWeekday)
        self.scheduledWeekdays = try container.decodeIfPresent([Int].self, forKey: .scheduledWeekdays)
    }

    public var resolvedWeekdays: [Int] {
        if let scheduledWeekdays, !scheduledWeekdays.isEmpty {
            return Array(Set(scheduledWeekdays.filter { day in (1...7).contains(day) })).sorted()
        }
        if let scheduledWeekday, (1...7).contains(scheduledWeekday) {
            return [scheduledWeekday]
        }
        return []
    }

    public func computeNextRunDate(after referenceDate: Date, calendar: Calendar = .current) -> Date {
        let allowedWeekdays = resolvedWeekdays
        if let minuteOfDay = scheduledMinuteOfDay {
            let clampedMinute = min(max(0, minuteOfDay), 1439)
            let targetHour = clampedMinute / 60
            let targetMinute = clampedMinute % 60

            // Search up to 8 days ahead for the next matching day & time strictly after referenceDate.
            let startOfReferenceDay = calendar.startOfDay(for: referenceDate)
            for dayOffset in 0...8 {
                guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: startOfReferenceDay) else {
                    continue
                }
                let weekday = calendar.component(.weekday, from: candidateDay)
                if !allowedWeekdays.isEmpty && !allowedWeekdays.contains(weekday) {
                    continue
                }
                if let candidate = calendar.date(
                    bySettingHour: targetHour,
                    minute: targetMinute,
                    second: 0,
                    of: candidateDay
                ), candidate > referenceDate {
                    return candidate
                }
            }
        }

        if !allowedWeekdays.isEmpty {
            let referenceHour = calendar.component(.hour, from: referenceDate)
            let referenceMinute = calendar.component(.minute, from: referenceDate)
            let startOfReferenceDay = calendar.startOfDay(for: referenceDate)
            for dayOffset in 1...8 {
                guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: startOfReferenceDay) else {
                    continue
                }
                let weekday = calendar.component(.weekday, from: candidateDay)
                if allowedWeekdays.contains(weekday),
                   let candidate = calendar.date(
                    bySettingHour: referenceHour,
                    minute: referenceMinute,
                    second: 0,
                    of: candidateDay
                   ) {
                    return candidate
                }
            }
        }

        let safeInterval = max(60, intervalSeconds)
        return referenceDate.addingTimeInterval(safeInterval)
    }

    public var cadenceLabel: String {
        let weekdays = resolvedWeekdays
        let timeString: String?
        if let minuteOfDay = scheduledMinuteOfDay {
            let hour = minuteOfDay / 60
            let minute = minuteOfDay % 60
            timeString = String(format: "%02d:%02d", hour, minute)
        } else {
            timeString = nil
        }

        if !weekdays.isEmpty {
            let label: String
            if weekdays == [2, 3, 4, 5, 6] {
                label = "Every weekday"
            } else if weekdays == [1, 7] {
                label = "Every weekend"
            } else {
                let symbols = Calendar.current.weekdaySymbols
                let names = weekdays.compactMap { weekday -> String? in
                    let zeroBased = weekday - 1
                    return symbols.indices.contains(zeroBased) ? symbols[zeroBased] : nil
                }
                label = "Every \(names.joined(separator: ", "))"
            }
            if let timeString {
                return "\(label) at \(timeString)"
            }
            return label
        }

        if let timeString {
            return "Every day at \(timeString)"
        }

        let minutes = intervalMinutes
        if minutes == 60 {
            return "Every hour"
        }
        if minutes == 1440 {
            return "Every day"
        }
        if minutes % 1440 == 0 {
            return "Every \(minutes / 1440) days"
        }
        if minutes % 60 == 0 {
            return "Every \(minutes / 60) hours"
        }
        return "Every \(minutes) minutes"
    }
}

/// Monitors network reachability via `NWPathMonitor` so due routines hold
/// cleanly while offline without burning retries.
public nonisolated final class ClickyRoutineNetworkObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.heyclicky.routine-network", qos: .utility)
    private let stateLock = NSLock()
    private var monitor: NWPathMonitor?
    private var isCancelled = false
    private let onAvailabilityChanged: @MainActor @Sendable (Bool) -> Void

    public init(onAvailabilityChanged: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onAvailabilityChanged = onAvailabilityChanged
    }

    public func start() {
        stateLock.lock()
        guard monitor == nil else {
            stateLock.unlock()
            return
        }
        isCancelled = false
        let pathMonitor = NWPathMonitor()
        monitor = pathMonitor
        stateLock.unlock()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.stateLock.lock()
            let cancelled = self.isCancelled
            self.stateLock.unlock()
            guard !cancelled else { return }

            let available = (path.status == .satisfied)
            let callback = self.onAvailabilityChanged
            Task { @MainActor in
                callback(available)
            }
        }
        pathMonitor.start(queue: queue)
    }

    public func stop() {
        stateLock.lock()
        isCancelled = true
        let activeMonitor = monitor
        monitor = nil
        stateLock.unlock()
        activeMonitor?.cancel()
    }

    deinit {
        stop()
    }
}

/// Observes `NSWorkspace` sleep/wake & screen wake notifications to distinguish
/// dark wakes (Power Nap) from full user wakes.
@MainActor
public final class ClickyRoutineFullWakeObserver {
    private var observers: [NSObjectProtocol] = []
    private var isCancelled = false
    private var isAwaitingScreensSinceSleep = false
    private var isAwaitingFullWakeSinceSleep = false
    private var awakeScreensFirstObservedAt: Date?
    private var settleTask: Task<Void, Never>?

    private let onSleepStateChanged: (Bool) -> Void
    private let onFullWake: () -> Void

    public var isInDarkWakeOrSleep: Bool {
        isAwaitingScreensSinceSleep || isAwaitingFullWakeSinceSleep
    }

    public init(
        onSleepStateChanged: @escaping (Bool) -> Void,
        onFullWake: @escaping () -> Void
    ) {
        self.onSleepStateChanged = onSleepStateChanged
        self.onFullWake = onFullWake
    }

    public func start() {
        guard observers.isEmpty else { return }
        isCancelled = false
        let center = NSWorkspace.shared.notificationCenter

        observers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWillSleep()
                }
            }
        )

        observers.append(
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleScreensDidSleep()
                }
            }
        )

        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDidWake()
                }
            }
        )

        observers.append(
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleScreensDidWake()
                }
            }
        )
    }

    public func stop() {
        isCancelled = true
        settleTask?.cancel()
        settleTask = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleWillSleep() {
        guard !isCancelled else { return }
        isAwaitingScreensSinceSleep = true
        isAwaitingFullWakeSinceSleep = true
        awakeScreensFirstObservedAt = nil
        settleTask?.cancel()
        settleTask = nil
        onSleepStateChanged(true)
    }

    private func handleScreensDidSleep() {
        guard !isCancelled else { return }
        isAwaitingScreensSinceSleep = true
        onSleepStateChanged(true)
    }

    private func handleDidWake() {
        guard !isCancelled else { return }
        // If screens haven't woken yet, this may be a dark wake (Power Nap).
        // Keep holding routines until screensDidWake arrives.
        if isAwaitingScreensSinceSleep {
            isAwaitingFullWakeSinceSleep = true
            onSleepStateChanged(true)
        }
    }

    private func handleScreensDidWake() {
        guard !isCancelled else { return }
        isAwaitingScreensSinceSleep = false
        awakeScreensFirstObservedAt = Date()
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, !self.isCancelled else { return }
            self.isAwaitingFullWakeSinceSleep = false
            self.onSleepStateChanged(false)
            self.onFullWake()
        }
    }
}

/// Holds a `PreventUserIdleSystemSleep` `IOPMAssertion` while routines are armed
/// and the Mac is running on AC power.
@MainActor
public final class ClickyRoutineKeepAwake {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var isAssertionActive = false

    public init() {}

    public static func isOnACPower() -> Bool {
        guard let unmanagedSourceType = IOPSGetProvidingPowerSourceType(nil) else {
            return false
        }
        let sourceType = unmanagedSourceType.takeUnretainedValue() as String
        return sourceType == (kIOPSACPowerValue as String) || sourceType == "AC Power"
    }

    @discardableResult
    public func sync(hasArmedRoutines: Bool) -> Bool {
        let shouldHold = hasArmedRoutines && Self.isOnACPower()
        if shouldHold && !isAssertionActive {
            var newAssertionID: IOPMAssertionID = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "HeyClicky is running a routine on a schedule" as CFString,
                &newAssertionID
            )
            if status == kIOReturnSuccess {
                assertionID = newAssertionID
                isAssertionActive = true
            }
        } else if !shouldHold && isAssertionActive {
            release()
        }
        return isAssertionActive
    }

    public func release() {
        guard isAssertionActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isAssertionActive = false
    }
}

public nonisolated enum RepeatJobAction: String, Codable, Sendable {
    case set
    case pause
    case resume
    case stop
}

public nonisolated struct RepeatJobResult: Equatable, Codable, Sendable {
    public let ok: Bool
    public let status: String
    public let routineID: String?
    public let nextRunAt: Date?
    public let message: String
}

@MainActor
public final class ClickyRoutineScheduler: ObservableObject {
    public static let shared = ClickyRoutineScheduler()

    public static let routinesDefaultsKey = "clicky.starterAgents.routines.v1"
    public static let maxConsecutiveFailures = 3

    private let defaults: UserDefaults

    @Published private(set) var routines: [ClickyRoutine] = []
    @Published private(set) var isNetworkAvailable: Bool = true
    @Published private(set) var isSleepingOrDarkWake: Bool = false
    @Published private(set) var isKeepAwakeAssertionActive: Bool = false

    public var onDispatchRoutine: (@MainActor (ClickyRoutine, ClickyRoutineRunTrigger) async -> ClickyRoutineRunOutcome)?

    private var pollTimer: Timer?
    private var networkObserver: ClickyRoutineNetworkObserver?
    private var fullWakeObserver: ClickyRoutineFullWakeObserver?
    private let keepAwake = ClickyRoutineKeepAwake()
    private var inFlightRoutineIDs: Set<String> = []
    private var isEvaluating = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.routines = Self.loadRoutines(from: defaults)
        syncJobStoreFlags()
    }

    public func start(pollIntervalSeconds: TimeInterval = 30.0) {
        stop()

        let netObserver = ClickyRoutineNetworkObserver { [weak self] available in
            guard let self else { return }
            let becameOnline = !self.isNetworkAvailable && available
            self.isNetworkAvailable = available
            if becameOnline {
                Task { @MainActor [weak self] in
                    await self?.evaluateDueRoutines()
                }
            }
        }
        netObserver.start()
        self.networkObserver = netObserver

        let wakeObserver = ClickyRoutineFullWakeObserver(
            onSleepStateChanged: { [weak self] sleeping in
                self?.isSleepingOrDarkWake = sleeping
            },
            onFullWake: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.evaluateDueRoutines()
                }
            }
        )
        wakeObserver.start()
        self.fullWakeObserver = wakeObserver

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.evaluateDueRoutines()
            }
        }

        syncKeepAwakeAssertion()
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        networkObserver?.stop()
        networkObserver = nil
        fullWakeObserver?.stop()
        fullWakeObserver = nil
        keepAwake.release()
        isKeepAwakeAssertionActive = false
    }

    @discardableResult
    public func addOrUpdate(_ routine: ClickyRoutine) -> ClickyRoutine {
        var resolved = routine
        if resolved.nextRunAt == nil && !resolved.isPaused {
            resolved.nextRunAt = resolved.computeNextRunDate(after: Date())
        }

        if let existingIndex = routines.firstIndex(where: { item in item.id == resolved.id }) {
            routines[existingIndex] = resolved
        } else {
            routines.append(resolved)
        }

        persistRoutines()
        syncJobStoreFlags()
        syncKeepAwakeAssertion()
        return resolved
    }

    public func togglePause(id: String) {
        guard let index = routines.firstIndex(where: { item in item.id == id }) else { return }
        setPaused(id: id, paused: !routines[index].isPaused)
    }

    public func setPaused(id: String, paused: Bool) {
        guard let index = routines.firstIndex(where: { item in item.id == id }) else { return }
        routines[index].isPaused = paused
        if !paused {
            routines[index].consecutiveFailedRunCount = 0
            routines[index].waitingForNetworkSince = nil
            let now = Date()
            if routines[index].nextRunAt == nil || (routines[index].nextRunAt ?? now) <= now {
                routines[index].nextRunAt = routines[index].computeNextRunDate(after: now)
            }
        }
        persistRoutines()
        syncKeepAwakeAssertion()
    }

    public func delete(id: String) {
        routines.removeAll { item in item.id == id }
        persistRoutines()
        syncJobStoreFlags()
        syncKeepAwakeAssertion()
    }

    public func routine(forJobID jobID: String) -> ClickyRoutine? {
        routines.first { item in item.jobID == jobID }
    }

    public func routines(forClickySlug slug: String) -> [ClickyRoutine] {
        routines.filter { item in item.clickySlug == slug }
    }

    public func runNow(id: String) async {
        guard let index = routines.firstIndex(where: { item in item.id == id }) else { return }
        await dispatchRoutine(at: index, trigger: .manual, now: Date())
    }

    public func evaluateDueRoutines(now: Date = Date()) async {
        guard !isEvaluating else { return }
        guard !isSleepingOrDarkWake else { return }

        isEvaluating = true
        defer {
            isEvaluating = false
            syncKeepAwakeAssertion()
        }

        for index in routines.indices {
            let routine = routines[index]
            guard !routine.isPaused,
                  !inFlightRoutineIDs.contains(routine.id),
                  let nextRunAt = routine.nextRunAt,
                  nextRunAt <= now else {
                continue
            }

            if !isNetworkAvailable {
                if routines[index].waitingForNetworkSince == nil {
                    routines[index].waitingForNetworkSince = now
                    persistRoutines()
                }
                continue
            }

            if routines[index].waitingForNetworkSince != nil {
                routines[index].waitingForNetworkSince = nil
                persistRoutines()
            }

            await dispatchRoutine(at: index, trigger: .scheduled, now: now)
        }
    }

    public func recordRunCompleted(
        routineID: String,
        failed: Bool,
        transientConnectivityError: Bool = false,
        summary: String? = nil,
        now: Date = Date()
    ) {
        inFlightRoutineIDs.remove(routineID)
        guard let index = routines.firstIndex(where: { item in item.id == routineID }) else { return }

        routines[index].lastRunFinishedAt = now
        routines[index].lastRunSummary = summary
        routines[index].lastRunFailed = failed

        if failed {
            if transientConnectivityError {
                // Hold for network without burning consecutive failure retries.
                routines[index].waitingForNetworkSince = routines[index].waitingForNetworkSince ?? now
                routines[index].pendingRetryAt = now.addingTimeInterval(120)
            } else {
                routines[index].consecutiveFailedRunCount += 1
                routines[index].pendingRetryAt = nil
                if routines[index].consecutiveFailedRunCount >= Self.maxConsecutiveFailures {
                    routines[index].isPaused = true
                }
            }
        } else {
            routines[index].consecutiveFailedRunCount = 0
            routines[index].waitingForNetworkSince = nil
            routines[index].pendingRetryAt = nil
        }

        if !routines[index].isPaused {
            routines[index].nextRunAt = routines[index].computeNextRunDate(after: now)
        }

        persistRoutines()
        syncKeepAwakeAssertion()
    }

    /// Handles the local `repeat_this_job` MCP tool call.
    public func handleRepeatThisJob(
        jobID: String,
        clickySlug: String?,
        action: RepeatJobAction = .set,
        everyMinutes: Int? = nil,
        timeString: String? = nil,
        days: [String]? = nil,
        title: String? = nil,
        task: String? = nil,
        ranNow: Bool? = nil,
        now: Date = Date()
    ) -> RepeatJobResult {
        switch action {
        case .pause:
            guard let existing = routine(forJobID: jobID) else {
                return RepeatJobResult(ok: false, status: "not_found", routineID: nil, nextRunAt: nil, message: "No repeat schedule found on this job.")
            }
            setPaused(id: existing.id, paused: true)
            return RepeatJobResult(ok: true, status: "paused", routineID: existing.id, nextRunAt: nil, message: "Paused routine \"\(existing.title)\".")

        case .resume:
            guard let existing = routine(forJobID: jobID) else {
                return RepeatJobResult(ok: false, status: "not_found", routineID: nil, nextRunAt: nil, message: "No repeat schedule found on this job.")
            }
            setPaused(id: existing.id, paused: false)
            let updated = routine(forJobID: jobID)
            return RepeatJobResult(ok: true, status: "resumed", routineID: existing.id, nextRunAt: updated?.nextRunAt, message: "Resumed routine \"\(existing.title)\".")

        case .stop:
            guard let existing = routine(forJobID: jobID) else {
                return RepeatJobResult(ok: false, status: "not_found", routineID: nil, nextRunAt: nil, message: "No repeat schedule found on this job.")
            }
            delete(id: existing.id)
            return RepeatJobResult(ok: true, status: "stopped", routineID: existing.id, nextRunAt: nil, message: "Stopped and removed routine \"\(existing.title)\".")

        case .set:
            let existing = routine(forJobID: jobID)
            let parsedMinuteOfDay = timeString.flatMap { value in Self.parseMinuteOfDay(value) }
                ?? existing?.scheduledMinuteOfDay
            let parsedWeekdays = days.map { dayList in Self.parseWeekdays(dayList) }
            let resolvedWeekdays: [Int]?
            if let parsedWeekdays {
                resolvedWeekdays = parsedWeekdays.isEmpty ? nil : parsedWeekdays
            } else {
                resolvedWeekdays = existing?.scheduledWeekdays
            }

            let resolvedIntervalMinutes: Int
            if let everyMinutes {
                resolvedIntervalMinutes = min(max(2, everyMinutes), 10_080)
            } else if resolvedWeekdays != nil || parsedMinuteOfDay != nil {
                resolvedIntervalMinutes = 1440
            } else {
                resolvedIntervalMinutes = existing?.intervalMinutes ?? 1440
            }

            let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = (resolvedTitle?.isEmpty == false ? resolvedTitle! : existing?.title) ?? "Scheduled job"

            let resolvedTask = task?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTask = (resolvedTask?.isEmpty == false ? resolvedTask! : existing?.taskPrompt) ?? ""
            guard !finalTask.isEmpty else {
                return RepeatJobResult(ok: false, status: "invalid", routineID: existing?.id, nextRunAt: nil, message: "A task prompt is required to set a repeat schedule.")
            }

            var updated = existing ?? ClickyRoutine(
                clickySlug: clickySlug,
                jobID: jobID,
                title: finalTitle,
                taskPrompt: finalTask,
                intervalMinutes: resolvedIntervalMinutes,
                createdAt: now
            )
            updated.clickySlug = clickySlug ?? updated.clickySlug
            updated.jobID = jobID
            updated.title = finalTitle
            updated.taskPrompt = finalTask
            updated.intervalMinutes = resolvedIntervalMinutes
            updated.scheduledMinuteOfDay = parsedMinuteOfDay
            updated.scheduledWeekdays = resolvedWeekdays
            updated.scheduledWeekday = (resolvedWeekdays?.count == 1) ? resolvedWeekdays?.first : nil
            updated.isPaused = false
            updated.consecutiveFailedRunCount = 0
            updated.waitingForNetworkSince = nil

            if existing == nil && ranNow == true {
                updated.runCount = max(1, updated.runCount + 1)
                updated.lastRunStartedAt = now
                updated.lastRunFinishedAt = now
            }

            updated.nextRunAt = updated.computeNextRunDate(after: now)
            let saved = addOrUpdate(updated)

            return RepeatJobResult(
                ok: true,
                status: existing == nil ? "created" : "updated",
                routineID: saved.id,
                nextRunAt: saved.nextRunAt,
                message: "Scheduled \"\(saved.title)\" (\(saved.cadenceLabel))."
            )
        }
    }

    private func dispatchRoutine(
        at index: Int,
        trigger: ClickyRoutineRunTrigger,
        now: Date
    ) async {
        guard routines.indices.contains(index) else { return }
        let routineID = routines[index].id
        inFlightRoutineIDs.insert(routineID)

        routines[index].lastRunStartedAt = now
        routines[index].runCount += 1
        routines[index].nextRunAt = routines[index].computeNextRunDate(after: now)
        persistRoutines()

        guard let dispatcher = onDispatchRoutine else {
            inFlightRoutineIDs.remove(routineID)
            return
        }

        let currentRoutine = routines[index]
        let outcome = await dispatcher(currentRoutine, trigger)

        switch outcome {
        case .succeeded(let summary):
            recordRunCompleted(routineID: routineID, failed: false, transientConnectivityError: false, summary: summary)
        case .failed(let summary, let transientConnectivity):
            recordRunCompleted(routineID: routineID, failed: true, transientConnectivityError: transientConnectivity, summary: summary)
        case .skippedBusy:
            inFlightRoutineIDs.remove(routineID)
            if let refreshedIndex = routines.firstIndex(where: { item in item.id == routineID }) {
                routines[refreshedIndex].nextRunAt = Date().addingTimeInterval(60)
                persistRoutines()
            }
        }
    }

    private func syncJobStoreFlags() {
        let jobIDs = Set(routines.compactMap(\.jobID))
        ClickyJobStore.shared.jobIDsWithRoutines = jobIDs
    }

    private func syncKeepAwakeAssertion() {
        let hasArmed = routines.contains { routine in !routine.isPaused }
        isKeepAwakeAssertionActive = keepAwake.sync(hasArmedRoutines: hasArmed)
    }

    private static func loadRoutines(from defaults: UserDefaults) -> [ClickyRoutine] {
        guard let data = defaults.data(forKey: routinesDefaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ClickyRoutine].self, from: data) {
            return decoded
        }
        return (try? JSONDecoder().decode([ClickyRoutine].self, from: data)) ?? []
    }

    private func persistRoutines() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let encoded = try? encoder.encode(routines) {
            defaults.set(encoded, forKey: Self.routinesDefaultsKey)
        }
    }

    public nonisolated static func parseMinuteOfDay(_ timeString: String) -> Int? {
        let trimmed = timeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    public nonisolated static func parseWeekdays(_ dayNames: [String]) -> [Int] {
        let lookup: [String: Int] = [
            "sun": 1, "sunday": 1,
            "mon": 2, "monday": 2,
            "tue": 3, "tues": 3, "tuesday": 3,
            "wed": 4, "wednesday": 4,
            "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
            "fri": 6, "friday": 6,
            "sat": 7, "saturday": 7
        ]
        var weekdays: [Int] = []
        for name in dayNames {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let mapped = lookup[key], !weekdays.contains(mapped) {
                weekdays.append(mapped)
            }
        }
        return weekdays.sorted()
    }
}
