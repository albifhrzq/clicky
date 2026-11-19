import Testing
@testable import Clicky

struct ClickyHandoffTests {
    @Test func parsesAgentTagWithSlug() {
        let result = ClickyHandoffTagParser.parse(from: "On it. [AGENT:research:Find flights]")
        #expect(result.text == "On it.")
        #expect(result.request?.kind == .agent)
        #expect(result.request?.clickySlug == "research")
        #expect(result.request?.task == "Find flights")
    }

    @Test func parsesDriveTagCaseInsensitive() {
        let result = ClickyHandoffTagParser.parse(from: "Sure [drive:Click Save]")
        #expect(result.request?.kind == .drive)
        #expect(result.request?.task == "Click Save")
    }

    @Test func noneSlugBecomesNil() {
        let result = ClickyHandoffTagParser.parse(from: "[AGENT:none:Do it]")
        #expect(result.request?.clickySlug == nil)
    }

    @Test func firstTagWinsAndAllStripped() {
        let result = ClickyHandoffTagParser.parse(from: "A [AGENT:none:one] B [DRIVE:two]")
        #expect(result.request?.task == "one")
        #expect(!result.text.contains("["))
    }

    @Test func noTagLeavesTextAlone() {
        let result = ClickyHandoffTagParser.parse(from: "hello [world]")
        #expect(result.text == "hello [world]")
        #expect(result.request == nil)
    }

    @Test func emptyTaskIsStrippedWithoutRequest() {
        let result = ClickyHandoffTagParser.parse(from: "ok [DRIVE:  ]")
        #expect(result.request == nil)
        #expect(result.text == "ok")
    }

    @Test func partialStreamingTagIsHidden() {
        #expect(ClickyHandoffTagParser.hidingPartialTag(in: "Starting [AG") == "Starting")
        #expect(ClickyHandoffTagParser.hidingPartialTag(in: "Go [DRIVE:cli") == "Go")
        #expect(ClickyHandoffTagParser.hidingPartialTag(in: "see [1] and [x") == "see [1] and [x")
    }

    @Test func overlongTaskIsCapped() {
        let longTask = String(repeating: "a", count: 900)
        let result = ClickyHandoffTagParser.parse(from: "[DRIVE:\(longTask)]")
        #expect(result.request?.task.count == 500)
    }

    @Test func askBeforeStartingJobsAlwaysShowsTheCard() {
        #expect(!ClickyHandoffPolicy.shouldStartWithoutAsking(source: .realtimeTool, askBeforeStartingJobs: true))
        #expect(!ClickyHandoffPolicy.shouldStartWithoutAsking(source: .replyTag(userText: "research laptops in the background"), askBeforeStartingJobs: true))
    }

    @Test func autoStartNeedsTheUsersOwnRequest() {
        #expect(ClickyHandoffPolicy.shouldStartWithoutAsking(source: .replyTag(userText: "tolong riset 3 laptop terbaik"), askBeforeStartingJobs: false))
        #expect(!ClickyHandoffPolicy.shouldStartWithoutAsking(source: .replyTag(userText: "what's on my screen?"), askBeforeStartingJobs: false))
        #expect(!ClickyHandoffPolicy.shouldStartWithoutAsking(source: .drawingButton, askBeforeStartingJobs: false))
        #expect(ClickyHandoffPolicy.shouldStartWithoutAsking(source: .realtimeTool, askBeforeStartingJobs: false))
    }

    @Test func partialTagHidingIgnoresInnerBrackets() {
        #expect(ClickyHandoffTagParser.hidingPartialTag(in: "On it. [AGENT:none:fix the [foo") == "On it.")
        #expect(ClickyHandoffTagParser.hidingPartialTag(in: "See [1] and [2]") == "See [1] and [2]")
        #expect(ClickyHandoffTagParser.hidingPartialTag(in: "Sure [DRI") == "Sure")
    }
}
