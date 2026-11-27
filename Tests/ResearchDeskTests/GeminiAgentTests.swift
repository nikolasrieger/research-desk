import XCTest
@testable import ResearchDesk

final class GeminiAgentTests: XCTestCase {
    @MainActor
    func testPersistentChatModelsApprovalsAndTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("gemini")
        let source = #"""
#!/usr/bin/env python3
import sys,json,os
assert sys.argv[1:]==['--acp']
turn=0
resumed=False
pending=None
sid='gemini-session-test'
def emit(o): print(json.dumps(dict(jsonrpc='2.0',**o)),flush=True)
def update(u): emit({'method':'session/update','params':{'sessionId':sid,'update':u}})
def finish():
    update({'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Final '+str(turn)+' pid '+str(os.getpid())}})
    emit({'id':pending,'result':{'stopReason':'end_turn'}})
for line in sys.stdin:
    e=json.loads(line); m=e.get('method'); rid=e.get('id'); p=e.get('params',{})
    assert e['jsonrpc']=='2.0'
    if m=='initialize':
        assert p['clientCapabilities']['terminal']==False
        emit({'id':rid,'result':{'protocolVersion':1,'agentCapabilities':{'loadSession':True}}})
    elif m in ('session/new','session/load'):
        assert p['mcpServers']==[]
        if m=='session/load':
            resumed=True
            assert p['sessionId']==sid
            update({'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Old replayed answer'}})
        emit({'id':rid,'result':{'sessionId':sid,'models':{'currentModelId':'auto','availableModels':[{'modelId':'auto','name':'Auto'},{'modelId':'flash','name':'Flash'}]}}})
    elif m=='session/set_model':
        assert p['modelId']=='flash'
        emit({'id':rid,'result':{}})
    elif m=='session/prompt':
        turn+=1; pending=rid
        assert ('<research-desk-job-registration>' in p['prompt'][0]['text'])==(turn==1 and not resumed)
        update({'sessionUpdate':'agent_thought_chunk','content':{'type':'text','text':'Private thoughts'}})
        update({'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Intermediate commentary'}})
        update({'sessionUpdate':'tool_call','toolCallId':'tool','title':'Check files'})
        emit({'id':42,'method':'session/request_permission','params':{'sessionId':sid,'toolCall':{'title':'Run command'},'options':[{'kind':'allow_once','optionId':'yes'},{'kind':'reject_once','optionId':'no'}]}})
    elif rid==42:
        assert e['result']['outcome']=={'outcome':'selected','optionId':'yes'}
        finish()
"""#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let project = Project(name: "Gemini", path: root.path)
        let historyRoot = root.appendingPathComponent("history")
        let chat = BriefAgentModel(project: project, executableOverride: executable.path, agent: "gemini", geminiTranscriptRoot: historyRoot)
        defer { chat.stop() }
        await chat.refreshModels()
        for _ in 0..<300 {
            if !chat.loadingModels { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(chat.agentName, "Gemini CLI")
        XCTAssertEqual(chat.modelOptions.map(\.id), ["", "auto", "flash"], chat.error)
        XCTAssertFalse(chat.running)
        XCTAssertTrue(chat.replies.isEmpty)
        chat.chooseModel("flash")
        for turn in 1...2 {
            chat.instruction = "Turn \(turn)"
            chat.send()
            for _ in 0..<300 {
                if !chat.permissions.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let permission = try XCTUnwrap(chat.permissions.first, chat.error)
            chat.answer(permission, allow: true)
            for _ in 0..<300 {
                if !chat.running { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(chat.running, chat.error)
            XCTAssertEqual(chat.replies.count, turn, chat.error)
            XCTAssertTrue(chat.current?.markdown.hasPrefix("Final \(turn) pid ") == true)
            XCTAssertFalse(chat.current?.markdown.contains("commentary") == true)
            XCTAssertEqual(chat.activeModel, "flash")
        }
        XCTAssertEqual(chat.replies[0].markdown.components(separatedBy: " pid ").last,
                       chat.replies[1].markdown.components(separatedBy: " pid ").last)
        let records = try GeminiTranscriptStore.read(project, id: chat.sessionID, root: historyRoot).get()
        XCTAssertEqual(records.map(\.instruction), ["Turn 1", "Turn 2"])
        XCTAssertEqual(GeminiTranscriptStore.discover(host: "", root: historyRoot).first?.id, chat.sessionID)
        XCTAssertTrue(GeminiTranscriptStore.discover(host: "other-host", root: historyRoot).isEmpty)
        XCTAssertFalse(chat.canCompact)

        chat.stop()
        for _ in 0..<300 {
            if chat.status.hasPrefix("Disconnected") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.instruction = "Resume after reconnect"
        chat.send()
        for _ in 0..<300 {
            if !chat.permissions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.answer(try XCTUnwrap(chat.permissions.first, chat.error), allow: true)
        for _ in 0..<300 {
            if !chat.running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(chat.replies.count, 3, chat.error)
        XCTAssertFalse(chat.current?.markdown.contains("replayed") == true)
        XCTAssertEqual(chat.current?.instruction, "Resume after reconnect")
        XCTAssertEqual(try GeminiTranscriptStore.read(project, id: chat.sessionID, root: historyRoot).get().count, 3)
    }

    @MainActor
    func testAuthenticationErrorPreservesDraft() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chat = BriefAgentModel(project: Project(name: "Gemini", path: root.path), agent: "gemini", geminiTranscriptRoot: root)
        chat.instruction = "Unsent draft"
        chat.consumeGemini(["id": "gemini-session", "error": ["code": -32000, "message": "Authentication required"]])
        XCTAssertTrue(chat.error.contains("Authentication required"))
        XCTAssertTrue(chat.error.contains("sign-in"))
        XCTAssertEqual(chat.instruction, "Unsent draft")
        XCTAssertFalse(chat.running)
        XCTAssertFalse(chat.loadingModels)
        XCTAssertTrue(chat.replies.isEmpty)
    }

    func testTranscriptSeparatesHostsAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = Project(name: "Local", path: "/work")
        let remote = Project(name: "Remote", path: "/work", host: "nugget")
        let record = BriefHistory.Record(instruction: "Question", markdown: "Answer", incomplete: false,
                                        contextTokens: nil, contextWindow: nil, contextCompacted: nil)
        try GeminiTranscriptStore.save(local, id: "same-id", title: "Local", records: [record], root: root)
        try GeminiTranscriptStore.save(remote, id: "same-id", title: "Remote", records: [], root: root)
        XCTAssertEqual(try GeminiTranscriptStore.read(local, id: "same-id", root: root).get().count, 1)
        XCTAssertEqual(try GeminiTranscriptStore.read(remote, id: "same-id", root: root).get().count, 0)
        XCTAssertEqual(GeminiTranscriptStore.discover(host: "nugget", root: root).first?.name, "Remote")
        XCTAssertThrowsError(try GeminiTranscriptStore.read(Project(name: "Other", path: "/other"), id: "same-id", root: root).get())
    }
}
