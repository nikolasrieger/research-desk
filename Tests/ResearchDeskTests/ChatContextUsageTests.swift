import XCTest
@testable import ResearchDesk

final class ChatContextUsageTests: XCTestCase {
    func testContextIncludesCachedTokensAndDoesNotAccumulateRepeatedEvents() {
        var usage = ChatContextUsage()
        let event: [String: Any] = ["type": "assistant", "message": ["usage": ["input_tokens": 1000, "cache_read_input_tokens": 140000, "cache_creation_input_tokens": 10000, "output_tokens": 500]]]
        usage.observe(event); usage.observe(event)
        XCTAssertEqual(usage.tokens, 151500)
        XCTAssertTrue(usage.isLarge)
        usage.observe(["type": "assistant", "parent_tool_use_id": "subagent", "message": ["usage": ["input_tokens": 10]]])
        XCTAssertEqual(usage.tokens, 151500)
        usage.observe(["type": "result", "modelUsage": ["opus": ["contextWindow": 1000000]]])
        XCTAssertFalse(usage.isLarge)
        usage.observe(["type": "system", "subtype": "compact_boundary"])
        XCTAssertNil(usage.tokens)
        usage.observe(["type": "assistant", "message": ["usage": ["input_tokens": 2000]]])
        XCTAssertEqual(usage.tokens, 2000)
    }
    @MainActor
    func testHandoffCreatesIndependentChatAndPreservesDraft() {
        let project = Project(name: "Test", path: "/tmp/test")
        let old = BriefAgentStore.shared.create(for: project)
        old.instruction = "Keep the validation unchanged."
        let fresh = BriefAgentStore.shared.create(for: project, workingProject: old.project)
        fresh.instruction = ChatContextUsage.handoff(from: old.sessionID, project: old.project, draft: old.instruction)
        XCTAssertNotEqual(fresh.sessionID, old.sessionID)
        XCTAssertTrue(fresh.instruction.contains(old.sessionID))
        XCTAssertTrue(fresh.instruction.contains(old.sessionID + ".jsonl"))
        XCTAssertTrue(fresh.instruction.hasSuffix(old.instruction))
        XCTAssertFalse(fresh.running)
        XCTAssertTrue(fresh.replies.isEmpty)
        XCTAssertNil(fresh.contextUsage.tokens)
    }
    func testSavedTranscriptRestoresLatestContextTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("projects/test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let events: [[String: Any]] = [
            ["type": "user", "message": ["content": "Do the work"]],
            ["type": "assistant", "message": ["id": "answer", "stop_reason": "end_turn", "content": [["type": "text", "text": "Done"]], "usage": ["input_tokens": 1000, "cache_read_input_tokens": 160000, "output_tokens": 100]]],
            ["type": "result", "result": "Done", "modelUsage": ["sonnet": ["contextWindow": 200000]]]
        ]
        let data = try events.map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
        try data.write(to: folder.appendingPathComponent(id + ".jsonl"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", BriefHistory.script, id]
        process.environment = ProcessInfo.processInfo.environment.merging(["CLAUDE_CONFIG_DIR": root.path]) { _, new in new }
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let records = try JSONDecoder().decode([BriefHistory.Record].self, from: output)
        XCTAssertEqual(records.last?.contextTokens, 161100)
        XCTAssertEqual(records.last?.contextWindow, 200000)
    }
}
