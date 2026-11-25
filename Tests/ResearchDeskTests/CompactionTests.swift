import XCTest
@testable import ResearchDesk

final class CompactionTests: XCTestCase {
    @MainActor
    func testNativeCompactionPreservesDraftAndRepliesAcrossReconnectForBothAgents() async throws {
        for agent in ["claude", "codex"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent(agent)
            let script = #"""
#!/usr/bin/env python3
import sys,json,os,time
agent=os.path.basename(sys.argv[0]); compactions=0
def emit(e): print(json.dumps(e),flush=True)
for line in sys.stdin:
    e=json.loads(line); method=e.get('method'); rid=e.get('id')
    if agent=='codex':
        if method=='initialize': emit({'id':rid,'result':{}})
        elif method=='model/list': emit({'id':rid,'result':{'data':[]}})
        elif method in ('thread/start','thread/resume'):
            thread=e.get('params',{}).get('threadId','fixture-thread')
            emit({'id':rid,'result':{'thread':{'id':thread}}})
        elif method=='turn/start':
            emit({'method':'item/completed','params':{'threadId':thread,'item':{'type':'agentMessage','phase':'final_answer','text':'Original reply'}}})
            emit({'method':'thread/tokenUsage/updated','params':{'threadId':thread,'tokenUsage':{'last':{'totalTokens':160000},'modelContextWindow':200000}}})
            emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'status':'completed'}}})
        elif method=='thread/compact/start':
            compactions+=1
            if compactions>1:
                emit({'id':rid,'error':{'code':-32601,'message':'Compaction unavailable'}}); continue
            assert e['params']['threadId']==thread
            emit({'id':rid,'result':{}})
            time.sleep(.05)
            emit({'method':'item/started','params':{'threadId':thread,'item':{'type':'contextCompaction'}}})
            emit({'method':'item/completed','params':{'threadId':thread,'item':{'type':'contextCompaction'}}})
            emit({'method':'thread/tokenUsage/updated','params':{'threadId':thread,'tokenUsage':{'last':{'totalTokens':4000},'modelContextWindow':200000}}})
            emit({'method':'thread/compacted','params':{'threadId':thread}})
            emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'status':'completed'}}})
    elif e.get('type')=='control_request':
        emit({'type':'control_response','response':{'subtype':'success','request_id':e['request_id'],'response':{}}})
    elif e.get('type')=='user':
        text=e['message']['content']
        if text=='/compact':
            compactions+=1
            if compactions>1:
                emit({'type':'result','subtype':'success','result':'Not enough messages to compact.'}); continue
            emit({'type':'system','subtype':'compact_boundary','compact_metadata':{'pre_tokens':160000,'trigger':'manual'}})
            emit({'type':'result','subtype':'success','result':'Compacted'})
        else:
            emit({'type':'system','subtype':'init'})
            emit({'type':'assistant','message':{'usage':{'input_tokens':160000}}})
            emit({'type':'result','subtype':'success','result':'Original reply','modelUsage':{'test':{'contextWindow':200000}}})
"""#
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let chat = BriefAgentModel(project: Project(name: "Fixture", path: root.path), executableOverride: executable.path, agent: agent)
            defer { chat.stop() }
            XCTAssertFalse(chat.canCompact)
            chat.instruction = "First request"; chat.send()
            try await waitForIdle(chat)
            XCTAssertEqual(chat.replies.count, 1, chat.error)
            XCTAssertEqual(chat.contextUsage.tokens, 160000)
            let id = chat.sessionID
            // Force a reconnect, as happens when reopening a saved conversation.
            chat.stop()
            for _ in 0..<300 {
                if chat.status.contains("Disconnected") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            chat.instruction = "Preserve this draft"
            chat.attachments = [BriefAttachment(label: "context", text: "Preserve this attachment")]
            XCTAssertTrue(chat.canCompact)
            chat.compactHistory()
            XCTAssertTrue(chat.compacting)
            XCTAssertFalse(chat.canCompact)
            try await waitForIdle(chat)
            XCTAssertFalse(chat.compacting)
            XCTAssertEqual(chat.sessionID, id)
            XCTAssertEqual(chat.instruction, "Preserve this draft")
            XCTAssertEqual(chat.attachments.count, 1)
            XCTAssertEqual(chat.replies.count, 1)
            XCTAssertEqual(chat.current?.markdown, "Original reply")
            XCTAssertTrue(chat.error.isEmpty, chat.error)
            if agent == "codex" { XCTAssertEqual(chat.contextUsage.tokens, 4000) }
            else {
                XCTAssertNil(chat.contextUsage.tokens)
                XCTAssertTrue(chat.contextUsage.compacted)
                chat.consume(try JSONSerialization.data(withJSONObject: ["type": "assistant", "message": ["usage": ["input_tokens": 3500]]]))
                XCTAssertEqual(chat.contextUsage.tokens, 3500)
                XCTAssertFalse(chat.contextUsage.compacted)
            }
            let tokens = chat.contextUsage.tokens
            chat.compactHistory()
            try await waitForIdle(chat)
            XCTAssertFalse(chat.compacting)
            XCTAssertFalse(chat.error.isEmpty)
            XCTAssertEqual(chat.contextUsage.tokens, tokens)
            XCTAssertEqual(chat.replies.count, 1)
            XCTAssertEqual(chat.instruction, "Preserve this draft")
            XCTAssertEqual(chat.attachments.count, 1)
        }
    }

    @MainActor
    private func waitForIdle(_ chat: BriefAgentModel) async throws {
        for _ in 0..<400 {
            if !chat.running { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Agent did not finish: " + chat.status + " " + chat.error)
    }
}
