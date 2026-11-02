#if DEBUG
import SwiftUI
import AppKit

/// A persistent, line-oriented Claude Code transport shared by every turn in a conversation.
final class BriefTransport: @unchecked Sendable {
    enum Event: Sendable { case line(Data), stderr(String), exit(Int32) }
    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let writes = DispatchQueue(label: "researchdesk.brief.stdin")

    func run(project: Project, executable: String?, sessionID: String, resume: Bool) throws -> AsyncStream<Event> {
        let args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-prompt-tool", "stdio", "--permission-mode", "auto", resume ? "--resume" : "--session-id", sessionID]
        if project.isRemote {
            let command = (["claude"] + args).map(Command.shellQuote).joined(separator: " ")
            let remote = "cd " + Command.shellQuote(project.path) + " && exec \"${SHELL:-/bin/bash}\" -lic " + Command.shellQuote(command)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "--", project.host, remote]
        } else {
            guard let executable else { throw ResearchError.message("Claude Code was not found on this Mac. Install the CLI and sign in before sending an instruction.") }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: project.path)
        }
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [executable.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }, env["PATH"], home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].compactMap { $0 }.joined(separator: ":")
        process.environment = env
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        try process.run()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            var pending = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    continuation.yield(.line(Data(pending[..<end])))
                    pending.removeSubrange(...end)
                }
                if pending.count > 8_000_000 { pending.removeAll(); continuation.yield(.stderr("Claude emitted an oversized event; it was omitted.")) }
            }
            if !pending.isEmpty { continuation.yield(.line(pending)) }
        }
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            while true {
                let data = errors.fileHandleForReading.availableData
                if data.isEmpty { break }
                continuation.yield(.stderr(String(decoding: data, as: UTF8.self)))
            }
        }
        DispatchQueue.global().async { [self] in
            process.waitUntilExit()
            group.wait()
            continuation.yield(.exit(process.terminationStatus))
            continuation.finish()
        }
        return stream
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        writes.async { [self] in
            try? input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        }
    }
    func closeInput() { writes.async { [self] in try? input.fileHandleForWriting.close() } }
    func stop() {
        closeInput()
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// Accumulates fragments of one main-agent message without promoting commentary to a final answer.
struct BriefFinalResponse {
    private var messageID: String?
    private var text: [Int: String] = [:]
    private var hasTools = false
    private var stopReason: String?
    mutating func observe(_ event: [String: Any]) {
        guard event["type"] as? String == "assistant", event["isSidechain"] as? Bool != true,
              event["parent_tool_use_id"] as? String == nil,
              event["isApiErrorMessage"] as? Bool != true,
              let message = event["message"] as? [String: Any] else { return }
        let id = message["id"] as? String ?? event["uuid"] as? String ?? UUID().uuidString
        if messageID != id { messageID = id; text = [:]; hasTools = false; stopReason = nil }
        if let reason = message["stop_reason"] as? String { stopReason = reason }
        let blocks = message["content"] as? [[String: Any]] ?? []
        for (index, block) in blocks.enumerated() {
            if block["type"] as? String == "tool_use" { hasTools = true }
            if block["type"] as? String == "text", let value = block["text"] as? String {
                text[(event["apiBlockIndex"] as? Int ?? 0) + index] = value
            }
        }
    }
    func finalText(resultConfirmsCompletion: Bool) -> String? {
        guard !hasTools, stopReason == "end_turn" || stopReason == "stop_sequence" || (stopReason == nil && resultConfirmsCompletion) else { return nil }
        let result = text.keys.sorted().compactMap { text[$0] }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

struct BriefReply: Identifiable {
    let id = UUID()
    let instruction: String
    let markdown: String
    let date = Date()
}
struct BriefPermission: Identifiable {
    let id: String
    let tool: String
    let input: [String: Any]
    var detail: String { (try? String(data: JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)) ?? "" }
}
struct BriefChangedFile: Decodable, Identifiable, Sendable {
    let path: String
    let status: String
    let diff: String
    var id: String { path }
}
struct BriefAttachment: Identifiable {
    let id = UUID()
    let label: String
    let text: String
}

/// Shared across project-tab switches; release builds never contain this store.
@MainActor final class BriefAgentStore: ObservableObject {
    static let shared = BriefAgentStore()
    private var sessions: [UUID: BriefAgentModel] = [:]
    @Published private(set) var savedChats: [String: [SavedAgentSession]] = [:]
    @Published private(set) var loadingHosts: Set<String> = []
    @Published var discoveryError = ""
    @Published private var conversations: [UUID: [BriefAgentModel]] = [:]
    private var observer: NSObjectProtocol?
    private var lastOpened: [String: UUID] = [:]
    private let defaults = UserDefaults(suiteName: WorkspaceStorage.domain) ?? .standard
    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BriefAgentStore.shared.conversations.values.flatMap { $0 }.forEach { $0.stop() } }
        }
    }
    func session(for project: Project) -> BriefAgentModel {
        if let existing = sessions[project.id], existing.project == project { return existing }
        let model = BriefAgentModel(project: project)
        track(model)
        sessions[project.id] = model
        conversations[project.id, default: []].append(model)
        return model
    }
    enum Activity { case idle, running, unread }
    func activity(for project: Project) -> Activity {
        let chats = chats(for: project)
        if chats.contains(where: { $0.running }) { return .running }
        if chats.contains(where: { $0.hasUnreadReply }) { return .unread }
        return .idle
    }
    private func track(_ model: BriefAgentModel) {
        model.onActivityChange = { [weak self] in self?.objectWillChange.send() }
    }
    func chats(for project: Project) -> [BriefAgentModel] { conversations[project.id] ?? [] }
    func create(for project: Project) -> BriefAgentModel {
        let model = BriefAgentModel(project: project)
        track(model)
        conversations[project.id, default: []].append(model)
        return model
    }
    private func selectionKey(_ project: Project) -> String { "agent.lastChat." + project.host + ":" + project.path }
    func remember(_ chat: BriefAgentModel, for project: Project) {
        let key = selectionKey(project)
        lastOpened[key] = chat.id
        let saved = SavedAgentSession(agent: "claude", id: chat.sessionID, modified: Date(), workspace: chat.project.path, name: chat.title)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }
    func restore(for project: Project) -> BriefAgentModel? {
        let key = selectionKey(project)
        if let id = lastOpened[key], let chat = chats(for: project).first(where: { $0.id == id }) { return chat }
        guard let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(SavedAgentSession.self, from: data) else { return nil }
        return open(saved, project: project)
    }
    func discover(_ project: Project) {
        let host = project.host
        guard loadingHosts.insert(host).inserted else { return }
        discoveryError = ""
        Task {
            let result = await Task.detached { BriefConversationHistory.read(project) }.value
            loadingHosts.remove(host)
            switch result {
            case .success(let found): savedChats[host] = found
            case .failure(let error): discoveryError = error.localizedDescription
            }
        }
    }
    func open(_ saved: SavedAgentSession, project: Project) -> BriefAgentModel {
        if let existing = chats(for: project).first(where: { $0.sessionID == saved.id }) { return existing }
        var workingProject = project
        if let path = saved.workspace, path.hasPrefix("/"), path != project.path {
            workingProject.path = path
            workingProject.name = URL(fileURLWithPath: path).lastPathComponent
        }
        let model = BriefAgentModel(project: workingProject)
        track(model)
        conversations[project.id, default: []].append(model)
        model.useSession(saved)
        return model
    }
}

@MainActor final class BriefAgentModel: ObservableObject {
    let project: Project
    private let executableOverride: String?
    let id = UUID()
    @Published var title = "New conversation"
    @Published var interrupted = false
    @Published var replies: [BriefReply] = []
    @Published var index = 0
    @Published var instruction = ""
    @Published var attachments: [BriefAttachment] = []
    @Published var progress: [String] = []
    @Published var permissions: [BriefPermission] = []
    @Published var changes: [BriefChangedFile] = []
    var onActivityChange: (() -> Void)?
    @Published var hasUnreadReply = false { didSet { onActivityChange?() } }
    @Published var running = false { didSet { onActivityChange?() } }
    @Published var loadingChanges = false
    @Published var loadingHistory = false
    @Published var error = ""
    @Published var status = "Ready for an instruction"
    @Published var sessionID = UUID().uuidString.lowercased()
    private var resume = false
    private var transport: BriefTransport?
    private var pendingInstruction = ""
    private var receivedResult = false
    private var resultFailed = false
    private var finalResponse = BriefFinalResponse()
    private var seenToolIDs: Set<String> = []
    private var pendingAttachments: [BriefAttachment] = []
    private var queuedPrompt: String?
    private let initializationID = "brief-initialize"

    init(project: Project, executableOverride: String? = nil) {
        self.project = project
        self.executableOverride = executableOverride
    }
    var canContinue: Bool { resume && interrupted && !running && !loadingHistory }
    var current: BriefReply? { replies.indices.contains(index) ? replies[index] : nil }

    func useSession(_ saved: SavedAgentSession) {
        guard !running, !loadingHistory, saved.agent == "claude", UUID(uuidString: saved.id) != nil else { return }
        let previous = transport; transport = nil; previous?.stop()
        sessionID = saved.id; resume = true; title = saved.title; error = ""; interrupted = false
        replies.removeAll(); index = 0; progress.removeAll(); permissions.removeAll(); attachments.removeAll()
        status = "Resuming \(saved.title)"
        if let path = saved.workspace, path.hasPrefix("/"), path != project.path {
            error = "This saved conversation belongs to another directory. Select a session from this workspace."
            resume = false; sessionID = UUID().uuidString.lowercased()
            return
        }
        loadingHistory = true
        let project = project
        Task {
            let result = await Task.detached { BriefHistory.read(project, id: saved.id) }.value
            loadingHistory = false
            switch result {
            case .success(let records):
                replies = records.filter { $0.incomplete != true }.map { BriefReply(instruction: $0.instruction, markdown: $0.markdown) }
                interrupted = records.last?.incomplete == true
                if interrupted { pendingInstruction = records.last?.instruction ?? "" }

                index = max(0, replies.count - 1)
                status = interrupted ? "Conversation ended before a final response" : "Saved conversation ready"
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    func newConversation() {
        guard !running, !loadingHistory else { return }
        let previous = transport; transport = nil; previous?.stop()
        sessionID = UUID().uuidString.lowercased(); resume = false
        replies.removeAll(); index = 0; progress.removeAll(); permissions.removeAll(); attachments.removeAll()
        error = ""; status = "Ready for an instruction"
    }
    static func prompt(_ instruction: String, attachments: [BriefAttachment]) -> String {
        instruction + attachments.map { "\n\nSelected file context: \($0.label)\n<context>\n\($0.text)\n</context>" }.joined()
    }
    func send() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running, !loadingHistory, !reloading, !text.isEmpty else { return }
        let prompt = Self.prompt(text, attachments: attachments)
        guard prompt.utf8.count < 512_000 else { error = "Instruction and selected context exceed 512 KB. Select fewer lines."; return }
        error = ""; permissions = []; progress = []; seenToolIDs.removeAll(); running = true; receivedResult = false; resultFailed = false; finalResponse = BriefFinalResponse()
        if title == "New conversation" { title = String(text.prefix(90)) }
        interrupted = false
        pendingInstruction = text; pendingAttachments = attachments; status = project.isRemote ? "Connecting to \(project.host)…" : "Starting Claude Code…"
        if let connection = transport {
            guard connection.process.isRunning else {
                running = false
                status = "Connection is closing; try again in a moment"
                return
            }
            status = "Claude is working…"
            connection.send(["type": "user", "message": ["role": "user", "content": prompt]])
            instruction = ""; attachments.removeAll()
            return
        }
        let connection = BriefTransport()
        do {
            let events = try connection.run(project: project, executable: project.isRemote ? nil : (executableOverride ?? AgentLocator.executable("claude")), sessionID: sessionID, resume: resume)
            transport = connection
            queuedPrompt = prompt
            connection.send(["type": "control_request", "request_id": initializationID,
                             "request": ["subtype": "initialize"]])
            instruction = ""; attachments.removeAll()
            Task { [self] in
                for await event in events {
                    guard transport === connection else { continue }
                    switch event {
                    case .line(let data): consume(data)
                    case .stderr(let text): error = String((error + text).suffix(16_000))
                    case .exit(let code):
                        if running {
                            if !receivedResult {
                                if error.isEmpty { error = "Claude exited without a final response (exit \(code)). You can send another instruction to resume." }
                                if instruction.isEmpty { instruction = pendingInstruction; attachments = pendingAttachments }
                            }
                            interrupted = !receivedResult || resultFailed
                        }
                        running = false; permissions.removeAll(); transport = nil
                        status = interrupted ? "Connection ended before completion" : "Disconnected · reconnects on the next instruction"
                        refreshChanges()
                    }
                }
            }
        } catch { running = false; self.error = error.localizedDescription; status = "Could not start Claude" }
    }
    @Published var reloading = false
    func reload() {
        guard !reloading, !loadingHistory else { return }
        reloading = true
        let draft = instruction
        let context = attachments
        if transport != nil { stop() }
        Task {
            for _ in 0..<80 {
                if transport == nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard transport == nil else { error = "The old connection is still closing. Try Reload again."; reloading = false; return }
            guard resume else { reloading = false; refreshChanges(); return }
            loadingHistory = true
            let project = project, id = sessionID
            let result = await Task.detached { BriefHistory.read(project, id: id) }.value
            switch result {
            case .success(let records):
                replies = records.filter { $0.incomplete != true }.map { BriefReply(instruction: $0.instruction, markdown: $0.markdown) }
                index = max(0, replies.count - 1)
                interrupted = records.last?.incomplete == true
                error = ""
                status = interrupted ? "Conversation ended before a final response" : "Ready for an instruction"
            case .failure(let failure): error = failure.localizedDescription
            }
            instruction = draft; attachments = context
            loadingHistory = false; reloading = false
            refreshChanges()
        }
    }
    func continueConversation() {
        guard canContinue else { return }
        let draft = instruction
        let context = attachments
        instruction = "Continue the last unfinished request in this conversation from where it stopped. First check what already completed, avoid repeating completed changes, and finish with a final response."
        attachments = []
        send()
        // Preserve a separately drafted instruction instead of silently replacing it.
        if !draft.isEmpty, draft != pendingInstruction {
            instruction = draft
            attachments = context
        }
    }

    func consume(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { return }
        switch type {
        case "control_response":
            if let response = event["response"] as? [String: Any], response["request_id"] as? String == initializationID {
                if response["subtype"] as? String == "error" {
                    error = response["error"] as? String ?? "Could not initialize Claude Code."
                    transport?.stop()
                } else if let prompt = queuedPrompt {
                    queuedPrompt = nil
                    transport?.send(["type": "user", "message": ["role": "user", "content": prompt]])
                }
            }
        case "control_cancel_request":
            if let id = event["request_id"] as? String { permissions.removeAll { $0.id == id } }
        case "system":
            if event["subtype"] as? String == "init" {
                if let id = event["session_id"] as? String { sessionID = id }
                resume = true; status = "Claude is working…"; log("Connected to Claude Code")
            } else if let subtype = event["subtype"] as? String { log(subtype.replacingOccurrences(of: "_", with: " ")) }
        case "assistant":
            finalResponse.observe(event)
            let message = event["message"] as? [String: Any]
            for block in message?["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                if let id = block["id"] as? String, !seenToolIDs.insert(id).inserted { continue }
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let detail = input["file_path"] as? String ?? input["command"] as? String ?? input["pattern"] as? String ?? ""
                status = name + (detail.isEmpty ? "" : ": " + String(detail.prefix(130)))
                log(status)
            }
        case "user":
            let message = event["message"] as? [String: Any]
            for block in message?["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                if block["is_error"] as? Bool == true { log("Tool reported an error") }
                status = "Reviewing tool results…"
            }
        case "control_request":
            guard let id = event["request_id"] as? String, let request = event["request"] as? [String: Any] else { return }
            if request["subtype"] as? String == "can_use_tool" {
                permissions.append(BriefPermission(id: id, tool: request["tool_name"] as? String ?? "Tool", input: request["input"] as? [String: Any] ?? [:]))
                status = "Waiting for tool approval"
            } else {
                transport?.send(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Unsupported debug client request"]])
            }
        case "result":
            guard event["parent_tool_use_id"] as? String == nil, event["isSidechain"] as? Bool != true else { return }
            receivedResult = true; resume = true
            if let id = event["session_id"] as? String { sessionID = id }
            resultFailed = event["is_error"] as? Bool == true || (event["subtype"] as? String)?.hasPrefix("error") == true
            if resultFailed {
                let details = (event["errors"] as? [String])?.joined(separator: "\n") ?? ""
                let result = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                error = !details.isEmpty ? details : !result.isEmpty ? result : "Claude ended this turn with an error."
                interrupted = true
            } else {
                interrupted = false
                let result = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let answer = result.isEmpty ? finalResponse.finalText(resultConfirmsCompletion: true) : result {
                    replies.append(BriefReply(instruction: pendingInstruction, markdown: answer))
                    hasUnreadReply = true
                    index = replies.count - 1
                    log("Final response received")
                } else {
                    error = "Claude completed this turn without a text response. No empty response was added. You can ask a follow-up."
                    log("Turn completed without a text response")
                }
            }
            running = false
            permissions.removeAll()
            status = interrupted ? "Request ended before completion" : "Ready for your next instruction"
            refreshChanges()
        default: break
        }
    }
    var pastActions: [String] {
        progress.last == status ? Array(progress.dropLast()) : progress
    }
    func markLatestRead() {
        if !replies.isEmpty, index == replies.count - 1 { hasUnreadReply = false }
    }
    func dismissError() { error = "" }
    func log(_ message: String) {
        guard progress.last != message else { return }
        progress.append(message)
        if progress.count > 150 { progress.removeFirst(progress.count - 150) }
    }
    func answer(_ permission: BriefPermission, allow: Bool) {
        let reply: [String: Any] = allow ? ["behavior": "allow", "updatedInput": permission.input] : ["behavior": "deny", "message": "The user declined this tool action."]
        transport?.send(["type": "control_response", "response": ["subtype": "success", "request_id": permission.id, "response": reply]])
        permissions.removeAll { $0.id == permission.id }; status = "Claude is working…"
        log((allow ? "Approved once: " : "Declined: ") + permission.tool)
    }
    func stop() {
        guard let transport else { return }
        status = "Closing connection…"
        transport.stop()
    }

    func refreshChanges() {
        guard !loadingChanges else { return }
        loadingChanges = true
        let project = project
        Task {
            let result = await Task.detached { BriefChanges.read(project) }.value
            loadingChanges = false
            switch result {
            case .success(let files): changes = files
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

/// Working tree and staged changes relative to HEAD, not attributed to Claude.
enum BriefChanges {
    static func read(_ project: Project) -> Result<[BriefChangedFile], Error> {
        let command = "cd " + Command.shellQuote(project.path) + " && python3 -c " + Command.shellQuote(script)
        let output = project.isRemote ? Command.ssh(project.host, command, maxOutput: 3_000_000) : Command.run("/bin/zsh", ["-c", command], timeout: 20, maxOutput: 3_000_000)
        guard output.2 == 0 else { return .failure(ResearchError.message(output.1.isEmpty ? "Could not read Git changes." : output.1)) }
        do { return .success(try JSONDecoder().decode([BriefChangedFile].self, from: Data(output.0.utf8))) }
        catch { return .failure(ResearchError.message("Could not decode Git changes: \(error.localizedDescription)")) }
    }
    static let script = #"""
import os, subprocess, json

def git(*args):
    return subprocess.run(['git', '--no-pager', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
r = git('status', '--porcelain=v1', '-z', '--untracked-files=all')
if r.returncode:
    raise RuntimeError(r.stderr.decode('utf-8', 'replace'))
root = os.path.realpath('.')
entries = r.stdout.split(b'\0')
result = []
i = 0
while i < len(entries) and len(result) < 80:
    raw = entries[i]; i += 1
    if not raw: continue
    status = raw[:2].decode('ascii', 'replace')
    path = os.fsdecode(raw[3:])
    if 'R' in status or 'C' in status: i += 1
    if status == '??':
        real = os.path.realpath(path)
        if os.path.commonpath([root, real]) != root or os.path.islink(path):
            text = 'Symlink target is not previewed.'
        elif os.path.isfile(real) and os.path.getsize(real) <= 120000:
            with open(real, 'rb') as f: data = f.read(120001)
            text = 'Binary file' if b'\0' in data else '\n'.join('+' + line for line in data.decode('utf-8', 'replace').splitlines())
        else: text = 'File is too large for this preview.'
    else:
        d = git('diff', '--no-ext-diff', '--no-textconv', '--no-renames', 'HEAD', '--', path)
        if d.returncode: d = git('diff', '--no-ext-diff', '--no-textconv', '--', path)
        text = d.stdout[:24000].decode('utf-8', 'replace')
        if len(d.stdout) > 24000: text += '\n[Diff truncated]'
    result.append(dict(path=path, status=status, diff=text))
print(json.dumps(result))
"""#
}

/// Complete Claude history for the selected machine/account, independent of the legacy top-40 menu.
enum BriefConversationHistory {
    static func read(_ project: Project) -> Result<[SavedAgentSession], Error> {
        let command = "python3 -c " + Command.shellQuote(script)
        let output = project.isRemote ? Command.ssh(project.host, command, maxOutput: 8_000_000) : Command.run("/bin/zsh", ["-c", command], timeout: 45, maxOutput: 8_000_000)
        guard output.2 == 0 else { return .failure(ResearchError.message("Could not load Claude conversations. " + output.1)) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .success(try decoder.decode([SavedAgentSession].self, from: Data(output.0.utf8)))
        } catch { return .failure(ResearchError.message("Conversation history could not be decoded. Try Refresh. " + error.localizedDescription)) }
    }
    static let script = #"""
import os, glob, json, uuid, datetime
root = os.path.join(os.environ.get('CLAUDE_CONFIG_DIR', os.path.expanduser('~/.claude')), 'projects')
found = {}
for folder in glob.glob(os.path.join(root, '*')):
    if not os.path.isdir(folder): continue
    indexed = {}
    try:
        with open(os.path.join(folder, 'sessions-index.json')) as f:
            for item in json.load(f).get('entries', []): indexed[item.get('sessionId')] = item
    except (OSError, ValueError, TypeError): pass
    for path in glob.glob(os.path.join(folder, '*.jsonl')):
        sid = os.path.basename(path)[:-6]
        try: uuid.UUID(sid)
        except ValueError: continue
        try:
            size = os.path.getsize(path)
            with open(path, 'rb') as f:
                head = f.read(65536)
                f.seek(max(0, size - 65536))
                tail = f.read(65536)
            metadata = indexed.get(sid, {})
            cwd = metadata.get('projectPath')
            title = metadata.get('customTitle') or metadata.get('summary')
            first_prompt = metadata.get('firstPrompt')
            for raw in (head + b'\n' + tail).splitlines():
                try: event = json.loads(raw)
                except (ValueError, UnicodeError): continue
                if not isinstance(event, dict) or event.get('isSidechain'): continue
                if isinstance(event.get('cwd'), str): cwd = event['cwd']
                if event.get('type') == 'custom-title' and event.get('customTitle'): title = event['customTitle']
                elif event.get('type') == 'ai-title' and not title: title = event.get('aiTitle')
                if not first_prompt and event.get('type') == 'user':
                    message = event.get('message', {})
                    content = message.get('content', []) if isinstance(message, dict) else []
                    if isinstance(content, str): first_prompt = content
                    elif isinstance(content, list):
                        first_prompt = ' '.join(b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text')
            stamp = datetime.datetime.fromtimestamp(os.path.getmtime(path), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            item = dict(agent='claude', id=sid, modified=stamp, workspace=cwd or os.path.basename(folder), name=str(title or first_prompt or '')[:180] or None)
            if sid not in found or found[sid]['modified'] < stamp: found[sid] = item
        except OSError: continue
print(json.dumps(sorted(found.values(), key=lambda x: x['modified'], reverse=True)))
"""#
}

enum BriefHistory {
    struct Record: Decodable, Sendable { let instruction: String; let markdown: String; let incomplete: Bool? }
    static func read(_ project: Project, id: String) -> Result<[Record], Error> {
        guard UUID(uuidString: id) != nil else { return .failure(ResearchError.message("Invalid saved session ID.")) }
        let command = "python3 -c " + Command.shellQuote(script) + " " + Command.shellQuote(id)
        let output = project.isRemote ? Command.ssh(project.host, command, maxOutput: 2_000_000) : Command.run("/bin/zsh", ["-c", command], maxOutput: 2_000_000)
        guard output.2 == 0 else { return .failure(ResearchError.message("Could not load saved responses. " + output.1)) }
        do { return .success(try JSONDecoder().decode([Record].self, from: Data(output.0.utf8))) }
        catch { return .failure(error) }
    }
    static let script = #"""
import os, glob, sys, json
root = os.path.join(os.environ.get('CLAUDE_CONFIG_DIR', os.path.expanduser('~/.claude')), 'projects')
files = glob.glob(os.path.join(root, '*', sys.argv[1] + '.jsonl'))
records = []
instruction = ''
current_id = None
parts = {}
has_tools = False
stop_reason = None
completion = False

def text_content(content):
    if isinstance(content, str): return content.strip()
    if not isinstance(content, list): return ''
    return '\n'.join(b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text').strip()

def flush():
    if not instruction: return
    text = '\n\n'.join(parts[k] for k in sorted(parts)).strip()
    confirmed = stop_reason in ('end_turn', 'stop_sequence') or (stop_reason is None and completion)
    if confirmed and not has_tools and text:
        records.append(dict(instruction=instruction[:100000], markdown=text[:150000]))
    elif not confirmed or has_tools:
        records.append(dict(instruction=instruction[:100000], markdown='', incomplete=True))

if not files: raise RuntimeError('Saved transcript is not available.')
f = max(files, key=os.path.getmtime)
with open(f, 'rb') as stream:
    start = max(0, os.path.getsize(f) - 8000000)
    stream.seek(start)
    data = stream.read(8000000)
    if start: data = data.partition(b'\n')[2]
for raw in data.splitlines():
    try: event = json.loads(raw)
    except (ValueError, UnicodeError): continue
    if not isinstance(event, dict): continue
    if event.get('isSidechain') or event.get('parent_tool_use_id'): continue
    if event.get('isMeta') and event.get('type') != 'system': continue
    if event.get('queueTranscriptOnly') or event.get('isCompactSummary'): continue
    message = event.get('message', {})
    if not isinstance(message, dict): message = {}
    content = message.get('content', [])
    if event.get('type') == 'user':
        if isinstance(content, list) and any(b.get('type') == 'tool_result' for b in content if isinstance(b, dict)): continue
        text = text_content(content)
        if not text or text.startswith('[Request interrupted by user'): continue
        flush()
        instruction = text
        current_id = None; parts = {}; has_tools = False; stop_reason = None; completion = False
    elif event.get('type') == 'assistant':
        mid = message.get('id') or event.get('uuid')
        if not mid: mid = 'anonymous-' + str(len(records))
        if mid != current_id:
            current_id = mid; parts = {}; has_tools = False; stop_reason = None; completion = False
        if event.get('isApiErrorMessage'):
            has_tools = True
            continue
        if message.get('stop_reason') is not None: stop_reason = message['stop_reason']
        blocks = content if isinstance(content, list) else []
        for index, block in enumerate(blocks):
            if not isinstance(block, dict): continue
            if block.get('type') == 'tool_use': has_tools = True
            if block.get('type') == 'text': parts[event.get('apiBlockIndex', 0) + index] = block.get('text', '')
    elif event.get('type') == 'result':
        if not event.get('is_error') and not str(event.get('subtype', '')).startswith('error'):
            result = str(event.get('result') or '').strip()
            if result: parts = {0: result}; has_tools = False; stop_reason = 'end_turn'
            completion = True
flush()
print(json.dumps(records[-40:]))
"""#
}

struct BriefSidebarActivity: View {
    let project: Project
    var legacyRunning = false
    @ObservedObject private var store = BriefAgentStore.shared
    var body: some View {
        switch store.activity(for: project) {
        case .running:
            Circle().fill(DeskStyle.running).frame(width: 5, height: 5).help("Agent is working")
                .accessibilityLabel("Agent is working")
        case .unread:
            if legacyRunning {
                Circle().fill(DeskStyle.running).frame(width: 5, height: 5).help("Agent is working")
            } else {
                Circle().fill(Color.blue).frame(width: 5, height: 5).help("New response ready to review")
                    .accessibilityLabel("New response ready to review")
            }
        case .idle:
            if legacyRunning { Circle().fill(DeskStyle.running).frame(width: 5, height: 5).help("Agent is working") }
        }
    }
}

struct BriefAgentPane: View {
    let project: Project
    @ObservedObject var model: DeskModel
    @ObservedObject private var store = BriefAgentStore.shared
    @State private var selected: BriefAgentModel?
    @State private var search = ""
    @State private var currentWorkspaceOnly = false
    @State private var restoredSelection = false
    private func matches(_ chat: SavedAgentSession) -> Bool {
        (!currentWorkspaceOnly || chat.belongs(to: project)) && (search.isEmpty || (chat.title + " " + (chat.workspace ?? "") + " " + chat.id).localizedCaseInsensitiveContains(search))
    }
    var body: some View {
        Group {
            if let selected {
                BriefAgentView(session: selected, model: model, goBack: {
                    self.selected = nil
                    store.discover(project)
                }).id(selected.id)
                    .onDisappear { store.remember(selected, for: project) }
            } else {
                overview
            }
        }.task {
            store.discover(project)
            if !restoredSelection { restoredSelection = true; selected = store.restore(for: project) }
        }
        .onChange(of: selected?.id) { _, _ in if let selected { store.remember(selected, for: project) } }
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        DeskEyebrow(title: "Agent workspace")
                        Text("Conversations").font(.system(size: 25, weight: .light))
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { store.discover(project) }.disabled(store.loadingHosts.contains(project.host))
                    Button("New conversation", systemImage: "plus") { selected = store.create(for: project) }
                        .buttonStyle(DeskButtonStyle(prominent: true))
                }.buttonStyle(DeskButtonStyle())
                HStack {
                    TextField("Search conversations, folders, or session IDs", text: $search).textFieldStyle(DeskFieldStyle())
                    Toggle("This workspace only", isOn: $currentWorkspaceOnly).toggleStyle(.checkbox).font(.caption)
                }
                let allSaved = store.savedChats[project.host] ?? []
                Text("Claude Code · \(project.isRemote ? project.host : "This Mac") · \(allSaved.count) saved conversations")
                    .font(.caption).foregroundStyle(DeskStyle.muted)
                if !store.discoveryError.isEmpty {
                    HStack(alignment: .top) {
                        Text(store.discoveryError).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                        Button { store.discoveryError = "" } label: { Image(systemName: "xmark") }.buttonStyle(DeskButtonStyle(compact: true))
                    }
                }
                ForEach(store.chats(for: project).filter { chat in
                    (!currentWorkspaceOnly || chat.project.path == project.path) && (search.isEmpty || (chat.title + " " + chat.project.path).localizedCaseInsensitiveContains(search))
                }, id: \.id) { chat in
                    BriefChatRow(chat: chat) { selected = chat }
                }
                let openIDs = Set(store.chats(for: project).map(\.sessionID))
                let saved = allSaved.filter { matches($0) && !openIDs.contains($0.id) }
                if !saved.isEmpty {
                    Text("Saved conversations").font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                    ForEach(saved) { chat in
                        Button {
                            if chat.workspace?.hasPrefix("/") == true || chat.belongs(to: project) {
                                selected = store.open(chat, project: project)
                            } else {
                                store.discoveryError = "The original directory for this conversation could not be resolved. Open its workspace first, then select this chat."
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(chat.title).font(.system(size: 12))
                                    Text(chat.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(DeskStyle.muted)
                                    Text(chat.workspace ?? "Unknown working directory").font(.caption.monospaced()).foregroundStyle(DeskStyle.muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(8)
                        }.buttonStyle(DeskButtonStyle())
                    }
                }
                if saved.isEmpty && store.chats(for: project).isEmpty {
                    Text(store.loadingHosts.contains(project.host) ? "Loading conversations…" : "No conversations match this filter. Clear search or turn off This workspace only.")
                        .font(.system(size: 12)).foregroundStyle(DeskStyle.muted).padding(.vertical, 20)
                }
            }.padding(26)
        }.background(DeskStyle.background)
    }
}

private struct BriefChatRow: View {
    @ObservedObject var chat: BriefAgentModel
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Circle().fill(chat.running ? DeskStyle.running : chat.hasUnreadReply ? Color.blue : DeskStyle.muted).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(chat.title).font(.system(size: 12))
                    Text(chat.interrupted ? "Interrupted · continue available" : chat.running ? chat.status : "\(chat.replies.count) final responses")
                        .font(.caption).foregroundStyle(DeskStyle.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }.padding(8)
        }.buttonStyle(DeskButtonStyle())
    }
}

struct BriefAgentView: View {
    @ObservedObject var session: BriefAgentModel
    @ObservedObject var model: DeskModel
    let goBack: () -> Void
    @StateObject private var dictation = ConsoleDictation()
    @FocusState private var instructionFocused: Bool
    @State private var inspector = 0
    @State private var fileID: String?
    @State private var selected: Set<Int> = []
    @State private var anchor: Int?
    @State private var historyExpanded = false
    @State private var inputWidth: CGFloat = 400
    @State private var responseVisible = false
    private var file: BriefChangedFile? { session.changes.first { $0.id == fileID } ?? session.changes.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: goBack) { Label("Conversations", systemImage: "chevron.left") }
                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    .help(session.project.path)
                Spacer(minLength: 8)
                Button("Continue conversation", systemImage: "play") { session.continueConversation() }
                    .disabled(!session.canContinue || session.reloading)
            }.buttonStyle(DeskButtonStyle()).padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if model.sessions[session.project.id]?.ended == false {
                Text("An existing terminal agent is still running in this workspace. Stop it in the standard app before sending here.")
                    .font(.caption).foregroundStyle(.orange).padding(10)
            }
            HSplitView {
                VStack(spacing: 0) {
                    responseNavigation
                    if let reply = session.current {
                        Text(reply.instruction).font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        MarkdownPreview(source: reply.markdown, rendersTables: true).id(reply.id)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(session.interrupted ? "This conversation was interrupted." : "Give Claude a direction.").font(.system(size: 24, weight: .light))
                            Text("Final responses appear here. Tool activity and approval requests stay in Progress. Use Continue to finish an interrupted request, or write a new instruction below.")
                                .font(.system(size: 12)).foregroundStyle(DeskStyle.muted).lineSpacing(5)
                            if !session.sessionID.isEmpty { Text("Session \(session.sessionID.prefix(8))").font(.caption.monospaced()).foregroundStyle(DeskStyle.muted) }
                        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    composer
                }.frame(minWidth: 240, idealWidth: 600, maxWidth: .infinity)
                inspectorPane.frame(minWidth: 190, idealWidth: 300, maxWidth: .infinity)
            }
        }
        .background(DeskStyle.background)
        .task { session.refreshChanges(); model.refreshHistory(session.project) }
        .onChange(of: fileID) { _, _ in selected.removeAll(); anchor = nil }
        .onChange(of: session.changes.map(\.diff)) { _, _ in selected.removeAll(); anchor = nil }
        .onAppear { responseVisible = true; markViewedResponse() }
        .onDisappear { responseVisible = false; dictation.cancel() }
        .onChange(of: session.replies.count) { _, _ in markViewedResponse() }
        .onChange(of: session.index) { _, _ in markViewedResponse() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in markViewedResponse() }
        .onChange(of: session.running) { _, running in
            if running { historyExpanded = false; dictation.cancel() }
        }
        .onChange(of: session.permissions.count) { _, count in if count > 0 { inspector = 0 } }
    }

    private func markViewedResponse() {
        if responseVisible && NSApp.isActive { session.markLatestRead() }
    }
    private var responseNavigation: some View {
        HStack {
            Text("Final response").font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
            Button { dictation.cancel(); session.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload this conversation and reconnect after a dropped connection")
                .accessibilityLabel("Reload conversation").disabled(session.reloading || session.loadingHistory)
            Spacer(minLength: 4)
            if session.index < session.replies.count - 1 {
                Button("Latest") { session.index = session.replies.count - 1 }
            }
            Button { session.index -= 1 } label: { Image(systemName: "arrow.left") }.disabled(session.index == 0)
            Text(session.replies.isEmpty ? "0 / 0" : "\(session.index + 1) / \(session.replies.count)").font(.caption.monospaced())
            Button { session.index += 1 } label: { Image(systemName: "arrow.right") }.disabled(session.index >= session.replies.count - 1)
        }.buttonStyle(DeskButtonStyle(compact: true)).padding(14)
    }
    private var inputHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let bounds = (session.instruction + "\n").boundingRect(
            with: NSSize(width: max(100, inputWidth - 24), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(180, max(28, ceil(bounds.height) + 12))
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !session.error.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ScrollView { Text(session.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 85)
                    Button { session.dismissError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(DeskButtonStyle(compact: true)).help("Dismiss error").accessibilityLabel("Dismiss error")
                }
            }
            ForEach(session.attachments) { attachment in
                HStack {
                    Text(attachment.label).font(.caption.monospaced()).lineLimit(1)
                    Spacer()
                    Button { session.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(7).background(DeskStyle.raised, in: RoundedRectangle(cornerRadius: 5))
            }
            if !dictation.status.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text(dictation.status).font(.caption).foregroundStyle(DeskStyle.muted)
                    Spacer()
                    Button { dictation.cancel() } label: { Image(systemName: "xmark") }
                        .buttonStyle(DeskButtonStyle(compact: true)).help("Cancel dictation").accessibilityLabel("Cancel dictation")
                }
            }
            TextEditor(text: $session.instruction).font(.system(size: 12)).scrollContentBackground(.hidden)
                .focused($instructionFocused)
                .frame(height: inputHeight).padding(6)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { inputWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in inputWidth = width }
                })
                .background(DeskStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DeskStyle.edge))
                .accessibilityLabel("Instruction to Claude Code")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    dictation.toggle { text in
                        let separator = session.instruction.isEmpty || session.instruction.last?.isWhitespace == true ? "" : " "
                        session.instruction += separator + text
                        instructionFocused = true
                    }
                } label: {
                    Label(dictation.recording ? "Stop dictation" : "Dictate",
                          systemImage: dictation.recording ? "stop.circle.fill" : "mic")
                }
                .buttonStyle(DeskButtonStyle(prominent: dictation.recording))
                .disabled(dictation.busy || session.loadingHistory)
                .help("Transcribe on this Mac and add to your draft without sending")
                Button("Send instruction", systemImage: "arrow.up") { session.send() }
                    .buttonStyle(DeskButtonStyle(prominent: true))
                    .disabled(session.running || session.reloading || session.loadingHistory || dictation.recording || dictation.busy || session.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sessions[session.project.id]?.ended == false)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(16).background { DeskMetalSurface() }
    }
    private var inspectorPane: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Button("Progress") { inspector = 0 }.buttonStyle(DeskButtonStyle(prominent: inspector == 0))
                Button("Changes (\(session.changes.count))") { inspector = 1 }.buttonStyle(DeskButtonStyle(prominent: inspector == 1))
                Spacer(minLength: 0)
            }
            if inspector == 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            Text(session.status).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 2)
                            if session.running { Button("Stop") { session.stop() }.buttonStyle(DeskButtonStyle(compact: true)) }
                        }
                        ForEach(session.permissions) { permission in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Allow \(permission.tool)?").font(.system(size: 12, weight: .medium))
                                Text(permission.detail).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                HStack {
                                    Button("Decline") { session.answer(permission, allow: false) }
                                    Button("Allow once") { session.answer(permission, allow: true) }
                                }.buttonStyle(DeskButtonStyle())
                            }.padding(12).background(DeskStyle.raised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        if !session.pastActions.isEmpty {
                            DisclosureGroup("Past actions (\(session.pastActions.count))", isExpanded: $historyExpanded) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(session.pastActions.enumerated()), id: \.offset) { _, text in
                                        Text(text).font(.system(size: 11)).foregroundStyle(DeskStyle.muted).textSelection(.enabled)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                            }.font(.system(size: 11)).foregroundStyle(DeskStyle.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack {
                    Text("Working tree + staged").font(.system(size: 10)).foregroundStyle(DeskStyle.muted)
                    Spacer()
                    Button { session.refreshChanges() } label: { Image(systemName: "arrow.clockwise") }.disabled(session.loadingChanges)
                }.buttonStyle(DeskButtonStyle(compact: true))
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(session.changes) { changed in
                                Button {
                                    fileID = changed.id
                                    DispatchQueue.main.async {
                                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("brief-code-preview", anchor: .top) }
                                    }
                                } label: {
                                    HStack { Text(changed.path).lineLimit(2); Spacer(); Text(changed.status).font(.caption.monospaced()) }
                                }.buttonStyle(DeskButtonStyle(prominent: changed.id == file?.id))
                            }
                            if let file {
                                codePreview(file).id("brief-code-preview")
                            } else { Text("No Git changes.").foregroundStyle(DeskStyle.muted).font(.caption) }
                        }
                    }
                }
                Button("Attach selected lines (\(selected.count))") { attach() }.buttonStyle(DeskButtonStyle()).disabled(selected.isEmpty)
                Text("Includes existing edits, up to 80 files. Large diffs are truncated. Changes are not necessarily made by Claude.").font(.system(size: 9)).foregroundStyle(DeskStyle.muted)
            }
        }.padding(16).background(DeskStyle.surface)
    }
    private func codePreview(_ file: BriefChangedFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(file.path).font(.caption.monospaced()).textSelection(.enabled).padding(12)
            Divider()
            Text("Click lines; shift-click selects a range.").font(.system(size: 10)).foregroundStyle(DeskStyle.muted).padding(10)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.diff.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                        Button { select(index) } label: {
                            Text(line.isEmpty ? " " : line).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("+") ? DeskStyle.running : DeskStyle.accent)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).padding(.horizontal, 10)
                                .background(selected.contains(index) ? DeskStyle.raised : .clear)
                        }.buttonStyle(.plain)
                    }
                }.padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeskStyle.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeskStyle.edge))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func select(_ index: Int) {
        if NSEvent.modifierFlags.contains(.shift), let anchor {
            selected.formUnion(min(anchor, index)...max(anchor, index))
        } else {
            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
            anchor = index
        }
    }
    private func attach() {
        guard let file, !selected.isEmpty else { return }
        let lines = file.diff.components(separatedBy: "\n")
        let chosen = selected.sorted().filter { lines.indices.contains($0) }
        session.attachments.append(BriefAttachment(label: file.path + " · \(chosen.count) diff lines", text: chosen.map { lines[$0] }.joined(separator: "\n")))
        selected.removeAll()
    }
}
#endif
