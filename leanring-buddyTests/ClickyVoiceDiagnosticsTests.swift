//
//  ClickyVoiceDiagnosticsTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct ClickyVoiceDiagnosticsTests {
    private func process(_ pid: Int32, _ bundle: String?, running: Bool = true) -> ClickyAudioInputProcess {
        ClickyAudioInputProcess(processID: pid, bundleIdentifier: bundle, isRunningInput: running)
    }

    @Test func callIsActiveWhenAnotherAppUsesTheMic() {
        let processes = [process(200, "us.zoom.xos")]
        #expect(ClickyCallPresenceDecision.isCallActive(processes: processes, ownProcessID: 100))
    }

    @Test func ownProcessAndIdleFaceTimeDoNotCount() {
        let processes = [process(100, "com.clicky"), process(300, "com.apple.FaceTime", running: false)]
        #expect(!ClickyCallPresenceDecision.isCallActive(processes: processes, ownProcessID: 100))
    }

    @Test func recordingAppsDoNotCount() {
        let processes = [process(400, "com.apple.garageband10"), process(401, "com.obsproject.obs-studio")]
        #expect(!ClickyCallPresenceDecision.isCallActive(processes: processes, ownProcessID: 100))
    }

    @Test func noiseFilterDropsShortAndFillerTranscripts() {
        #expect(ClickyTranscriptNoiseFilter.isNoise(""))
        #expect(ClickyTranscriptNoiseFilter.isNoise("..."))
        #expect(ClickyTranscriptNoiseFilter.isNoise("   "))
        #expect(ClickyTranscriptNoiseFilter.isNoise("Um, uh..."))
        #expect(!ClickyTranscriptNoiseFilter.isNoise("open safari"))
        for shortAnswer in ["ok", "no", "hi", "go", "up", "5"] {
            #expect(!ClickyTranscriptNoiseFilter.isNoise(shortAnswer))
        }
    }

    @Test func safetyFilterDetectsEachProviderSignal() {
        #expect(ClickySafetyFilterDetector.isAnthropicRefusal(["type": "message_delta", "delta": ["stop_reason": "refusal"]]))
        #expect(!ClickySafetyFilterDetector.isAnthropicRefusal(["delta": ["stop_reason": "end_turn"]]))
        #expect(ClickySafetyFilterDetector.isOpenAIContentFilter(["choices": [["finish_reason": "content_filter"]]]))
        #expect(!ClickySafetyFilterDetector.isOpenAIContentFilter(["choices": [["finish_reason": "stop"]]]))
        #expect(ClickySafetyFilterDetector.isGeminiSafetyBlock(["candidates": [["finishReason": "SAFETY"]]]))
        #expect(ClickySafetyFilterDetector.isGeminiSafetyBlock(["promptFeedback": ["blockReason": "SAFETY"]]))
        #expect(!ClickySafetyFilterDetector.isGeminiSafetyBlock(["candidates": [["finishReason": "STOP"]]]))
    }

    @Test func errorMapperUsesOfficialCopyForNetworkAndSafetyErrors() {
        let timeout = ClickyVoiceErrorMapper.message(for: URLError(.timedOut), fallback: "x")
        #expect(timeout == ClickyVoiceMessages.speechFinalTranscriptTimedOut)
        let safety = ClickyVoiceErrorMapper.message(for: ClickySafetyFilterError(), fallback: "x")
        #expect(safety == ClickyVoiceMessages.providerSafetyFilterBlocked)
        #expect(ClickyVoiceErrorMapper.message(for: URLError(.unknown), fallback: "fallback") != "")
    }

    @Test func voiceProcessingSkipsBluetoothAndHeadphones() {
        #expect(ClickyAudioRoutePolicy.shouldUseVoiceProcessing(outputIsBluetooth: false, outputIsHeadphones: false))
        #expect(!ClickyAudioRoutePolicy.shouldUseVoiceProcessing(outputIsBluetooth: true, outputIsHeadphones: false))
        #expect(!ClickyAudioRoutePolicy.shouldUseVoiceProcessing(outputIsBluetooth: false, outputIsHeadphones: true))
        #expect(ClickyAudioRoutePolicy.canStartAlwaysOnVoice(outputIsBluetooth: false, outputIsHeadphones: true))
    }

    @Test func deadMicrophoneNeedsSustainedSilence() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(!ClickyMicrophoneHealth.isInputDead(captureStartedAt: start, lastNonSilentInputAt: nil, now: start.addingTimeInterval(2)))
        #expect(ClickyMicrophoneHealth.isInputDead(captureStartedAt: start, lastNonSilentInputAt: nil, now: start.addingTimeInterval(12)))
        #expect(!ClickyMicrophoneHealth.isInputDead(captureStartedAt: start, lastNonSilentInputAt: nil, now: start.addingTimeInterval(10)))
        #expect(!ClickyMicrophoneHealth.isInputDead(captureStartedAt: start, lastNonSilentInputAt: start.addingTimeInterval(5), now: start.addingTimeInterval(6)))
    }

    @Test func permissionGuideListsMissingStepsInOrder() {
        let steps = ClickyPermissionGuideStep.remainingSteps(hasAccessibility: false, hasScreenRecording: false, hasScreenContent: true)
        #expect(steps == [.accessibility, .screenRecording])
    }
}
