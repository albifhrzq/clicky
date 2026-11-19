//
//  ClickyDictationLanguageRoutingTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Clicky

struct ClickyDictationLanguageRoutingTests {
    @Test func explicitDictationLanguageWinsOverVoiceLanguage() {
        #expect(BuddyTranscriptionProviderFactory.effectiveDictationLanguageCode(
            dictationAutoDetect: false, dictationLanguageCode: "id", selectedVoiceLanguage: "en"
        ) == "id")
    }

    @Test func autoDetectFallsBackToVoiceLanguageThenAuto() {
        #expect(BuddyTranscriptionProviderFactory.effectiveDictationLanguageCode(
            dictationAutoDetect: true, dictationLanguageCode: "auto", selectedVoiceLanguage: "id"
        ) == "id")
        #expect(BuddyTranscriptionProviderFactory.effectiveDictationLanguageCode(
            dictationAutoDetect: true, dictationLanguageCode: "auto", selectedVoiceLanguage: "auto"
        ) == nil)
    }

    @Test func indonesianIsNotAnAssemblyAIStreamingLanguage() {
        #expect(!BuddyTranscriptionProviderFactory.isAssemblyAIStreamingLanguage("id"))
        #expect(!BuddyTranscriptionProviderFactory.isAssemblyAIStreamingLanguage("id-ID"))
        #expect(BuddyTranscriptionProviderFactory.isAssemblyAIStreamingLanguage("en"))
    }
}

struct ClickyConversationHistoryDrawingNoteTests {
    @Test func drawingTurnsKeepANoteInHistoryAndPlainTurnsDoNot() {
        let drawnTurn = CompanionManager.conversationHistoryAssistantText(spokenText: "Here it is.", responseIncludedDrawing: true)
        #expect(drawnTurn.hasPrefix("[I drew this explanation on the user's screen.]"))
        #expect(drawnTurn.hasSuffix("Here it is."))
        #expect(CompanionManager.conversationHistoryAssistantText(spokenText: "Sure.", responseIncludedDrawing: false) == "Sure.")
    }
}
