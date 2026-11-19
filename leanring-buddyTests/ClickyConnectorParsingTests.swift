import Foundation
import Testing
@testable import Clicky

struct ClickyConnectorParsingTests {
    @Test func tokenizerHandlesQuotesAndEscapes() {
        #expect(ClickyConnectorParsing.tokenizeArguments("-y some-server --flag \"a b\" 'c d' e\\ f") == ["-y", "some-server", "--flag", "a b", "c d", "e f"])
        #expect(ClickyConnectorParsing.tokenizeArguments("") == [])
        #expect(ClickyConnectorParsing.tokenizeArguments("\"\"") == [""])
    }

    @Test func tokenizerRejectsUnclosedQuote() {
        #expect(ClickyConnectorParsing.tokenizeArguments("--x \"oops") == nil)
    }

    @Test func environmentParserReadsPairsAndSkipsComments() {
        let result = ClickyConnectorParsing.parseEnvironment("# note\nAPI_TOKEN=abc=def\n\n_X1 = y")
        #expect(result.issue == nil)
        #expect(result.pairs == [ClickyKeyValuePair(key: "API_TOKEN", value: "abc=def"), ClickyKeyValuePair(key: "_X1", value: "y")])
    }

    @Test func environmentParserRejectsBadNames() {
        #expect(ClickyConnectorParsing.parseEnvironment("1BAD=x").issue == .invalidEnvironmentName("1BAD"))
        #expect(ClickyConnectorParsing.parseEnvironment("noequals").issue == .invalidEnvironmentName("noequals"))
    }

    @Test func headerParserReadsPairsAndRejectsBadNames() {
        let ok = ClickyConnectorParsing.parseHeaders("X-Api-Key: secret:with:colons")
        #expect(ok.pairs == [ClickyKeyValuePair(key: "X-Api-Key", value: "secret:with:colons")])
        #expect(ClickyConnectorParsing.parseHeaders("Bad Name: x").issue == .invalidHeaderName("Bad Name"))
        #expect(ClickyConnectorParsing.parseHeaders("nocolon").issue == .invalidHeaderName("nocolon"))
    }

    @Test func urlValidation() {
        #expect(ClickyConnectorParsing.validateRemoteURL("https://mcp.example.com/mcp").issue == nil)
        #expect(ClickyConnectorParsing.validateRemoteURL("http://localhost:8080").warning == .plainHTTP)
        #expect(ClickyConnectorParsing.validateRemoteURL("ftp://x.com").issue == .invalidURL)
        #expect(ClickyConnectorParsing.validateRemoteURL("mcp.example.com").issue == .invalidURL)
        #expect(ClickyConnectorParsing.validateRemoteURL("https://user:pw@x.com").issue == .credentialsInURL)
        #expect(ClickyConnectorParsing.validateRemoteURL("https://x.com/mcp?api_key=1").issue == .credentialsInURL)
    }

    @Test func nameValidation() {
        let existing = [ClickyCustomConnector(name: "Meta Ads", transport: .remote, url: "https://a.com")]
        #expect(ClickyConnectorParsing.validateName("  ", editingID: nil, existing: existing) == .missingName)
        #expect(ClickyConnectorParsing.validateName("clicky_tools", editingID: nil, existing: existing) == .reservedName)
        #expect(ClickyConnectorParsing.validateName("Clicky", editingID: nil, existing: existing) == .reservedName)
        #expect(ClickyConnectorParsing.validateName("meta  ads", editingID: nil, existing: existing) == .duplicateName)
        #expect(ClickyConnectorParsing.validateName("Meta Ads", editingID: existing[0].id, existing: existing) == nil)
    }

    @Test func environmentClashAcrossConnectors() {
        let other = ClickyCustomConnector(name: "Other", transport: .command, command: "/bin/echo")
        let clash = ClickyConnectorParsing.environmentClash(
            newKeys: ["A", "B"], editingID: nil, existingKeysByConnector: [(other, ["B"])]
        )
        #expect(clash == .environmentNameInUse(connectorName: "Other", key: "B"))
        #expect(ClickyConnectorParsing.environmentClash(newKeys: ["B"], editingID: other.id, existingKeysByConnector: [(other, ["B"])]) == nil)
    }

    @Test func notNowGateBlocksForThirtyMinutes() {
        let chosenAt = Date(timeIntervalSince1970: 1_000)
        #expect(!ClickyNotNowGate.isBlocked(blockedAt: nil))
        #expect(ClickyNotNowGate.isBlocked(blockedAt: chosenAt, now: chosenAt.addingTimeInterval(29 * 60)))
        #expect(!ClickyNotNowGate.isBlocked(blockedAt: chosenAt, now: chosenAt.addingTimeInterval(30 * 60)))
    }

    @Test func notNowDeclineMessageTellsAgentNotToAskAgain() {
        #expect(ClickyNotNowGate.agentDeclineMessage.contains("don't ask again"))
    }

    @Test func connectorNameWithReservedKeyIsRejected() {
        #expect(ClickyConnectorParsing.validateName("@clicky", editingID: nil, existing: []) == .reservedName)
    }

    @Test func extensionSwapPromptOnlyForOldCopyWhenIdle() {
        #expect(ClickyChromeSetupFlow.shouldPromptExtensionSwap(hasOldCopy: true, isAnyJobRunning: false))
        #expect(!ClickyChromeSetupFlow.shouldPromptExtensionSwap(hasOldCopy: true, isAnyJobRunning: true))
        // A Web Store extension (e.g. version 0.6.6) with no old copy never triggers the swap prompt.
        #expect(!ClickyChromeSetupFlow.shouldPromptExtensionSwap(hasOldCopy: false, isAnyJobRunning: false))
    }
}
