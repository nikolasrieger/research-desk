import XCTest
@testable import ResearchDesk

final class CodexAgentTests: XCTestCase {
    func testFinalAnswerExcludesCommentaryAndToolSteps() {
        var state = CodexSessionState()
        state.observeItem(["type": "agentMessage", "phase": "commentary", "text": "Checking files"])
        state.observeItem(["type": "commandExecution", "command": "ls"])
        XCTAssertTrue(state.answer.isEmpty)
        state.observeItem(["type": "agentMessage", "phase": "final_answer", "text": "# Finished"])
        XCTAssertEqual(state.answer, "# Finished")
        state.beginTurn()
        XCTAssertTrue(state.answer.isEmpty)
        state.observeItem(["type": "agentMessage", "text": "Old client commentary"])
        state.observeItem(["type": "fileChange"])
        XCTAssertTrue(state.answer.isEmpty)
        state.observeItem(["type": "agentMessage", "text": "Legacy final"])
        XCTAssertEqual(state.answer, "Legacy final")
    }

    @MainActor
    func testPersistentCodexTransportApprovalsModelsAndTwoTurns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        let thread = UUID().uuidString.lowercased()
        let source = #"""
#!/usr/bin/env python3
import sys,json,os
turn=0

def emit(o): print(json.dumps(o),flush=True)
def finish():
    emit({'method':'item/completed','params':{'threadId':THREAD,'item':{'id':'answer','type':'agentMessage','phase':'final_answer','text':'Finished '+str(turn)+' pid '+str(os.getpid())}}})
    emit({'method':'turn/completed','params':{'threadId':THREAD,'turn':{'id':str(turn),'status':'completed','items':[]}}})
for line in sys.stdin:
    e=json.loads(line); m=e.get('method'); rid=e.get('id')
    if m=='initialize': emit({'id':rid,'result':{}})
    elif m=='model/list': emit({'id':rid,'result':{'data':[{'id':'test-model','model':'test-model','displayName':'Test model'}]}})
    elif m in ('thread/start','thread/resume'): emit({'id':rid,'result':{'thread':{'id':THREAD},'model':'test-model'}})
    elif m=='turn/start':
        assert ('<research-desk-job-registration>' in e['params']['input'][0]['text']) == (turn==0)
        turn+=1
        emit({'id':rid,'result':{'turn':{'id':str(turn),'status':'inProgress'}}})
        emit({'method':'item/completed','params':{'threadId':THREAD,'item':{'type':'agentMessage','phase':'commentary','text':'Not the final response'}}})
        emit({'id':99,'method':'item/commandExecution/requestApproval','params':{'threadId':THREAD,'itemId':'command','command':'echo test'}})
    elif rid==99 and 'result' in e:
        if e['result']['decision']=='accept': finish()
"""#.replacingOccurrences(of: "THREAD", with: "'" + thread + "'")
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let chat = BriefAgentModel(project: Project(name: "Codex test", path: root.path), executableOverride: executable.path, agent: "codex")
        defer { chat.stop() }
        for turn in 1...2 {
            chat.instruction = "Turn \(turn)"
            chat.send()
            for _ in 0..<300 {
                if !chat.permissions.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let approval = try XCTUnwrap(chat.permissions.first, chat.error)
            XCTAssertTrue(chat.replies.count == turn - 1)
            chat.answer(approval, allow: true)
            for _ in 0..<300 {
                if !chat.running { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(chat.running, chat.error)
            XCTAssertEqual(chat.replies.count, turn)
            XCTAssertTrue(chat.current?.markdown.hasPrefix("Finished \(turn) pid ") == true)
            XCTAssertEqual(chat.sessionID, thread)
        }
        let firstPID = chat.replies[0].markdown.components(separatedBy: " pid ").last
        let secondPID = chat.replies[1].markdown.components(separatedBy: " pid ").last
        XCTAssertEqual(firstPID, secondPID)
        XCTAssertTrue(chat.modelOptions.contains { $0.id == "test-model" })
    }

    func testCodexHistoryIncludesFinalsAndInterruptedRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions/2026/11/19")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let events: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/test"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "First"]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "Intermediate"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "phase": "final_answer", "content": [["type": "output_text", "text": "Final answer"]]]],
            ["type": "event_msg", "payload": ["type": "task_complete"]],
            ["type": "event_msg", "payload": ["type": "token_count", "info": ["last_token_usage": ["total_tokens": 160000], "model_context_window": 200000]]],
            ["type": "compacted", "payload": ["message": "Summary"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Unfinished"]]
        ]
        let data = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try data.write(to: directory.appendingPathComponent("rollout-" + id + ".jsonl"), atomically: true, encoding: .utf8)
        let command = "CODEX_HOME=" + Command.shellQuote(root.path) + " python3 -c " + Command.shellQuote(CodexHistory.script) + " " + Command.shellQuote(id)
        let result = Command.run("/bin/zsh", ["-c", command])
        XCTAssertEqual(result.2, 0, result.1)
        let records = try JSONDecoder().decode([BriefHistory.Record].self, from: Data(result.0.utf8))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].markdown, "Final answer")
        XCTAssertEqual(records[1].incomplete, true)
        XCTAssertEqual(records[1].instruction, "Unfinished")
        XCTAssertNil(records.last?.contextTokens)
        XCTAssertEqual(records.last?.contextCompacted, true)
        XCTAssertEqual(records.last?.contextWindow, 200000)
        let discovery = "CODEX_HOME=" + Command.shellQuote(root.path) + " CLAUDE_CONFIG_DIR=" + Command.shellQuote(root.appendingPathComponent("claude").path) + " python3 -c " + Command.shellQuote(BriefConversationHistory.script)
        let listing = Command.run("/bin/zsh", ["-c", discovery])
        XCTAssertEqual(listing.2, 0, listing.1)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let sessions = try decoder.decode([SavedAgentSession].self, from: Data(listing.0.utf8))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].agent, "codex")
        XCTAssertEqual(sessions[0].id, id)
    }
}
