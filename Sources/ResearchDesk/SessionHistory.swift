import Foundation
import SQLite3

struct SavedAgentSession: Codable, Identifiable, Sendable {
    let agent: String
    let id: String
    let modified: Date
    var workspace: String? = nil
    var name: String? = nil

    var title: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let date = modified.formatted(date: .abbreviated, time: .shortened)
        return "\(date) · \(id.prefix(8))"
    }

    func belongs(to project: Project) -> Bool {
        guard let workspace else { return true }
        return workspace == project.path || workspace == project.path.replacingOccurrences(of: "/", with: "-")
    }

    var locationLabel: String {
        guard let workspace else { return "" }
        return workspace.hasPrefix("/") ? URL(fileURLWithPath: workspace).lastPathComponent : workspace
    }
}

enum SessionHistory {
    static func discover(_ project: Project) -> [SavedAgentSession]? {
        project.isRemote ? remote(project) : local(project)
    }

    private static func local(_ project: Project) -> [SavedAgentSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexNames = localCodexNames(home: home, project: project)
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        let claudeRoot = home.appendingPathComponent(".claude/projects")
            .appendingPathComponent(project.path.replacingOccurrences(of: "/", with: "-"))
        var result: [SavedAgentSession] = []
        var claudeFiles: [String: URL] = [:]
        if let enumerator = FileManager.default.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let id = uuidSuffix(file.deletingPathExtension().lastPathComponent),
                      let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let prefix = (try? handle.read(upToCount: 65_536)) ?? Data()
                try? handle.close()
                guard let firstLine = String(data: prefix.prefix(while: { $0 != 10 }), encoding: .utf8),
                      firstLine.contains("\"cwd\":\"\(project.path)\"") else { continue }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                result.append(SavedAgentSession(agent: "codex", id: id, modified: date, name: codexNames[id]))
            }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files where file.pathExtension == "jsonl" {
                guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let id = file.deletingPathExtension().lastPathComponent
                claudeFiles[id] = file
                result.append(SavedAgentSession(agent: "claude", id: id, modified: date))
            }
        }
        return result.sorted { $0.modified > $1.modified }.prefix(40).map { session in
            var saved = session
            if let file = claudeFiles[saved.id] { saved.name = claudeName(file) }
            return saved
        }
    }

    private static func localCodexNames(home: URL, project: Project) -> [String: String] {
        let path = home.appendingPathComponent(".codex/state_5.sqlite").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else { if database != nil { sqlite3_close(database) }; return [:] }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = "SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, '')) FROM threads WHERE cwd = ?"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else { return [:] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = project.path.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        var names: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) {
                names[String(cString: id)] = String(cString: name)
            }
        }
        return names
    }

    private static func claudeName(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2_000_000) else { return nil }
        for line in data.split(separator: 10) where line.range(of: Data("\"ai-title\"".utf8)) != nil {
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               object["type"] as? String == "ai-title", let name = object["aiTitle"] as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        }
        return nil
    }

    private static func remote(_ project: Project) -> [SavedAgentSession]? {
        let python = #"""
import os, sys, json, glob, re, datetime, sqlite3
p = sys.argv[1]
h = os.path.expanduser('~')
out = []
names = {}
try:
    db = sqlite3.connect('file:' + h + '/.codex/state_5.sqlite?mode=ro', uri=True)
    names = {sid: name for sid, name in db.execute("SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, '')) FROM threads WHERE cwd = ?", (p,)) if name}
    db.close()
except (sqlite3.Error, OSError):
    pass
def stamp(f):
    return datetime.datetime.fromtimestamp(os.path.getmtime(f), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
def claude_name(f):
    with open(f, 'rb') as stream:
        consumed = 0
        for line in stream:
            consumed += len(line)
            if consumed > 2000000:
                break
            if b'"ai-title"' in line:
                try:
                    item = json.loads(line)
                    if item.get('type') == 'ai-title' and item.get('aiTitle'):
                        return item['aiTitle']
                except (ValueError, UnicodeDecodeError):
                    pass
    return None
codex = glob.glob(h + '/.codex/sessions/*/*/*/*.jsonl')
codex.sort(key=os.path.getmtime, reverse=True)
for f in codex[:1500]:
    sid = os.path.basename(f)[-42:-6]
    if not re.fullmatch(r'[0-9a-fA-F-]{36}', sid):
        continue
    with open(f, 'rb') as stream:
        head = stream.read(65536).split(b'\n', 1)[0]
    match = re.search(rb'"cwd":"([^"]+)"', head)
    if match:
        out.append({'agent':'codex', 'id':sid, 'modified':stamp(f), 'workspace':match.group(1).decode('utf-8', 'replace'), 'name':names.get(sid)})
claude = glob.glob(h + '/.claude/projects/*/*.jsonl')
claude.sort(key=os.path.getmtime, reverse=True)
for index, f in enumerate(claude[:1500]):
    sid = os.path.basename(f)[:-6]
    if re.fullmatch(r'[0-9a-fA-F-]{36}', sid):
        workspace = os.path.basename(os.path.dirname(f))
        if index < 120:
            with open(f, 'rb') as stream:
                match = re.search(rb'"cwd":"([^"]+)"', stream.read(262144))
            if match:
                workspace = match.group(1).decode('utf-8', 'replace')
        out.append({'agent':'claude', 'id':sid, 'modified':stamp(f), 'workspace':workspace, 'file':f})
same = [x for x in out if x['workspace'] in (p, p.replace('/', '-'))]
other = [x for x in out if x['workspace'] not in (p, p.replace('/', '-'))]
same.sort(key=lambda x:x['modified'], reverse=True)
other.sort(key=lambda x:x['modified'], reverse=True)
selected = same[:40] + other[:40]
for item in selected:
    if item['agent'] == 'claude':
        item['name'] = claude_name(item.pop('file'))
print(json.dumps(selected))
"""#
        let command = "python3 -c " + Command.shellQuote(python) + " " + Command.shellQuote(project.path)
        let (output, _, status) = Command.ssh(project.host, command, maxOutput: 100_000)
        guard status == 0, let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder.sessionDecoder.decode([SavedAgentSession].self, from: data)
    }

    private static func uuidSuffix(_ name: String) -> String? {
        guard name.count >= 36 else { return nil }
        let candidate = String(name.suffix(36))
        return UUID(uuidString: candidate) == nil ? nil : candidate
    }
}

private extension JSONDecoder {
    static var sessionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
