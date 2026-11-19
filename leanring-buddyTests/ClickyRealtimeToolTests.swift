import Testing
@testable import Clicky

struct ClickyRealtimeToolTests {
    @Test func openAIDeclarationsListBothToolsWithSchemas() {
        let declarations = RealtimeToolSupport.openAIToolDeclarations()
        #expect(declarations.compactMap { $0["name"] as? String } == ["use_screen", "start_background_job"])
        #expect(declarations.allSatisfy { $0["type"] as? String == "function" })
    }

    @Test func geminiDeclarationsWrapFunctionDeclarations() {
        let declarations = RealtimeToolSupport.geminiToolDeclarations()
        let functions = declarations.first?["functionDeclarations"] as? [[String: Any]]
        #expect(functions?.count == 2)
    }

    @Test func parsesOpenAIToolCall() {
        let call = RealtimeToolSupport.parseOpenAIToolCall(from: [
            "type": "response.function_call_arguments.done",
            "call_id": "call_1", "name": "use_screen",
            "arguments": "{\"request\":\"what is this\"}"
        ])
        #expect(call == RealtimeToolCall(callID: "call_1", name: "use_screen", arguments: ["request": "what is this"]))
        #expect(RealtimeToolSupport.parseOpenAIToolCall(from: ["type": "response.done"]) == nil)
    }

    @Test func parsesGeminiToolCalls() {
        let calls = RealtimeToolSupport.parseGeminiToolCalls(from: [
            "toolCall": ["functionCalls": [["id": "g1", "name": "start_background_job", "args": ["task": "build"]]]]
        ])
        #expect(calls == [RealtimeToolCall(callID: "g1", name: "start_background_job", arguments: ["task": "build"])])
    }

    @Test func buildsToolResultMessages() {
        let openAI = RealtimeToolSupport.openAIToolResultMessages(callID: "c", output: "ok")
        #expect(openAI.count == 2)
        #expect(openAI[1]["type"] as? String == "response.create")
        let item = openAI[0]["item"] as? [String: Any]
        #expect(item?["type"] as? String == "function_call_output")
        let gemini = RealtimeToolSupport.geminiToolResultMessage(callID: "g", name: "use_screen", output: "ok")
        let responses = (gemini["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]]
        #expect(responses?.first?["id"] as? String == "g")
    }
}

struct ClickyRealtimeToolGateTests {
    @Test func rejectsSecondCallWhileOneIsInFlight() {
        var gate = RealtimeToolCallGate()
        #expect(gate.admit(toolName: "use_screen") == nil)
        #expect(gate.admit(toolName: "start_background_job") == RealtimeToolCallGate.busyMessage)
        gate.finishToolCall()
        #expect(gate.admit(toolName: "start_background_job") == nil)
    }

    @Test func allowsOnlyOneUseScreenPerUtteranceUntilReset() {
        var gate = RealtimeToolCallGate()
        #expect(gate.admit(toolName: "use_screen") == nil)
        gate.finishToolCall()
        #expect(gate.admit(toolName: "use_screen") == RealtimeToolCallGate.busyMessage)
        gate.resetForNewUtterance()
        #expect(gate.admit(toolName: "use_screen") == nil)
    }
}
