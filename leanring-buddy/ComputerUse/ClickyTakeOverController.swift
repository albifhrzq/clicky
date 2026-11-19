//
//  ClickyTakeOverController.swift
//  leanring-buddy
//
//  Coordinates mac_step computer-use consent, driving lifecycle, and
//  CGEventTap + NSEvent user-input monitoring that immediately aborts driving
//  if the user moves the mouse or presses Escape.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

// MARK: - Public Contract Types

nonisolated public enum TakeOverPhase: String, Sendable, Equatable {
    case idle
    case offered
    case driving
}

nonisolated public enum TakeOverConsentDecision: String, Sendable, Equatable {
    case approve
    case decline
}

nonisolated public struct TakeOverConsentRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let step: String
    public let shortTitle: String
    public let reason: String?
    public let requestedAt: Date

    public init(
        id: UUID = UUID(),
        step: String,
        shortTitle: String,
        reason: String? = nil,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.step = step
        self.shortTitle = shortTitle
        self.reason = reason
        self.requestedAt = requestedAt
    }
}

nonisolated public struct AgentDriveOutcome: Equatable, Sendable {
    public enum Ending: String, Sendable, Equatable {
        case finished
        case userTookOver = "user_took_over"
        case safetyStop = "safety_check"
        case couldNotSee = "could_not_see"
        case outOfAgentMessages = "out_of_agent_messages"
        case failed
    }

    public let ending: Ending
    public let summary: String
    public let actions: Int

    public init(ending: Ending, summary: String, actions: Int = 0) {
        self.ending = ending
        self.summary = summary
        self.actions = actions
    }
}

nonisolated public enum ClickyTakeOverError: LocalizedError, Sendable {
    case busy
    case declined
    case userTookOver
    case accessibilityNotGranted
    case missingExecutor
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .busy:
            return "Clicky was already driving the screen, so nothing was done for this step."
        case .declined:
            return "The user said not now to this step."
        case .userTookOver:
            return "The user took the screen back partway through, so this step may not be finished."
        case .accessibilityNotGranted:
            return "Accessibility permission is required to control the screen."
        case .missingExecutor:
            return "No screen-driving step executor is configured yet."
        case .timedOut:
            return "The user didn't answer the screen control request in time."
        }
    }
}

// MARK: - Thread-Safe User Takeover Flag & Input Monitor

nonisolated private final class AtomicTakeOverSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var tookOver = false
    private var lastKnownMouseLocation: CGPoint?

    func reset(initialMouseLocation: CGPoint?) {
        lock.lock()
        tookOver = false
        lastKnownMouseLocation = initialMouseLocation
        lock.unlock()
    }

    func markTookOver() -> Bool {
        lock.lock()
        let wasAlreadySet = tookOver
        tookOver = true
        lock.unlock()
        return !wasAlreadySet
    }

    func isTookOver() -> Bool {
        lock.lock()
        let value = tookOver
        lock.unlock()
        return value
    }

    /// Filters micro-jitter so tiny 1px sensor noise does not prematurely abort,
    /// while deliberate mouse movement (> 4pt) immediately triggers takeover.
    func recordMouseMove(_ point: CGPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if tookOver { return false }
        guard let previous = lastKnownMouseLocation else {
            lastKnownMouseLocation = point
            return false
        }
        let distance = hypot(point.x - previous.x, point.y - previous.y)
        if distance >= 4.0 {
            tookOver = true
            return true
        }
        return false
    }
}

// MARK: - TakeOver Controller

@MainActor
public final class ClickyTakeOverController: ObservableObject {
    public static let shared = ClickyTakeOverController()

    private static let consentTimeoutSeconds: TimeInterval = 180.0

    @Published public private(set) var phase: TakeOverPhase = .idle
    @Published public var pendingConsent: TakeOverConsentRequest?
    @Published public private(set) var userTookOver: Bool = false
    @Published public private(set) var overlayStatus: String = ""
    @Published public private(set) var endSummary: String?
    @Published public private(set) var lastTakeOverEndedAt: Date?

    public let driver: ClickyAppDriver

    public var onConsentRequested: ((TakeOverConsentRequest) -> Void)?
    public var onPhaseChanged: ((TakeOverPhase) -> Void)?
    public var onUserTookOver: ((String) -> Void)?

    /// Pluggable vision/action loop for `mac_step` provided by the agent/LLM orchestrator.
    public var stepExecutor: (@MainActor (_ request: TakeOverConsentRequest, _ driver: ClickyAppDriver) async throws -> AgentDriveOutcome)?

    private let atomicSignal = AtomicTakeOverSignal()
    private var consentContinuation: CheckedContinuation<TakeOverConsentDecision, Never>?
    private var activeConsentID: UUID?
    private var drivingTask: Task<AgentDriveOutcome, Error>?

    // Event monitors (CGEventTap + NSEvent fallback)
    private var cgEventTap: CFMachPort?
    private var cgEventTapRunLoopSource: CFRunLoopSource?
    private var nsGlobalMonitor: Any?
    private var nsLocalMonitor: Any?

    private init() {
        let signal = atomicSignal
        self.driver = ClickyAppDriver(shouldAbortCheck: {
            signal.isTookOver()
        })
    }

    // MARK: - Public mac_step Entry Point

    public func runMacStep(
        step: String,
        shortTitle: String? = nil,
        reason: String? = nil
    ) async throws -> String {
        let trimmedStep = step.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStep.isEmpty else {
            throw ClickyTakeOverError.missingExecutor
        }

        guard phase == .idle && pendingConsent == nil else {
            throw ClickyTakeOverError.busy
        }

        let resolvedTitle = (shortTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.deriveShortTitle(from: trimmedStep)

        let request = TakeOverConsentRequest(
            step: trimmedStep,
            shortTitle: resolvedTitle,
            reason: reason
        )

        let decision = await requestConsent(for: request)
        guard decision == .approve else {
            throw ClickyTakeOverError.declined
        }

        let outcome = try await executeDrive(for: request)
        switch outcome.ending {
        case .finished:
            return outcome.summary.isEmpty ? "Completed: \(resolvedTitle)" : outcome.summary
        case .userTookOver:
            throw ClickyTakeOverError.userTookOver
        case .safetyStop, .couldNotSee, .outOfAgentMessages, .failed:
            return outcome.summary
        }
    }

    // MARK: - Consent Flow

    public func requestConsent(for request: TakeOverConsentRequest) async -> TakeOverConsentDecision {
        phase = .offered
        pendingConsent = request
        activeConsentID = request.id
        overlayStatus = request.shortTitle
        onPhaseChanged?(.offered)
        onConsentRequested?(request)

        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<TakeOverConsentDecision, Never>) in
            consentContinuation = continuation

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.consentTimeoutSeconds * 1_000_000_000))
                guard let self else { return }
                if self.activeConsentID == request.id {
                    self.resolvePendingConsent(.decline)
                }
            }
        }

        if decision == .decline {
            phase = .idle
            overlayStatus = ""
            onPhaseChanged?(.idle)
        }

        return decision
    }

    public func resolvePendingConsent(_ decision: TakeOverConsentDecision) {
        pendingConsent = nil
        activeConsentID = nil

        if let continuation = consentContinuation {
            consentContinuation = nil
            continuation.resume(returning: decision)
        }
    }

    // MARK: - Driving Execution & User Takeover Abort

    public func executeDrive(for request: TakeOverConsentRequest) async throws -> AgentDriveOutcome {
        guard AXIsProcessTrusted() else {
            phase = .idle
            overlayStatus = ""
            onPhaseChanged?(.idle)
            throw ClickyTakeOverError.accessibilityNotGranted
        }

        userTookOver = false
        driver.resetTakeOverState()
        atomicSignal.reset(initialMouseLocation: driver.currentCursorPosition())

        phase = .driving
        overlayStatus = String(localized: "Hands off the mouse while I drive. Esc stops me.")
        endSummary = nil
        onPhaseChanged?(.driving)

        startUserInputMonitor()

        defer {
            stopUserInputMonitor()
            drivingTask = nil
            lastTakeOverEndedAt = Date()
            phase = .idle
            onPhaseChanged?(.idle)
        }

        guard let stepExecutor else {
            // Even when no vision loop is attached yet, verify monitor & driver are ready
            // and return a structured outcome rather than crashing.
            let outcome = AgentDriveOutcome(
                ending: .failed,
                summary: String(localized: "I can't see the screen right now."),
                actions: 0
            )
            endSummary = outcome.summary
            return outcome
        }

        let task = Task<AgentDriveOutcome, Error> {
            try await stepExecutor(request, driver)
        }
        drivingTask = task

        do {
            let outcome = try await task.value
            if userTookOver || atomicSignal.isTookOver() {
                let takeoverOutcome = AgentDriveOutcome(
                    ending: .userTookOver,
                    summary: "The user took the screen back partway through, so this step may not be finished.",
                    actions: outcome.actions
                )
                endSummary = takeoverOutcome.summary
                return takeoverOutcome
            }
            endSummary = outcome.summary
            return outcome
        } catch is CancellationError {
            let ending: AgentDriveOutcome.Ending = (userTookOver || atomicSignal.isTookOver()) ? .userTookOver : .failed
            let summary = ending == .userTookOver
                ? "The user took the screen back partway through, so this step may not be finished."
                : String(localized: "I stopped there: \(String(localized: "screen control ended")). It's yours.")
            let outcome = AgentDriveOutcome(ending: ending, summary: summary, actions: 0)
            endSummary = summary
            return outcome
        } catch ClickyAppDriverError.userTookOver {
            let outcome = AgentDriveOutcome(
                ending: .userTookOver,
                summary: "The user took the screen back partway through, so this step may not be finished.",
                actions: 0
            )
            endSummary = outcome.summary
            return outcome
        } catch {
            let lostConnectionCodes: [URLError.Code] = [.networkConnectionLost, .notConnectedToInternet]
            let isConnectionLost = (error as? URLError).map { lostConnectionCodes.contains($0.code) } ?? false
            let outcome = AgentDriveOutcome(
                ending: .failed,
                summary: isConnectionLost
                    ? String(localized: "I lost the connection partway, so I stopped there.")
                    : error.localizedDescription,
                actions: 0
            )
            endSummary = outcome.summary
            throw error
        }
    }

    public func updateOverlayStatus(_ status: String) {
        overlayStatus = status
    }

    public func abortForUserTakeOver(reason: String = "user_input") {
        let shouldNotify = atomicSignal.markTookOver()
        driver.markUserTookOver()

        if !userTookOver {
            userTookOver = true
        }
        if shouldNotify {
            overlayStatus = String(localized: "Okay, it's all yours.")
            drivingTask?.cancel()
            onUserTookOver?(reason)
        }
    }

    // MARK: - User Input Monitors (CGEventTap + NSEvent)

    public func startUserInputMonitor() {
        stopUserInputMonitor()

        // 1. Primary monitor: listen-only CGEventTap (sees global mouse moves, clicks, and Escape)
        let monitoredEvents: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .keyDown
        ]
        let eventMask = monitoredEvents.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }

        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let controller = Unmanaged<ClickyTakeOverController>.fromOpaque(userInfo).takeUnretainedValue()
            return controller.handleCGEventTap(eventType: eventType, event: event)
        }

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ),
           let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            cgEventTap = tap
            cgEventTapRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        // 2. Redundant NSEvent global + local monitors (catches Escape or mouse activity
        // even if CGEventTap is disabled by macOS timeout or targeted to our own overlay)
        let nsMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]
        nsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: nsMask) { [weak self] event in
            self?.handleNSEvent(event)
        }
        nsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: nsMask) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    public func stopUserInputMonitor() {
        if let cgEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), cgEventTapRunLoopSource, .commonModes)
            self.cgEventTapRunLoopSource = nil
        }
        if let cgEventTap {
            CFMachPortInvalidate(cgEventTap)
            self.cgEventTap = nil
        }
        if let nsGlobalMonitor {
            NSEvent.removeMonitor(nsGlobalMonitor)
            self.nsGlobalMonitor = nil
        }
        if let nsLocalMonitor {
            NSEvent.removeMonitor(nsLocalMonitor)
            self.nsLocalMonitor = nil
        }
    }

    private nonisolated func handleCGEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                if let tap = self?.cgEventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore synthetic events created by ClickyAppDriver
        if event.getIntegerValueField(.eventSourceUserData) == ClickyAppDriver.syntheticEventUserDataTag {
            return Unmanaged.passUnretained(event)
        }

        switch eventType {
        case .mouseMoved:
            if atomicSignal.recordMouseMove(event.location) {
                Task { @MainActor [weak self] in
                    self?.abortForUserTakeOver(reason: "mouse_moved")
                }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if atomicSignal.markTookOver() {
                Task { @MainActor [weak self] in
                    self?.abortForUserTakeOver(reason: "mouse_clicked")
                }
            }
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == 53 { // Escape
                if atomicSignal.markTookOver() {
                    Task { @MainActor [weak self] in
                        self?.abortForUserTakeOver(reason: "escape_key")
                    }
                }
            }
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleNSEvent(_ event: NSEvent) {
        guard phase == .driving else { return }

        if let cgEvent = event.cgEvent,
           cgEvent.getIntegerValueField(.eventSourceUserData) == ClickyAppDriver.syntheticEventUserDataTag {
            return
        }

        switch event.type {
        case .mouseMoved:
            let cgPoint = driver.convertAppKitPointToCoreGraphics(NSEvent.mouseLocation)
            if atomicSignal.recordMouseMove(cgPoint) {
                abortForUserTakeOver(reason: "mouse_moved")
            }
        case .leftMouseDown, .rightMouseDown:
            abortForUserTakeOver(reason: "mouse_clicked")
        case .keyDown:
            if event.keyCode == 53 { // Escape
                abortForUserTakeOver(reason: "escape_key")
            }
        default:
            break
        }
    }

    // MARK: - MCP Tool Handler

    public func handleMacStepToolCall(_ arguments: [String: Any]) async -> ClickyMCPToolResult {
        guard let step = (arguments["step"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !step.isEmpty else {
            return ClickyMCPToolResult.error("Say the step: which app, what to do.")
        }

        let shortTitle = arguments["shortTitle"] as? String
        let reason = arguments["reason"] as? String

        do {
            let summary = try await runMacStep(step: step, shortTitle: shortTitle, reason: reason)
            return ClickyMCPToolResult.text(
                summary,
                structuredContent: [
                    "status": "drove",
                    "summary": summary
                ]
            )
        } catch ClickyTakeOverError.declined {
            return ClickyMCPToolResult.error(
                "The user said not now. Finish what you can without this step, and say in your reply exactly what's left for them to do there.",
                extra: ["status": "declined"]
            )
        } catch ClickyTakeOverError.busy {
            return ClickyMCPToolResult.error(
                "Clicky was already driving the screen, so nothing was done for this step. Finish what you can and say what's left.",
                extra: ["status": "busy"]
            )
        } catch ClickyTakeOverError.userTookOver {
            return ClickyMCPToolResult.error(
                "The user took the screen back partway through, so this step may not be finished.",
                extra: ["status": "user_took_over"]
            )
        } catch {
            return ClickyMCPToolResult.error(
                error.localizedDescription,
                extra: ["status": "failed"]
            )
        }
    }

    private static func deriveShortTitle(from step: String) -> String {
        let words = step.split(whereSeparator: { $0.isWhitespace })
        if words.count <= 8 {
            return step
        }
        return words.prefix(8).joined(separator: " ") + "…"
    }
}
