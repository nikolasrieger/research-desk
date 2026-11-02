#if DEBUG
import XCTest
@testable import ResearchDesk

final class BriefAgentTests: XCTestCase {
    @MainActor
    func testOnlyResultBecomesResponseAndPermissionsStaySeparate() throws {
        let model = BriefAgentModel(project: Project(name: "Test", path: "/tmp"))
        func consume(_ object: [String: Any]) throws { model.consume(try JSONSerialization.data(withJSONObject: object)) }
        try consume(["type": "assistant", "message": ["content": [["type": "text", "text": "Intermediate thought"], ["type": "tool_use", "name": "Read", "input": ["file_path": "main.swift"]]]]])
        XCTAssertTrue(model.replies.isEmpty)
        XCTAssertTrue(model.progress.contains { $0.contains("Read") })
        try consume(["type": "control_request", "request_id": "approval", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "swift test"]]])
        XCTAssertEqual(model.permissions.first?.tool, "Bash")
        XCTAssertTrue(model.replies.isEmpty)
        try consume(["type": "control_cancel_request", "request_id": "approval"])
        XCTAssertTrue(model.permissions.isEmpty)
        try consume(["type": "result", "result": "# Completed\nFinal answer.", "session_id": UUID().uuidString])
        XCTAssertEqual(model.replies.count, 1)
        XCTAssertEqual(model.current?.markdown, "# Completed\nFinal answer.")
        try consume(["type": "result", "is_error": true, "errors": ["Authentication required"]])
        XCTAssertEqual(model.replies.count, 1)
        XCTAssertEqual(model.error, "Authentication required")
    }

    @MainActor
    func testEmptyResultsNeverCreateBlankOrIntermediateReplies() throws {
        let model = BriefAgentModel(project: Project(name: "Test", path: "/tmp"))
        func consume(_ object: [String: Any]) throws { model.consume(try JSONSerialization.data(withJSONObject: object)) }
        try consume(["type": "assistant", "apiBlockIndex": 0, "message": ["id": "tool-msg", "stop_reason": "tool_use", "content": [["type": "text", "text": "I will check a file."]]]])
        try consume(["type": "assistant", "apiBlockIndex": 1, "message": ["id": "tool-msg", "stop_reason": "tool_use", "content": [["type": "tool_use", "name": "Read"]]]])
        try consume(["type": "result", "result": "   ", "is_error": false])
        XCTAssertTrue(model.replies.isEmpty)
        XCTAssertTrue(model.error.contains("without a text response"))
        try consume(["type": "assistant", "apiBlockIndex": 0, "message": ["id": "final", "stop_reason": "end_turn", "content": [["type": "thinking", "thinking": "Hidden"]]]])
        try consume(["type": "assistant", "apiBlockIndex": 1, "message": ["id": "final", "stop_reason": "end_turn", "content": [["type": "text", "text": "First final paragraph."]]]])
        try consume(["type": "assistant", "apiBlockIndex": 2, "message": ["id": "final", "stop_reason": "end_turn", "content": [["type": "text", "text": "Second final paragraph."]]]])
        try consume(["type": "assistant", "parent_tool_use_id": "child", "message": ["id": "subagent", "stop_reason": "end_turn", "content": [["type": "text", "text": "Subagent text"]]]])
        try consume(["type": "result", "result": "", "is_error": false])
        XCTAssertEqual(model.replies.count, 1)
        XCTAssertEqual(model.current?.markdown, "First final paragraph.\n\nSecond final paragraph.")
    }

    @MainActor
    func testProgressDeduplicatesAndExcludesCurrentAction() throws {
        let model = BriefAgentModel(project: Project(name: "Test", path: "/tmp"))
        let event: [String: Any] = ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "read-1", "name": "Read", "input": ["file_path": "main.swift"]]]]]
        let data = try JSONSerialization.data(withJSONObject: event)
        model.consume(data); model.consume(data)
        XCTAssertEqual(model.progress.count, 1)
        XCTAssertTrue(model.pastActions.isEmpty)
        model.log("Repeated event"); model.log("Repeated event")
        XCTAssertEqual(model.progress.count, 2)
        model.error = "Failure"
        model.dismissError()
        XCTAssertTrue(model.error.isEmpty)
    }

    @MainActor
    func testContextAndWorkspaceSessionsAreIsolated() {
        let first = Project(name: "One", path: "/tmp/one")
        let second = Project(name: "Two", path: "/tmp/two")
        XCTAssertTrue(BriefAgentStore.shared.session(for: first) === BriefAgentStore.shared.session(for: first))
        XCTAssertFalse(BriefAgentStore.shared.session(for: first) === BriefAgentStore.shared.session(for: second))
        let prompt = BriefAgentModel.prompt("Keep the thresholds unchanged.", attachments: [BriefAttachment(label: "file.swift · 2 diff lines", text: "+ selected\n context")])
        XCTAssertTrue(prompt.contains("Keep the thresholds unchanged."))
        XCTAssertTrue(prompt.contains("+ selected\n context"))
        XCTAssertTrue(WorkspaceStorage.domain.hasSuffix(".debug"))
        XCTAssertTrue(WorkspaceStorage.fileURL.path.contains("ResearchDeskDebug"))
    }

    func testStructuredTransportApprovalRoundTrip() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("fake-claude")
        let source = #"""
#!/usr/bin/python3
import sys, json
assert '--permission-prompt-tool' in sys.argv
assert sys.argv[sys.argv.index('--permission-mode') + 1] == 'auto'
init = json.loads(sys.stdin.readline())
assert init['request']['subtype'] == 'initialize'
print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':init['request_id'],'response':{}}}), flush=True)
msg = json.loads(sys.stdin.readline())
assert msg['message']['content'] == 'Test instruction'
print(json.dumps({'type':'control_request','request_id':'p1','request':{'subtype':'can_use_tool','tool_name':'Edit','input':{'file_path':'file.swift'}}}), flush=True)
reply = json.loads(sys.stdin.readline())
assert reply['response']['response']['behavior'] == 'allow'
print(json.dumps({'type':'result','result':'Finished'}), flush=True)
"""#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let connection = BriefTransport()
        defer { connection.stop() }
        let stream = try connection.run(project: Project(name: "Test", path: folder.path), executable: executable.path, sessionID: UUID().uuidString, resume: false)
        connection.send(["type": "control_request", "request_id": "init", "request": ["subtype": "initialize"]])
        var result = ""
        var code: Int32?
        for await event in stream {
            switch event {
            case .line(let data):
                let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                switch object["type"] as? String {
                case "control_response": connection.send(["type": "user", "message": ["role": "user", "content": "Test instruction"]])
                case "control_request": connection.send(["type": "control_response", "response": ["subtype": "success", "request_id": "p1", "response": ["behavior": "allow", "updatedInput": ["file_path": "file.swift"]]]])
                case "result": result = object["result"] as? String ?? ""; connection.closeInput()
                default: break
                }
            case .exit(let value): code = value
            case .stderr: break
            }
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(result, "Finished")
    }

    func testSavedTranscriptOmitsToolSteps() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = folder.appendingPathComponent("projects/workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let records: [[String: Any]] = [
            ["type": "user", "message": ["content": "Investigate"]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Checking"], ["type": "tool_use", "name": "Read"]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "content": "File content"]]]],
            ["type": "assistant", "apiBlockIndex": 0, "message": ["id": "commentary", "stop_reason": "tool_use", "content": [["type": "text", "text": "Intermediate commentary"]]]],
            ["type": "assistant", "apiBlockIndex": 1, "message": ["id": "commentary", "stop_reason": "tool_use", "content": [["type": "tool_use", "name": "Read"]]]],
            ["type": "assistant", "apiBlockIndex": 0, "message": ["id": "final-1", "stop_reason": "end_turn", "content": [["type": "thinking", "thinking": "Hidden"]]]],
            ["type": "assistant", "apiBlockIndex": 1, "message": ["id": "final-1", "stop_reason": "end_turn", "content": [["type": "text", "text": "Final finding"]]]],
            ["type": "assistant", "apiBlockIndex": 1, "message": ["id": "final-1", "stop_reason": "end_turn", "content": [["type": "text", "text": "Final finding"]]]],
            ["type": "user", "isMeta": true, "message": ["content": "Internal context"]],
            ["type": "user", "queueTranscriptOnly": true, "message": ["content": "Queued placeholder"]],
            ["type": "user", "message": ["content": "Empty turn"]],
            ["type": "assistant", "message": ["id": "empty", "stop_reason": "end_turn", "content": [["type": "text", "text": " "]]]],
            ["type": "user", "message": ["content": "Unfinished follow-up"]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Still checking"], ["type": "tool_use", "name": "Bash"]]]]
        ]
        let data = try records.reduce(into: Data()) { result, item in
            result.append(try JSONSerialization.data(withJSONObject: item)); result.append(10)
        }
        try data.write(to: workspace.appendingPathComponent(id + ".jsonl"))
        let command = "CLAUDE_CONFIG_DIR=" + Command.shellQuote(folder.path) + " python3 -c " + Command.shellQuote(BriefHistory.script) + " " + Command.shellQuote(id)
        let output = Command.run("/bin/zsh", ["-c", command])
        XCTAssertEqual(output.2, 0, output.1)
        let history = try JSONDecoder().decode([BriefHistory.Record].self, from: Data(output.0.utf8))
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.last?.incomplete == true)
        XCTAssertEqual(history.last?.instruction, "Unfinished follow-up")
        XCTAssertEqual(history.first?.instruction, "Investigate")
        XCTAssertEqual(history.first?.markdown, "Final finding")
    }

    @MainActor
    func testOverviewRetainsIndependentConversations() {
        let project = Project(name: "Overview", path: "/tmp")
        let first = BriefAgentStore.shared.create(for: project)
        first.instruction = "Draft one"
        let second = BriefAgentStore.shared.create(for: project)
        second.instruction = "Draft two"
        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(BriefAgentStore.shared.chats(for: project).count, 2)
        let saved = SavedAgentSession(agent: "claude", id: first.sessionID, modified: Date())
        XCTAssertTrue(BriefAgentStore.shared.open(saved, project: project) === first)
        XCTAssertEqual(first.instruction, "Draft one")
        XCTAssertEqual(second.instruction, "Draft two")
    }

    func testCompleteHistoryUsesCustomConfigAndHasNoTopFortyLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("projects/-tmp-one")
        let second = folder.appendingPathComponent("projects/-tmp-two")
        for path in [first, second] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        for i in 0..<47 {
            let directory = i < 24 ? first : second
            let event: [String: Any] = ["type": "user", "cwd": i < 24 ? "/tmp/one" : "/tmp/two", "message": ["content": "Conversation \(i)"]]
            var data = try JSONSerialization.data(withJSONObject: event)
            data.append(10)
            try data.write(to: directory.appendingPathComponent(UUID().uuidString + ".jsonl"))
        }
        let command = "CLAUDE_CONFIG_DIR=" + Command.shellQuote(folder.path) + " python3 -c " + Command.shellQuote(BriefConversationHistory.script)
        let output = Command.run("/bin/zsh", ["-c", command])
        XCTAssertEqual(output.2, 0, output.1)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let chats = try decoder.decode([SavedAgentSession].self, from: Data(output.0.utf8))
        XCTAssertEqual(chats.count, 47)
        XCTAssertEqual(Set(chats.compactMap(\.workspace)), ["/tmp/one", "/tmp/two"])
        XCTAssertTrue(chats.allSatisfy { $0.name?.hasPrefix("Conversation ") == true })
    }

    @MainActor
    func testOtherWorkspaceChatRetainsOriginalDirectory() {
        let project = Project(name: "Current", path: "/tmp/current")
        let saved = SavedAgentSession(agent: "claude", id: UUID().uuidString, modified: Date(), workspace: "/tmp/original", name: "Earlier chat")
        let chat = BriefAgentStore.shared.open(saved, project: project)
        XCTAssertEqual(chat.project.path, "/tmp/original")
        XCTAssertEqual(chat.sessionID, saved.id)
    }

    @MainActor
    func testContinueOnlyEnabledForUnfinishedSession() throws {
        let model = BriefAgentModel(project: Project(name: "Test", path: "/tmp"))
        func consume(_ object: [String: Any]) throws { model.consume(try JSONSerialization.data(withJSONObject: object)) }
        XCTAssertFalse(model.canContinue)
        try consume(["type": "system", "subtype": "init", "session_id": UUID().uuidString])
        XCTAssertFalse(model.canContinue)
        model.interrupted = true
        XCTAssertTrue(model.canContinue)
        model.running = true
        XCTAssertFalse(model.canContinue)
        model.running = false
        try consume(["type": "result", "result": "Finished", "is_error": false])
        XCTAssertFalse(model.canContinue)
        try consume(["type": "result", "is_error": true, "errors": ["Network error"]])
        XCTAssertTrue(model.canContinue)
    }

    @MainActor
    func testLatestChatRestoresWithoutReplacingItsDraft() {
        let project = Project(name: "Restore", path: "/tmp/restore-" + UUID().uuidString)
        let first = BriefAgentStore.shared.create(for: project)
        let last = BriefAgentStore.shared.create(for: project)
        last.instruction = "Keep this draft"
        BriefAgentStore.shared.remember(first, for: project)
        BriefAgentStore.shared.remember(last, for: project)
        XCTAssertTrue(BriefAgentStore.shared.restore(for: project) === last)
        XCTAssertEqual(last.instruction, "Keep this draft")
        UserDefaults(suiteName: WorkspaceStorage.domain)?.removeObject(forKey: "agent.lastChat.:" + project.path)
    }

    @MainActor
    func testFollowUpReusesSameClaudeProcess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(Command.run("/usr/bin/git", ["-C", folder.path, "init", "-q"]).2, 0)
        let executable = folder.appendingPathComponent("fake-claude")
        let source = #"""
#!/usr/bin/python3
import sys, json, os
with open('starts.log', 'a') as f: f.write(str(os.getpid()) + '\n')
init = json.loads(sys.stdin.readline())
print(json.dumps({'type':'control_response','response':{'subtype':'success','request_id':init['request_id'],'response':{}}}), flush=True)
print(json.dumps({'type':'system','subtype':'init','session_id':sys.argv[-1]}), flush=True)
for raw in sys.stdin:
    message = json.loads(raw)
    if message.get('type') == 'user':
        print(json.dumps({'type':'result','is_error':False,'result':'Answer: ' + message['message']['content']}), flush=True)
"""#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = BriefAgentModel(project: Project(name: "Test", path: folder.path), executableOverride: executable.path)
        defer { model.stop() }
        model.instruction = "First instruction"
        model.send()
        for _ in 0..<100 {
            if model.replies.count == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.replies.count, 1, model.error)
        XCTAssertFalse(model.running)
        model.instruction = "Follow-up"
        model.send()
        for _ in 0..<100 {
            if model.replies.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.replies.count, 2, model.error)
        XCTAssertEqual(model.current?.markdown, "Answer: Follow-up")
        let starts = try String(contentsOf: folder.appendingPathComponent("starts.log"), encoding: .utf8)
        XCTAssertEqual(starts.split(separator: "\n").count, 1, "Follow-up must not launch a second process")
        model.stop()
        for _ in 0..<100 {
            if model.status.contains("Disconnected") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    func testSidebarTracksRunningAndUnreadAcrossChats() throws {
        let project = Project(name: "Indicators", path: "/tmp/indicators-" + UUID().uuidString)
        let first = BriefAgentStore.shared.create(for: project)
        let second = BriefAgentStore.shared.create(for: project)
        let store = BriefAgentStore.shared
        XCTAssertEqual(store.activity(for: project), .idle)
        first.running = true
        XCTAssertEqual(store.activity(for: project), .running)
        first.consume(try JSONSerialization.data(withJSONObject: ["type": "result", "result": "Completed"]))
        XCTAssertEqual(store.activity(for: project), .unread)
        second.running = true
        XCTAssertEqual(store.activity(for: project), .running)
        second.running = false
        XCTAssertEqual(store.activity(for: project), .unread)
        first.markLatestRead()
        XCTAssertEqual(store.activity(for: project), .idle)
        first.consume(try JSONSerialization.data(withJSONObject: ["type": "result", "result": "Another answer"]))
        first.index = 0
        first.markLatestRead()
        XCTAssertEqual(store.activity(for: project), .unread)
        first.index = first.replies.count - 1
        first.markLatestRead()
        XCTAssertEqual(store.activity(for: project), .idle)
    }

    func testChangesIncludeStagedUnstagedAndUntracked() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func git(_ args: String...) { XCTAssertEqual(Command.run("/usr/bin/git", ["-C", folder.path] + args).2, 0) }
        git("init", "-q")
        let tracked = folder.appendingPathComponent("tracked.txt")
        try "before\n".write(to: tracked, atomically: true, encoding: .utf8)
        git("add", ".")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Initial")
        try "staged\n".write(to: tracked, atomically: true, encoding: .utf8)
        git("add", ".")
        try "working\n".write(to: tracked, atomically: true, encoding: .utf8)
        try "new content\n".write(to: folder.appendingPathComponent("new file.txt"), atomically: true, encoding: .utf8)
        let changes = try BriefChanges.read(Project(name: "Test", path: folder.path)).get()
        XCTAssertEqual(Set(changes.map(\.path)), ["tracked.txt", "new file.txt"])
        XCTAssertTrue(changes.first { $0.path == "tracked.txt" }!.diff.contains("+working"))
        XCTAssertTrue(changes.first { $0.path == "new file.txt" }!.diff.contains("+new content"))
    }
}
#endif
