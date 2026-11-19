import Foundation
import Testing
@testable import Clicky

struct ClickyJobInstructionsTests {
    @Test func buildMentionsEveryFinalMessageBlock() {
        let instructions = ClickyJobInstructions.build(standingContext: "")
        for blockName in ClickyJobInstructions.finalMessageBlockNames {
            #expect(instructions.contains("<\(blockName)>"))
        }
    }

    @Test func blockNamesAreReadByTheParser() {
        let sample = ClickyJobInstructions.finalMessageBlockNames
            .map { "<\($0)><item>x</item></\($0)>" }.joined()
        let parsed = AgentCompletionXMLParser.parse(sample)
        #expect(parsed.summary != nil && parsed.answer != nil && parsed.learned != nil)
        #expect(!parsed.nextActions.isEmpty && !parsed.artifacts.isEmpty)
    }

    @Test func sampleFinalMessageRoundTrips() {
        let parsed = AgentCompletionXMLParser.parse("""
        <SUMMARY>I compared the quotes.</SUMMARY>
        <ARTIFACTS><item>output/quotes.md</item></ARTIFACTS>
        <NEXT_ACTIONS><item>Email the cheapest one</item><item>Add dates</item></NEXT_ACTIONS>
        """)
        #expect(parsed.summary == "I compared the quotes.")
        #expect(parsed.artifacts == ["output/quotes.md"])
        #expect(parsed.nextActions.count == 2)
    }

    @Test func chatShowsTheFullReplyNotTheSummaryOrAnswerJSON() {
        let parsed = AgentCompletionXMLParser.parse("""
        The cheapest quote is Northwind at $420.
        <SUMMARY>I compared the quotes.</SUMMARY>
        <ANSWER>{"outcome":"found"}</ANSWER>
        """)
        #expect(parsed.displayBody == "The cheapest quote is Northwind at $420.")

        let tagsOnly = AgentCompletionXMLParser.parse("<SUMMARY>I compared the quotes.</SUMMARY>")
        #expect(tagsOnly.displayBody == "I compared the quotes.")
    }

    @Test func standingContextIsAppendedAndEmptyAddsNothing() {
        let withContext = ClickyJobInstructions.build(standingContext: "  PREFS  ")
        #expect(withContext.hasSuffix("\n\nPREFS"))
        let without = ClickyJobInstructions.build(standingContext: "\n ")
        #expect(without == without.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!without.contains("PREFS"))
    }

    @Test func driveSayIsOptional() {
        #expect(ClickyDriveActionParser.parseSay("{\"action\":\"wait\"}") == nil)
        #expect(ClickyDriveActionParser.parseSay("{\"action\":\"wait\",\"say\":\" Hi. \"}") == "Hi.")
    }
}
