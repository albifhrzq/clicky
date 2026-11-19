import Foundation
import Testing
@testable import Clicky

struct ClickyNotchChatTests {
    @Test func shortPressIsNotAHoldButQuarterSecondIs() {
        #expect(!ClickyNotchHoldToTalk.isHold(pressDurationSeconds: 0.3))
        #expect(ClickyNotchHoldToTalk.isHold(pressDurationSeconds: 0.45))
    }

    @Test func shortcutLabelFallsBackWhenEmpty() {
        #expect(ClickyNotchHoldToTalk.shortcutLabel("") == "Control+Option")
        #expect(ClickyNotchHoldToTalk.shortcutLabel("Fn") == "Fn")
    }

    @Test func streamingScrollIsThrottledToAboutTenPerSecond() {
        #expect(!ClickyChatStreamingScroll.shouldScroll(secondsSinceLastScroll: 0.05))
        #expect(ClickyChatStreamingScroll.shouldScroll(secondsSinceLastScroll: 0.1))
    }

    @Test func activityEventsFollowWhatHappenedInTheTurn() {
        let events = ClickyChatActivityLedger.eventsForTurn(
            tookScreenshot: true,
            attachedRegionImageCount: 2,
            readDocumentText: false
        )
        #expect(events == [ClickyChatActivityLedger.lookedAtScreen, ClickyChatActivityLedger.lookedAtImage])
    }

    @Test func mergingActivityDoesNotDuplicate() {
        let merged = ClickyChatActivityLedger.merged(["Looked at your screen"], with: ["Looked at your screen", "Read a file"])
        #expect(merged == ["Looked at your screen", "Read a file"])
    }

    @Test func drawingOnlyVoiceReplyGetsPlaceholderText() {
        #expect(ClickyChatActivityLedger.displayReply(spokenText: "  ", hasDrawing: true) == "Drawn on your screen.")
        #expect(ClickyChatActivityLedger.displayReply(spokenText: "", hasDrawing: false).isEmpty)
    }

    @Test func typingDotsOnlyForEmptyAssistantRows() {
        #expect(ClickyChatActivityLedger.shouldShowTypingDots(role: "assistant", text: ""))
        #expect(!ClickyChatActivityLedger.shouldShowTypingDots(role: "assistant", text: "hi"))
        #expect(!ClickyChatActivityLedger.shouldShowTypingDots(role: "user", text: ""))
    }

    @Test func chatMessageDecodesWithoutActivityKey() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"user","text":"hi","timestamp":0,"artifactPaths":[]}"#
        let message = try JSONDecoder().decode(ClickyChatMessage.self, from: Data(json.utf8))
        #expect(message.activity.isEmpty)
    }
}

struct ClickyComposerHelpersTests {
    @Test func spellsOutModifierSymbols() {
        #expect(ClickyComposerShortcutLabel.spelledOut("⌃⌥") == "control + option")
        #expect(ClickyComposerShortcutLabel.spelledOut("⌘⇧K") == "command + shift + K")
    }

    @Test func fallsBackToDefaultBindingWhenEmptyOrBlank() {
        #expect(ClickyComposerShortcutLabel.spelledOut("") == "control + option")
        #expect(ClickyComposerShortcutLabel.spelledOut("  \n") == "control + option")
    }

    @Test func normalizesRealWordFormatsFromShortcutBinding() {
        #expect(ClickyComposerShortcutLabel.spelledOut("ctrl + option") == "control + option")
        #expect(ClickyComposerShortcutLabel.spelledOut("cmd + shift + space") == "command + shift + space")
        #expect(ClickyComposerShortcutLabel.spelledOut("shift + fn") == "shift + fn")
        #expect(ClickyComposerShortcutLabel.spelledOut("Control+Option") == "control + option")
    }

    @Test func hidesBothTrailingButtonsWhenIdle() {
        let visibility = ClickyComposerTrailingButtons.visibility(isFocused: false, isDraftEmpty: true, isShowingStop: false)
        #expect(visibility == .init(showsSendOrStopButton: false, showsReadAloudButton: false))
    }

    @Test func showsOnlyReadAloudWhenFocusedWithEmptyDraft() {
        let visibility = ClickyComposerTrailingButtons.visibility(isFocused: true, isDraftEmpty: true, isShowingStop: false)
        #expect(visibility == .init(showsSendOrStopButton: false, showsReadAloudButton: true))
    }

    @Test func showsBothWhenTyping() {
        let visibility = ClickyComposerTrailingButtons.visibility(isFocused: false, isDraftEmpty: false, isShowingStop: false)
        #expect(visibility == .init(showsSendOrStopButton: true, showsReadAloudButton: true))
    }

    @Test func showsOnlyStopWhileStreamingWithEmptyUnfocusedDraft() {
        let visibility = ClickyComposerTrailingButtons.visibility(isFocused: false, isDraftEmpty: true, isShowingStop: true)
        #expect(visibility == .init(showsSendOrStopButton: true, showsReadAloudButton: false))
    }
}
