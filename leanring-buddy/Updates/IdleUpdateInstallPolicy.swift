//
//  IdleUpdateInstallPolicy.swift
//  leanring-buddy
//

import Combine
import Foundation
import Sparkle

public nonisolated enum IdleUpdateInstallWaitReason: String, CaseIterable, Equatable, Sendable {
    case onboardingInProgress = "onboarding_in_progress"
    case agentRunning = "agent_running"
    case voiceTurnActive = "voice_turn_active"
    case voiceSessionOpen = "voice_session_open"
    case recordingOrDictating = "recording_or_dictating"
    case notchOpen = "notch_open"
    case notchAnswerInProgress = "notch_answer_in_progress"
    case showingSomethingOnScreen = "showing_something_on_screen"
    case drivingTheMac = "driving_the_mac"
    case onACall = "on_a_call"
    case fullscreenApp = "fullscreen_app"
    case recentlyBusy = "recently_busy"
}

public nonisolated struct IdleUpdateInstallConditions: Equatable, Sendable {
    public var secondsSinceHeyClickyWasLastBusy: TimeInterval
    public var isOnboardingInProgress: Bool
    public var activeAgentTaskCount: Int
    public var isVoiceTurnActive: Bool
    public var isRealtimeVoiceSessionOpen: Bool
    public var isRecordingOrDictating: Bool
    public var isNotchOpen: Bool
    public var isNotchAnswerInProgress: Bool
    public var isShowingSomethingOnScreen: Bool
    public var isDrivingTheMac: Bool
    public var isOnACall: Bool
    public var isFrontmostAppFullscreen: Bool

    public init(
        secondsSinceHeyClickyWasLastBusy: TimeInterval,
        isOnboardingInProgress: Bool = false,
        activeAgentTaskCount: Int = 0,
        isVoiceTurnActive: Bool = false,
        isRealtimeVoiceSessionOpen: Bool = false,
        isRecordingOrDictating: Bool = false,
        isNotchOpen: Bool = false,
        isNotchAnswerInProgress: Bool = false,
        isShowingSomethingOnScreen: Bool = false,
        isDrivingTheMac: Bool = false,
        isOnACall: Bool = false,
        isFrontmostAppFullscreen: Bool = false
    ) {
        self.secondsSinceHeyClickyWasLastBusy = secondsSinceHeyClickyWasLastBusy
        self.isOnboardingInProgress = isOnboardingInProgress
        self.activeAgentTaskCount = activeAgentTaskCount
        self.isVoiceTurnActive = isVoiceTurnActive
        self.isRealtimeVoiceSessionOpen = isRealtimeVoiceSessionOpen
        self.isRecordingOrDictating = isRecordingOrDictating
        self.isNotchOpen = isNotchOpen
        self.isNotchAnswerInProgress = isNotchAnswerInProgress
        self.isShowingSomethingOnScreen = isShowingSomethingOnScreen
        self.isDrivingTheMac = isDrivingTheMac
        self.isOnACall = isOnACall
        self.isFrontmostAppFullscreen = isFrontmostAppFullscreen
    }
}

public nonisolated enum IdleUpdateInstallDecision: Equatable, Sendable {
    case wait(reasons: [IdleUpdateInstallWaitReason])
    case install

    public var logDescription: String {
        switch self {
        case .install:
            return "install"
        case .wait(let reasons):
            let joined = reasons.map(\.rawValue).joined(separator: ",")
            return "wait (\(joined))"
        }
    }
}

public nonisolated enum IdleUpdateInstallPolicy {
    public static let defaultRequiredIdleSeconds: TimeInterval = 300
    public static let debugQuietSecondsDefaultsKey = "debugIdleUpdateInstallQuietSeconds"

    public static func requiredIdleSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        if let override = defaults.object(forKey: debugQuietSecondsDefaultsKey) as? Double, override >= 0 {
            return override
        }
        return defaultRequiredIdleSeconds
    }

    public static func evaluate(
        _ conditions: IdleUpdateInstallConditions,
        requiredIdleSeconds: TimeInterval = defaultRequiredIdleSeconds
    ) -> IdleUpdateInstallDecision {
        var reasons: [IdleUpdateInstallWaitReason] = []

        if conditions.isOnboardingInProgress {
            reasons.append(.onboardingInProgress)
        }
        if conditions.activeAgentTaskCount > 0 {
            reasons.append(.agentRunning)
        }
        if conditions.isVoiceTurnActive {
            reasons.append(.voiceTurnActive)
        }
        if conditions.isRealtimeVoiceSessionOpen {
            reasons.append(.voiceSessionOpen)
        }
        if conditions.isRecordingOrDictating {
            reasons.append(.recordingOrDictating)
        }
        if conditions.isNotchOpen {
            reasons.append(.notchOpen)
        }
        if conditions.isNotchAnswerInProgress {
            reasons.append(.notchAnswerInProgress)
        }
        if conditions.isShowingSomethingOnScreen {
            reasons.append(.showingSomethingOnScreen)
        }
        if conditions.isDrivingTheMac {
            reasons.append(.drivingTheMac)
        }
        if conditions.isOnACall {
            reasons.append(.onACall)
        }
        if conditions.isFrontmostAppFullscreen {
            reasons.append(.fullscreenApp)
        }
        if conditions.secondsSinceHeyClickyWasLastBusy < requiredIdleSeconds {
            reasons.append(.recentlyBusy)
        }

        if reasons.isEmpty {
            return .install
        }
        return .wait(reasons: reasons)
    }
}

@MainActor
public final class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate, ObservableObject {
    @Published public private(set) var hasPendingIdleUpdateInstall: Bool = false
    @Published public private(set) var pendingUpdateVersion: String?
    @Published public private(set) var lastLoggedIdleUpdateInstallDecision: String?

    public var conditionsProvider: (() -> IdleUpdateInstallConditions)?
    public var autoInstallEnabled: Bool = true

    private var immediateInstallHandler: (() -> Void)?
    private var idleCheckTimer: Timer?
    private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        conditionsProvider: (() -> IdleUpdateInstallConditions)? = nil
    ) {
        self.defaults = defaults
        self.conditionsProvider = conditionsProvider
        super.init()
    }

    public func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        pendingUpdateVersion = item.displayVersionString
        hasPendingIdleUpdateInstall = true
        self.immediateInstallHandler = immediateInstallHandler

        guard autoInstallEnabled else {
            return false
        }

        startIdleCheckTimer()
        evaluatePendingInstallNow()
        return true
    }

    public func evaluatePendingInstallNow() {
        guard hasPendingIdleUpdateInstall,
              let installHandler = immediateInstallHandler,
              let conditionsProvider else {
            return
        }

        let requiredIdle = IdleUpdateInstallPolicy.requiredIdleSeconds(defaults: defaults)
        let conditions = conditionsProvider()
        let decision = IdleUpdateInstallPolicy.evaluate(conditions, requiredIdleSeconds: requiredIdle)
        let decisionDescription = decision.logDescription

        if lastLoggedIdleUpdateInstallDecision != decisionDescription {
            lastLoggedIdleUpdateInstallDecision = decisionDescription
            print("🔄 [IdleUpdateInstall] decision=\(decisionDescription)")
        }

        if case .install = decision {
            immediateInstallHandler = nil
            hasPendingIdleUpdateInstall = false
            idleCheckTimer?.invalidate()
            idleCheckTimer = nil
            installHandler()
        }
    }

    public func triggerImmediateInstallIfReady() {
        guard let installHandler = immediateInstallHandler else { return }
        immediateInstallHandler = nil
        hasPendingIdleUpdateInstall = false
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
        installHandler()
    }

    public func stopIdlePolling() {
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
    }

    private func startIdleCheckTimer() {
        idleCheckTimer?.invalidate()
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluatePendingInstallNow()
            }
        }
    }
}
