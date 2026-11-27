import Foundation

struct CodexQuestion: Identifiable {
    let id: String
    let requestKey: String
    let prompt: String
    let options: [String]
    var answer = ""
    var secret = false
}

struct CodexSessionState {
    var threadReady = false
    var defaultModel: String?
    var finalAnswer = ""
    var fallbackAnswer = ""
    var sawPhase = false
    var turnID: String?
    mutating func beginTurn() { finalAnswer = ""; fallbackAnswer = ""; sawPhase = false; turnID = nil }
    mutating func observeItem(_ item: [String: Any]) {
        let type = item["type"] as? String ?? ""
        if type == "agentMessage" {
            let phase = item["phase"] as? String
            if phase != nil { sawPhase = true }
            if phase == "final_answer" { finalAnswer = item["text"] as? String ?? "" }
            else if phase == nil { fallbackAnswer = item["text"] as? String ?? "" }
        } else if ["commandExecution", "fileChange", "mcpToolCall", "webSearch", "dynamicToolCall"].contains(type) {
            fallbackAnswer = ""
        }
    }
    var answer: String { (sawPhase ? finalAnswer : fallbackAnswer).trimmingCharacters(in: .whitespacesAndNewlines) }
    static var initialize: [String: Any] { ["id": "rd-initialize", "method": "initialize", "params": ["clientInfo": ["name": "research_desk", "title": "Research Desk", "version": "1.0"]]] }
    static func request(_ method: String, id: String, params: [String: Any]) -> [String: Any] { ["method": method, "id": id, "params": params] }
}

enum CodexHistory {
    static func read(_ project: Project, id: String) -> Result<[BriefHistory.Record], Error> {
        guard !id.isEmpty, id.utf8.count < 256, id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return .failure(ResearchError.message("Invalid Codex session ID.")) }
        let command = "python3 -c " + Command.shellQuote(script) + " " + Command.shellQuote(id)
        let result = project.isRemote ? Command.ssh(project.host, command, maxOutput: 8_000_000, timeout: 30) : Command.run("/bin/zsh", ["-c", command], timeout: 30, maxOutput: 8_000_000)
        guard result.2 == 0 else { return .failure(ResearchError.message("Could not load Codex conversation. " + result.1)) }
        do { return .success(try JSONDecoder().decode([BriefHistory.Record].self, from: Data(result.0.utf8))) }
        catch { return .failure(error) }
    }
    static let discovery = #"""
codex_root = os.environ.get('CODEX_HOME', os.path.expanduser('~/.codex'))
for path in glob.glob(os.path.join(codex_root, 'sessions', '*', '*', '*', '*.jsonl')):
    try:
        with open(path, 'rb') as f: head = f.read(65536).decode('utf-8', 'replace').splitlines()
        meta = json.loads(head[0]).get('payload', {})
        sid = meta.get('id'); cwd = meta.get('cwd')
        if not sid or not cwd: continue
        title = None
        for line in head[1:]:
            try: event = json.loads(line)
            except ValueError: continue
            payload = event.get('payload', {})
            if event.get('type') == 'event_msg' and payload.get('type') == 'user_message':
                title = payload.get('message'); break
        stamp = datetime.datetime.fromtimestamp(os.path.getmtime(path), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        found['codex:'+sid] = dict(agent='codex', id=sid, modified=stamp, workspace=cwd, name=str(title or '')[:180] or None)
    except (OSError, ValueError, TypeError, KeyError): continue
"""#
    static let script = #"""
import os, glob, sys, json
root = os.environ.get('CODEX_HOME', os.path.expanduser('~/.codex'))
files = glob.glob(os.path.join(root, 'sessions', '*', '*', '*', '*'+sys.argv[1]+'.jsonl'))
if not files: sys.exit('Codex transcript is not available on this machine.')
path = max(files, key=os.path.getmtime)
records=[]; instruction=''; final=''; fallback=''; partial=''; phased=False; active=False; saw_assistant=False; event_user=False; tokens=None; window=None; compacted=False

def flush(complete=False, message=None):
    global instruction, final, fallback, partial, phased, active, saw_assistant, event_user
    answer = str(message or (final if phased else fallback) or (partial if not complete else '')).strip()
    if instruction:
        records.append(dict(instruction=instruction[:100000], markdown=answer[:150000], incomplete=not complete))
    instruction=''; final=''; fallback=''; partial=''; phased=False; active=False; saw_assistant=False; event_user=False

def user_text(payload):
    content=payload.get('content', [])
    metadata=payload.get('internal_chat_message_metadata_passthrough') or {}
    kinds=metadata.get('content_item_kinds') if isinstance(metadata, dict) else None
    parts=[]
    for index, block in enumerate(content):
        if not isinstance(block,dict) or block.get('type') not in ('input_text','text'): continue
        if isinstance(kinds,list) and (index >= len(kinds) or kinds[index] != 'user.text'): continue
        text=block.get('text','')
        if not isinstance(text,str): continue
        if not kinds and text.lstrip().startswith(('<environment_context>', '# AGENTS.md instructions')): continue
        parts.append(text)
    return '\n\n'.join(parts).strip()

with open(path, 'rb') as f:
    start=max(0, os.path.getsize(path)-8000000); f.seek(start)
    if start: f.readline()
    lines=f.read().decode('utf-8','replace').splitlines()
for line in lines:
    try: e=json.loads(line)
    except ValueError: continue
    p=e.get('payload', {})
    if not isinstance(p,dict): continue
    typ=p.get('type')
    if e.get('type')=='compacted' or (e.get('type')=='event_msg' and typ=='context_compacted'): tokens=None; compacted=True
    if e.get('type')=='event_msg':
        if typ=='task_started':
            if instruction: flush()
            active=True; saw_assistant=False; event_user=False
        elif typ=='user_message':
            # Older versions emit both response_item/user and user_message.
            # The event is authoritative; do not add a duplicate turn.
            if instruction and (event_user or saw_assistant): flush()
            instruction=str(p.get('message') or ''); active=True; event_user=True
        elif typ=='task_complete': flush(True, p.get('last_agent_message'))
        elif typ in ('turn_aborted','task_failed'): flush()
        elif typ=='token_count':
            info=p.get('info') or {}; usage=info.get('last_token_usage') or {}
            tokens=usage.get('total_tokens'); window=info.get('model_context_window'); compacted=False
    elif e.get('type')=='response_item':
        if typ=='message' and p.get('role')=='user':
            text=user_text(p)
            if text and not event_user:
                if saw_assistant: flush()
                instruction=(instruction+'\n\n'+text).strip(); active=True
        elif typ=='message' and p.get('role')=='assistant':
            saw_assistant=True
            text='\n\n'.join(b.get('text','') for b in p.get('content',[]) if b.get('type')=='output_text')
            if text.strip(): partial=text
            phase=p.get('phase')
            if phase is not None: phased=True
            if phase=='final_answer': final=text
            elif phase is None: fallback=text
        elif typ in ('function_call','custom_tool_call','web_search_call'): fallback=''
if instruction: flush()
if records: records[-1].update(contextTokens=tokens, contextWindow=window, contextCompacted=compacted)
print(json.dumps(records[-40:]))
"""#
}
