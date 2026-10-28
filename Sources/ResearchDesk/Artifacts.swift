import SwiftUI

enum ArtifactLink {
    static func parse(_ input: String) -> URL? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return nil }
        if host == "claude.ai" {
            let pattern = #"^/(?:code/artifact|public/artifacts|artifacts)/[A-Za-z0-9_-]+/?$"#
            guard url.path.range(of: pattern, options: .regularExpression) != nil else { return nil }
        } else if host.hasSuffix(".claude.site") {
            guard host != ".claude.site" else { return nil }
        } else { return nil }
        return url
    }

    static func latest(in data: Data) -> URL? {
        // Read complete JSON records only. A partial final record is normal
        // while Claude is writing its transcript.
        var latest: URL?
        let expression = try! NSRegularExpression(pattern: #"https://[^\s<>\"\\]+"#)
        func inspect(_ object: Any) {
            if let value = object as? String {
                let range = NSRange(value.startIndex..., in: value)
                for match in expression.matches(in: value, range: range) {
                    guard let found = Range(match.range, in: value) else { continue }
                    let candidate = String(value[found]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;]}'"))
                    if let url = parse(candidate) { latest = url }
                }
            } else if let values = object as? [Any] { values.forEach(inspect) }
            else if let values = object as? [String: Any] { values.keys.sorted().forEach { inspect(values[$0]!) } }
        }
        for line in data.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            // A user's pasted URL is not evidence that Claude published it.
            if object["type"] as? String == "user" {
                let message = object["message"] as? [String: Any]
                let blocks = message?["content"] as? [[String: Any]] ?? []
                blocks.filter { $0["type"] as? String == "tool_result" }.forEach(inspect)
            } else { inspect(object) }
        }
        return latest
    }
}

enum ArtifactDiscovery {
    static let tailLimit = 8_000_000
    static func latest(project: Project, sessionID: String) throws -> URL? {
        guard UUID(uuidString: sessionID) != nil else { throw ResearchError.message("Invalid Claude session ID.") }
        if project.isRemote {
            let command = "python3 -c " + Command.shellQuote(remoteScript) + " " + Command.shellQuote(sessionID)
            let (output, failure, code) = Command.ssh(project.host, command, maxOutput: 16_000)
            guard code == 0 else { throw ResearchError.message(failure.isEmpty ? "Could not inspect the remote Claude session." : failure) }
            let record = try JSONDecoder().decode(RemoteResult.self, from: Data(output.utf8))
            if !record.found { throw ResearchError.message("The Claude transcript is not available yet. Publish an artifact in this session, then refresh.") }
            return record.url.flatMap(ArtifactLink.parse)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        return try local(root: config.appendingPathComponent("projects"), sessionID: sessionID)
    }
    static func local(root: URL, sessionID: String) throws -> URL? {
        guard UUID(uuidString: sessionID) != nil else { throw ResearchError.message("Invalid Claude session ID.") }
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let candidates = folders.map { $0.appendingPathComponent(sessionID + ".jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        guard let file = candidates.first else { throw ResearchError.message("The Claude transcript is not available yet. Publish an artifact in this session, then refresh.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let start = end > UInt64(tailLimit) ? end - UInt64(tailLimit) : 0
        try handle.seek(toOffset: start)
        var data = try handle.read(upToCount: tailLimit) ?? Data()
        if start > 0, let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
        return ArtifactLink.latest(in: data)
    }
    private struct RemoteResult: Decodable { let found: Bool; let url: String? }
    static let remoteScript = #"""
import os, sys, json, glob, re
from urllib.parse import urlparse
sid = sys.argv[1]
assert re.fullmatch(r'[0-9a-fA-F-]{36}', sid)
root = os.path.join(os.environ.get('CLAUDE_CONFIG_DIR', os.path.expanduser('~/.claude')), 'projects')
files = glob.glob(os.path.join(root, '*', sid + '.jsonl'))
latest = None
def inspect(value):
    global latest
    if isinstance(value, str):
        for raw in re.findall(r'https://[^\s<>"\\]+', value):
            raw = raw.rstrip(').,;]}\'')
            u = urlparse(raw)
            host = (u.hostname or '').lower()
            valid = (host == 'claude.ai' and re.fullmatch(r'/(?:code/artifact|public/artifacts|artifacts)/[A-Za-z0-9_-]+/?', u.path)) or host.endswith('.claude.site')
            if valid and not u.username and not u.password:
                latest = raw
    elif isinstance(value, list):
        for item in value: inspect(item)
    elif isinstance(value, dict):
        for key in sorted(value): inspect(value[key])
if files:
    f = max(files, key=os.path.getmtime)
    with open(f, 'rb') as stream:
        start = max(0, os.path.getsize(f) - 8000000)
        stream.seek(start)
        data = stream.read(8000000)
        if start: data = data.partition(b'\n')[2]
    for line in data.splitlines():
        try:
            obj = json.loads(line)
            if obj.get('type') == 'user':
                content = obj.get('message', {}).get('content', [])
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get('type') == 'tool_result': inspect(block)
            else: inspect(obj)
        except (ValueError, AttributeError): pass
print(json.dumps({'found':bool(files), 'url':latest}))
"""#
}

struct ArtifactsPane: View {
    let session: AgentSession?
    @State private var input = ""
    @State private var url: URL?
    @State private var error = ""
    @State private var webError = ""
    @State private var loading = false
    @State private var reload = 0
    @State private var request = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Claude artifact URL", text: $input).textFieldStyle(DeskFieldStyle()).onSubmit { open() }
                Button("Open") { open() }.disabled(input.isEmpty)
                Button("Latest in chat") { discover() }.disabled(session?.agent != "claude" || loading)
                if loading { ProgressView().controlSize(.small) }
            }.padding(12).background { DeskMetalSurface() }
            if let url {
                HStack {
                    Text("Sign in to Claude here if the artifact is private.").font(.caption).foregroundStyle(DeskStyle.muted)
                    Spacer()
                    Button("Reload") { reload += 1 }
                    Button("Open in browser ↗") { NSWorkspace.shared.open(url) }
                }.padding(.horizontal, 12).padding(.vertical, 5)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10) }
            if !webError.isEmpty { Text(webError + " — try Open in browser.").font(.caption).foregroundStyle(.orange).padding(10) }
            if let url {
                HostedArtifactWebView(url: url, reload: reload, error: $webError)
            } else {
                VStack(spacing: 8) {
                    Text("Claude artifacts").font(.system(size: 15, weight: .medium))
                    Text("Open the latest hosted artifact linked in this Claude session, or paste its URL above.")
                        .font(.callout).foregroundStyle(DeskStyle.muted).multilineTextAlignment(.center)
                    Text("In Claude Code, /artifacts lists your artifacts and lets you copy a link.")
                        .font(.caption).foregroundStyle(DeskStyle.muted)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(DeskStyle.background)
            .task { if let existing = session?.artifactURL { input = existing.absoluteString; url = existing } else if session?.agent == "claude" { discover() } }
            .onDisappear { request = UUID(); loading = false }
    }
    private func open() {
        guard let parsed = ArtifactLink.parse(input) else { error = "Use a hosted artifact URL on claude.ai or claude.site."; return }
        request = UUID(); loading = false
        url = parsed; session?.artifactURL = parsed; error = ""; webError = ""
    }
    private func discover() {
        guard let session, session.agent == "claude" else { return }
        let project = session.project
        let id = session.claudeSessionID
        request = UUID(); let token = request
        loading = true; error = ""
        Task {
            let result = await Task.detached { () -> Result<URL?, Error> in
                Result { try ArtifactDiscovery.latest(project: project, sessionID: id) }
            }.value
            guard request == token else { return }
            loading = false
            switch result {
            case .success(let found):
                if let found { url = found; input = found.absoluteString; session.artifactURL = found; webError = "" }
                else { error = "No hosted artifact link found in the most recent 8 MB of this chat. Use /artifacts in Claude to copy its link, then paste it above." }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
