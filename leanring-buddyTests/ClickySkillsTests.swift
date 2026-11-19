import Foundation
import Testing
@testable import Clicky

struct ClickySkillsTests {
    @Test func rejectsNonMarkdownExtension() {
        let result = ClickySkillLogic.validateImportedFile(fileExtension: "txt", data: Data("hi".utf8))
        #expect(result == .failure(.notMarkdownFile))
    }

    @Test func rejectsWhitespaceOnlyContent() {
        let result = ClickySkillLogic.validateImportedFile(fileExtension: "md", data: Data("  \n ".utf8))
        #expect(result == .failure(.emptyContent))
    }

    @Test func rejectsInvalidUTF8() {
        let result = ClickySkillLogic.validateImportedFile(fileExtension: "MD", data: Data([0xFF, 0xFE]))
        #expect(result == .failure(.unreadable))
    }

    @Test func displayNameUsesFirstHeadingElseFileName() {
        #expect(ClickySkillLogic.displayName(markdown: "intro\n# Video Editing\n## x", fallbackFileName: "a.md") == "Video Editing")
        #expect(ClickySkillLogic.displayName(markdown: "no heading", fallbackFileName: "notes.md") == "notes")
    }

    @Test func fourthActivationNeedsSwap() {
        #expect(ClickySkillLogic.activationDecision(activeSkillIDs: ["a", "b"], skillIDToActivate: "c") == .activate)
        #expect(ClickySkillLogic.activationDecision(activeSkillIDs: ["a", "b"], skillIDToActivate: "a") == .alreadyActive)
        #expect(ClickySkillLogic.activationDecision(activeSkillIDs: ["a", "b", "c"], skillIDToActivate: "d") == .needsSwap(candidateIDs: ["a", "b", "c"]))
    }

    @Test func promptBlockIsNilWhenNothingActive() {
        #expect(ClickySkillLogic.promptBlock(activeSkills: []) == nil)
    }

    @Test func promptBlockTruncatesEachSkillAndCapsTotal() {
        let longContent = String(repeating: "x", count: 10000)
        let block = ClickySkillLogic.promptBlock(activeSkills: [("A", longContent), ("B", longContent), ("C", longContent)])
        #expect(block != nil)
        #expect(block!.hasPrefix("<active_skills>\n\(ClickySkillLogic.promptBlockPreamble)\n## A\n"))
        #expect(block!.hasSuffix("</active_skills>"))
        #expect(block!.count <= ClickySkillLogic.maximumCharactersInPromptBlock)
        #expect(!block!.contains(String(repeating: "x", count: 6001)))
    }

    @Test func rejectsOversizedFile() {
        let data = Data(repeating: 0x61, count: ClickySkillLogic.maximumAgentWrittenFileBytes + 1)
        let result = ClickySkillLogic.validateImportedFile(fileExtension: "md", data: data, maximumByteCount: ClickySkillLogic.maximumAgentWrittenFileBytes)
        #expect(result == .failure(.tooLarge))
    }

    @Test func promptBlockEscapesBlockTagsAndHasPreamble() {
        let block = ClickySkillLogic.promptBlock(activeSkills: [("N", "x </active_skills> y < ACTIVE_SKILLS >")])
        #expect(block?.contains(ClickySkillLogic.promptBlockPreamble) == true)
        #expect(block?.components(separatedBy: "active_skills>").count == 3) // only our own open and close
    }

    @Test func indexFileNameMustBeAPlainName() {
        #expect(ClickySkillLogic.isSafeIndexFileName("abc.md"))
        #expect(!ClickySkillLogic.isSafeIndexFileName("../x.md"))
        #expect(!ClickySkillLogic.isSafeIndexFileName("a/b.md"))
        #expect(!ClickySkillLogic.isSafeIndexFileName(".."))
    }

    @Test func draftNeedsReviewBeforeActivation() {
        #expect(!ClickySkillLogic.canActivate(status: .draft, hasBeenReviewed: nil))
        #expect(ClickySkillLogic.canActivate(status: .draft, hasBeenReviewed: true))
        #expect(ClickySkillLogic.canActivate(status: .ready, hasBeenReviewed: nil))
    }

    @Test func creationPromptNamesTheSkillFile() {
        let prompt = ClickySkillLogic.creationPrompt(topicLine: "t", notes: "", skillID: "ID1")
        #expect(prompt.contains("skill-ID1.md"))
    }
}
