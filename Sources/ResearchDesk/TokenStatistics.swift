import Foundation

/// Reads reported usage from native transcripts, rather than estimating tokens from text.
enum TokenStatistics {
    static func read(host: String) throws -> [String: [String: Int64]] {
        let command = "TZ=" + Command.shellQuote(TimeZone.current.identifier) + " python3 -c " + Command.shellQuote(script)
        let result = host.isEmpty ? Command.run("/bin/zsh", ["-lc", command], timeout: 90, maxOutput: 8_000_000)
            : Command.ssh(host, command, maxOutput: 8_000_000, timeout: 90)
        guard result.2 == 0 else { throw ResearchError.message("Could not read token statistics. " + result.1) }
        return try JSONDecoder().decode([String: [String: Int64]].self, from: Data(result.0.utf8))
    }
    static let script = #"""
import os,glob,json,datetime
result={}
def add(cwd,stamp,count):
    if not cwd or not stamp or count<=0: return
    try: day=datetime.datetime.fromisoformat(stamp.replace('Z','+00:00')).astimezone().strftime('%Y-%m-%d')
    except (ValueError,TypeError): return
    days=result.setdefault(os.path.normpath(cwd),{})
    days[day]=days.get(day,0)+count

def events(path):
    with open(path,encoding='utf-8',errors='replace') as stream:
        for line in stream:
            try:
                item=json.loads(line)
                if isinstance(item,dict): yield item
            except ValueError: pass

# Claude can repeat usage in multiple content blocks for the same API message.
messages={}
root=os.environ.get('CLAUDE_CONFIG_DIR',os.path.expanduser('~/.claude'))
for path in glob.glob(os.path.join(root,'projects','**','*.jsonl'),recursive=True):
    try:
        cwd=None
        for e in events(path):
            cwd=e.get('cwd') or cwd
            if e.get('type')!='assistant' or e.get('isApiErrorMessage'): continue
            m=e.get('message') or {}; u=m.get('usage') or {}
            if not isinstance(u,dict) or not m.get('id'): continue
            key=(e.get('sessionId') or path,m['id'])
            count=sum(max(0,int(u.get(k) or 0)) for k in ('input_tokens','cache_creation_input_tokens','cache_read_input_tokens','output_tokens'))
            previous=messages.get(key)
            if not previous or count>previous[2]: messages[key]=(cwd,e.get('timestamp'),count)
    except (OSError,ValueError,TypeError): continue
for cwd,stamp,count in messages.values(): add(cwd,stamp,count)

# Codex reports cumulative usage; differences avoid recounting repeated snapshots.
root=os.environ.get('CODEX_HOME',os.path.expanduser('~/.codex'))
seen=set()
for path in sorted(glob.glob(os.path.join(root,'sessions','*','*','*','*.jsonl'))+glob.glob(os.path.join(root,'archived_sessions','*.jsonl'))):
    try:
        cwd=None; previous=0
        for e in events(path):
            p=e.get('payload') or {}
            if not isinstance(p,dict): continue
            if e.get('type')=='session_meta': cwd=p.get('cwd')
            if e.get('type')!='event_msg' or p.get('type')!='token_count': continue
            usage=(p.get('info') or {}).get('total_token_usage') or {}
            if 'total_tokens' not in usage: continue
            total=max(0,int(usage['total_tokens']))
            delta=total-previous if total>=previous else total; previous=total
            key=(cwd,e.get('timestamp'),total)
            if key in seen: continue
            seen.add(key); add(cwd,e.get('timestamp'),delta)
    except (OSError,ValueError,TypeError): continue
print(json.dumps(result))
"""#
}
