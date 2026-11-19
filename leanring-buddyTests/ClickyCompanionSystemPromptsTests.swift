//
//  ClickyCompanionSystemPromptsTests.swift
//  Tests that the voice prompt does not forbid the drawing code block.
//

import Foundation
import Testing
@testable import Clicky

struct ClickyCompanionSystemPromptsTests {
    @Test func voicePromptAllowsDrawingCodeBlock() {
        let voicePrompt = ClickyCompanionSystemPrompts.voiceSystemPrompt()
        #expect(voicePrompt.contains("drawing code block"))
    }

    @Test func voicePromptNoLongerForbidsAllCodeAloud() {
        let voicePrompt = ClickyCompanionSystemPrompts.voiceSystemPrompt()
        #expect(!voicePrompt.contains("Do not read code aloud. Describe what it does or what has to change."))
    }
}
