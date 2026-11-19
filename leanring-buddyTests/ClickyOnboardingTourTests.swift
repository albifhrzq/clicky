//
//  ClickyOnboardingTourTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Clicky

struct ClickyOnboardingTourTests {
    private typealias Machine = ClickyOnboardingTourStateMachine

    @Test func voiceTurnsAdvanceTalkThenPointThenTextMode() {
        #expect(Machine.nextStep(current: .talk, event: .voiceTurnCompleted, dictationEnabled: true) == .point)
        #expect(Machine.nextStep(current: .point, event: .voiceTurnCompleted, dictationEnabled: true) == .textMode)
    }

    @Test func textTriggerGoesToDictationWhenEnabled() {
        #expect(Machine.nextStep(current: .textMode, event: .textTriggerFired, dictationEnabled: true) == .dictation)
    }

    @Test func textTriggerSkipsDictationWhenDisabled() {
        #expect(Machine.nextStep(current: .textMode, event: .textTriggerFired, dictationEnabled: false) == .drive)
    }

    @Test func remainingStepsAdvanceOnTheirOwnEvents() {
        #expect(Machine.nextStep(current: .dictation, event: .dictationReleased, dictationEnabled: true) == .drive)
        #expect(Machine.nextStep(current: .drive, event: .driveTimerElapsed, dictationEnabled: true) == .notch)
        #expect(Machine.nextStep(current: .notch, event: .notchHovered, dictationEnabled: true) == .done)
    }

    @Test func unrelatedEventsDoNotChangeTheStep() {
        #expect(Machine.nextStep(current: .talk, event: .textTriggerFired, dictationEnabled: true) == .talk)
        #expect(Machine.nextStep(current: .notch, event: .voiceTurnCompleted, dictationEnabled: true) == .notch)
        #expect(Machine.nextStep(current: .drive, event: .notchHovered, dictationEnabled: true) == .drive)
    }

    @Test func skipEndsTheTourFromAnyActiveStep() {
        for step in ClickyOnboardingTourStep.allCases where step != .done {
            #expect(Machine.nextStep(current: step, event: .skipRequested, dictationEnabled: true) == nil)
        }
    }

    @Test func stepCountDropsDictationWhenDisabled() {
        #expect(Machine.visibleSteps(dictationEnabled: true).count == 6)
        #expect(Machine.visibleSteps(dictationEnabled: false).count == 5)
        #expect(Machine.stepNumber(of: .drive, dictationEnabled: false) == 4)
        #expect(Machine.stepNumber(of: .done, dictationEnabled: true) == nil)
    }
}
