import XCTest
@testable import ResearchDesk

final class ProviderSwitchTests: XCTestCase {
    @MainActor
    func testSwitchTransfersVisibleHistoryOnceAndPersistsAuthors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try #"""
#!/usr/bin/env python3
import sys,json
turn=0
def emit(o): print(json.dumps(o),flush=True)
for line in sys.stdin:
    e=json.loads(line); m=e.get('method'); rid=e.get('id')
    if m=='initialize': emit({'id':rid,'result':{}})
    elif m=='model/list': emit({'id':rid,'result':{'data':[]}})
    elif m=='thread/start': emit({'id':rid,'result':{'thread':{'id':'switched-session'}}})
    elif m=='turn/start':
        turn+=1
        text=e['params']['input'][0]['text']
        if turn==1:
            history=json.loads(text.split('Previous conversation (JSON):\n')[1].split('\n\nCurrent user instruction:\n')[0])
            assert history==[{'user':'Original question','assistant':'Original answer','provider':'claude'}]
            assert 'Continue with Codex' in text
            assert 'Selected file context: selected.py' in text
        else: assert 'Previous conversation (JSON):' not in text
        emit({'method':'turn/completed','params':{'threadId':'switched-session','turn':{'status':'completed','items':[{'type':'agentMessage','phase':'final_answer','text':'Codex answer '+str(turn)}]}}})
"""#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let project = Project(name: "Switch", path: root.path)
        let previous = BriefAgentModel(project: project)
        previous.title = "Original chat"
        previous.replies = [.init(instruction: "Original question", markdown: "Original answer")]
        previous.instruction = "Continue with Codex"
        previous.attachments = [.init(label: "selected.py", text: "print('context')")]
        let archive = root.appendingPathComponent("archive")
        let next = BriefAgentModel(project: project, executableOverride: executable.path, agent: "codex", geminiTranscriptRoot: archive)
        defer { next.stop() }
        XCTAssertTrue(next.adoptConversation(from: previous))
        XCTAssertEqual(next.title, previous.title)
        XCTAssertEqual(next.replies.count, 1)
        XCTAssertEqual(next.replies[0].provider, "claude")
        XCTAssertEqual(next.instruction, previous.instruction)
        XCTAssertEqual(next.attachments.count, 1)
        XCTAssertFalse(next.hasStoredSession)
        for turn in 1...2 {
            if turn == 2 { next.instruction = "Follow-up" }
            next.send()
            for _ in 0..<300 {
                if !next.running { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(next.running, next.error)
            XCTAssertEqual(next.replies.count, turn + 1, next.error)
        }
        XCTAssertEqual(next.replies.map(\.provider), ["claude", "codex", "codex"])
        let snapshot = try XCTUnwrap(AgentTranscriptStore.snapshot(project, id: next.sessionID, agent: "codex", root: archive))
        XCTAssertNil(snapshot.handoff)
        XCTAssertEqual(snapshot.records.map(\.provider), ["claude", "codex", "codex"])
        XCTAssertEqual(previous.replies.count, 1)
        XCTAssertEqual(previous.instruction, "Continue with Codex")
    }

    @MainActor
    func testSwitchRejectsRunningInterruptedAndOversizedChats() {
        let project = Project(name: "Switch", path: "/tmp")
        let previous = BriefAgentModel(project: project)
        let next = BriefAgentModel(project: project, agent: "gemini")
        previous.running = true
        XCTAssertFalse(next.adoptConversation(from: previous))
        previous.running = false; previous.interrupted = true
        XCTAssertFalse(next.adoptConversation(from: previous))
        previous.interrupted = false
        previous.replies = [.init(instruction: "Large", markdown: String(repeating: "x", count: 450_000))]
        XCTAssertFalse(next.adoptConversation(from: previous))
        XCTAssertTrue(previous.error.contains("too large"))
        XCTAssertTrue(next.replies.isEmpty)
    }
}
