//
//  ClickyAssemblyAIAudioBatchingTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Clicky

struct ClickyAssemblyAIAudioBatchingTests {
    @Test func shortFinalAudioIsPaddedToTheTwentyMillisecondMinimum() {
        // 5.375 ms of 16 kHz PCM16 is what AVCaptureSession buffers turned into, which AssemblyAI rejected.
        let fiveMillisecondsOfAudio = Data(repeating: 1, count: 172)
        let finalMessage = AssemblyAIAudioMessageBatching.finalAudioMessage(fromPendingBytes: fiveMillisecondsOfAudio)
        #expect(finalMessage?.count == AssemblyAIAudioMessageBatching.minimumAudioMessageByteCount)
        #expect(finalMessage?.prefix(172) == fiveMillisecondsOfAudio)
    }

    @Test func emptyPendingAudioSendsNothingAndLongAudioIsUnchanged() {
        #expect(AssemblyAIAudioMessageBatching.finalAudioMessage(fromPendingBytes: Data()) == nil)
        let longAudio = Data(repeating: 2, count: AssemblyAIAudioMessageBatching.preferredAudioMessageByteCount)
        #expect(AssemblyAIAudioMessageBatching.finalAudioMessage(fromPendingBytes: longAudio) == longAudio)
    }
}
