//
//  ClickyOnboardingTour.swift
//  leanring-buddy
//
//  Interactive first-run tour that replaces the old onboarding video. The tour
//  asks the user to actually try each feature (voice, pointing, text mode,
//  dictation, agents, notch) and advances when the matching signal arrives.
//  The step machine is a pure function so it can be unit tested; the controller
//  below wires it to real shortcut / voice / notch signals and shows each line
//  in the cursor prompt bubble.
//

import Combine
import Foundation

// MARK: - Step Machine (pure)

nonisolated enum ClickyOnboardingTourStep: Int, CaseIterable, Equatable {
    case talk
    case point
    case textMode
    case dictation
    case drive
    case notch
    case done

    /// Short stable name used for analytics.
    var analyticsName: String {
        switch self {
        case .talk: return "talk"
        case .point: return "point"
        case .textMode: return "text_mode"
        case .dictation: return "dictation"
        case .drive: return "drive"
        case .notch: return "notch"
        case .done: return "done"
        }
    }
}

nonisolated enum ClickyOnboardingTourEvent: Equatable {
    /// One full push-to-talk turn finished (processing -> idle, optionally via responding).
    case voiceTurnCompleted
    case textTriggerFired
    case dictationReleased
    case driveTimerElapsed
    case notchHovered
    case skipRequested
}

nonisolated enum ClickyOnboardingTourStateMachine {
    /// Returns the step the tour should be on after `event`.
    /// - Same step as `current`: the event is irrelevant, nothing changes.
    /// - `nil`: the user skipped, the tour is over.
    static func nextStep(
        current: ClickyOnboardingTourStep,
        event: ClickyOnboardingTourEvent,
        dictationEnabled: Bool
    ) -> ClickyOnboardingTourStep? {
        if event == .skipRequested {
            return current == .done ? .done : nil
        }

        switch (current, event) {
        case (.talk, .voiceTurnCompleted):
            return .point
        case (.point, .voiceTurnCompleted):
            return .textMode
        case (.textMode, .textTriggerFired):
            return dictationEnabled ? .dictation : .drive
        case (.dictation, .dictationReleased):
            return .drive
        case (.drive, .driveTimerElapsed):
            return .notch
        case (.notch, .notchHovered):
            return .done
        default:
            return current
        }
    }

    /// Steps the user will actually see (dictation is dropped when disabled, `done` is not counted).
    static func visibleSteps(dictationEnabled: Bool) -> [ClickyOnboardingTourStep] {
        ClickyOnboardingTourStep.allCases.filter { step in
            step != .done && (step != .dictation || dictationEnabled)
        }
    }

    /// 1-based position of `step` among the visible steps, or nil for `done`.
    static func stepNumber(of step: ClickyOnboardingTourStep, dictationEnabled: Bool) -> Int? {
        visibleSteps(dictationEnabled: dictationEnabled).firstIndex(of: step).map { $0 + 1 }
    }

    static func lineText(
        for step: ClickyOnboardingTourStep,
        voiceHoldKeys: String,
        textTriggerKeys: String,
        dictationHoldKeys: String
    ) -> String {
        switch step {
        case .talk:
            return "hold \(voiceHoldKeys), say hi or tell me your name, then let go."
        case .point:
            return "hold the keys, circle something on your screen, and ask about it."
        case .textMode:
            return "press \(textTriggerKeys) and you can type to me chatgpt style."
        case .dictation:
            return "hold \(dictationHoldKeys) in any text field. i type exactly what you say."
        case .drive:
            return "i can drive your computer too. ask me in text mode with agents, press esc to take it back."
        case .notch:
            return "i live in your mac's notch. hover it."
        case .done:
            return "that's it! i'm all yours. hold \(voiceHoldKeys) and i'm here."
        }
    }

    static func skipLineText(voiceHoldKeys: String) -> String {
        "skipped? very brave. god speed my friend. here if you need me, just hold \(voiceHoldKeys)"
    }
}

// MARK: - Controller

@MainActor
final class ClickyOnboardingTourController: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var currentStep: ClickyOnboardingTourStep = .talk

    private static let secondsToShowDriveStepAfterSpeaking: UInt64 = 6
    private static let secondsToKeepFarewellBubble: UInt64 = 4

    private weak var companionManager: CompanionManager?
    private var isDictationStepIncluded: Bool = true

    /// Voice turn tracking: a turn counts once we saw processing, then idle. Listening is not required
    /// (push-to-talk during a spoken tour line never publishes it) and responding is optional
    /// (POINT/drawing-only replies skip it).
    private var hasSeenProcessingInCurrentStep = false

    private var voiceStateCancellable: AnyCancellable?
    private var notchHoverCancellable: AnyCancellable?
    private var stepTask: Task<Void, Never>?
    private var farewellTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start(companionManager: CompanionManager) {
        guard !isActive else { return }
        self.companionManager = companionManager
        farewellTask?.cancel()
        farewellTask = nil

        isDictationStepIncluded = companionManager.globalPushToTalkShortcutMonitor
            .binding(for: .dictationHold).isEnabled
        isActive = true

        voiceStateCancellable = companionManager.$voiceState
            .removeDuplicates()
            .sink { [weak self] newVoiceState in
                self?.handleVoiceStateChange(newVoiceState)
            }

        enterStep(.talk)
    }

    /// Fed by CompanionManager's slot event subscription.
    /// `voiceStateWasIdleBeforeEvent` matters for Escape: if Clicky was busy (speaking, etc.)
    /// the first Escape only interrupts that, and only a second Escape skips the tour.
    func handleSlotEvent(_ event: ClickyShortcutSlotEvent, voiceStateWasIdleBeforeEvent: Bool) {
        guard isActive else { return }
        switch event {
        case .triggered(let slot) where slot == .textTrigger:
            apply(.textTriggerFired)
        case .released(let slot) where slot == .dictationHold:
            apply(.dictationReleased)
        case .escapeInterrupted:
            // The drive line itself tells the user about esc, and the step auto-advances.
            guard currentStep != .drive else { return }
            // Esc during the tour's own line should skip at once, not need a second press.
            if voiceStateWasIdleBeforeEvent || companionManager?.isSpeakingOnboardingTourLine == true {
                apply(.skipRequested)
            }
        default:
            break
        }
    }

    // MARK: Step handling

    private func apply(_ event: ClickyOnboardingTourEvent) {
        guard isActive else { return }
        guard let nextStep = ClickyOnboardingTourStateMachine.nextStep(
            current: currentStep,
            event: event,
            dictationEnabled: isDictationStepIncluded
        ) else {
            finishSkipped()
            return
        }
        guard nextStep != currentStep else { return }
        enterStep(nextStep)
    }

    private func enterStep(_ step: ClickyOnboardingTourStep) {
        guard let companionManager else { return }

        stepTask?.cancel()
        notchHoverCancellable = nil
        hasSeenProcessingInCurrentStep = false
        currentStep = step

        if step == .done {
            finishCompleted()
            return
        }

        ClickyAnalytics.trackOnboardingTourStep(step: step.analyticsName)

        let line = lineText(for: step)
        let stepNumber = ClickyOnboardingTourStateMachine.stepNumber(
            of: step, dictationEnabled: isDictationStepIncluded
        ) ?? 1
        let totalSteps = ClickyOnboardingTourStateMachine
            .visibleSteps(dictationEnabled: isDictationStepIncluded).count
        companionManager.showOnboardingTourBubble(
            text: "\(line)\nstep \(stepNumber) of \(totalSteps) · esc to skip"
        )

        if step == .notch {
            // The textMode step leaves the notch open; collapse it so a hover is a real signal.
            NotchWindowManager.shared.collapseNotch()
            var hasSeenNotUnhovered = false
            notchHoverCancellable = NotchWindowManager.shared.$isHovered
                .removeDuplicates()
                .sink { [weak self] isHovered in
                    if !isHovered {
                        hasSeenNotUnhovered = true
                    } else if hasSeenNotUnhovered {
                        self?.apply(.notchHovered)
                    }
                }
        }

        stepTask = Task { @MainActor [weak self] in
            // Don't cut off Clicky's real reply to the user's last turn.
            await companionManager.waitForSpeechPlaybackToFinish()
            guard !Task.isCancelled else { return }
            await companionManager.speakOnboardingTourLine(line)
            guard let self, !Task.isCancelled, self.currentStep == step else { return }
            if step == .drive {
                try? await Task.sleep(nanoseconds: Self.secondsToShowDriveStepAfterSpeaking * 1_000_000_000)
                guard !Task.isCancelled, self.currentStep == step else { return }
                self.apply(.driveTimerElapsed)
            }
        }
    }

    private func handleVoiceStateChange(_ newVoiceState: CompanionVoiceState) {
        guard isActive, currentStep == .talk || currentStep == .point else { return }
        switch newVoiceState {
        case .processing:
            hasSeenProcessingInCurrentStep = true
        case .idle:
            if hasSeenProcessingInCurrentStep {
                apply(.voiceTurnCompleted)
            }
        case .listening, .responding:
            break
        }
    }

    // MARK: Ending

    private func finishCompleted() {
        ClickyAnalytics.trackOnboardingTourCompleted()
        ClickySoundEffectPlayer.shared.play(.tada)
        endTour(farewellLine: lineText(for: .done))
    }

    private func finishSkipped() {
        ClickyAnalytics.trackOnboardingTourSkipped(atStep: currentStep.analyticsName)
        let keys = keyText(for: .voiceHold)
        endTour(farewellLine: ClickyOnboardingTourStateMachine.skipLineText(voiceHoldKeys: keys))
    }

    private func endTour(farewellLine: String) {
        stepTask?.cancel()
        stepTask = nil
        notchHoverCancellable = nil
        voiceStateCancellable = nil
        isActive = false
        guard let companionManager else { return }

        companionManager.stopOnboardingMusic()
        companionManager.showOnboardingTourBubble(text: farewellLine)

        farewellTask?.cancel()
        farewellTask = Task { @MainActor [weak self] in
            await companionManager.speakOnboardingTourLine(farewellLine)
            try? await Task.sleep(nanoseconds: Self.secondsToKeepFarewellBubble * 1_000_000_000)
            guard !Task.isCancelled, self?.isActive == false else { return }
            await companionManager.hideOnboardingTourBubble()
            companionManager.onboardingTourDidFinish()
        }
    }

    // MARK: Copy helpers

    private func lineText(for step: ClickyOnboardingTourStep) -> String {
        ClickyOnboardingTourStateMachine.lineText(
            for: step,
            voiceHoldKeys: keyText(for: .voiceHold),
            textTriggerKeys: keyText(for: .textTrigger),
            dictationHoldKeys: keyText(for: .dictationHold)
        )
    }

    private func keyText(for slot: ClickyShortcutSlot) -> String {
        let displayText = companionManager?.globalPushToTalkShortcutMonitor
            .binding(for: slot).displayText ?? ""
        if displayText.isEmpty {
            return slot == .voiceHold ? "control + option" : "your shortcut"
        }
        return displayText
    }
}
