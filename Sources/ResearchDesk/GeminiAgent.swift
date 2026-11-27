import Foundation
import CryptoKit

enum GeminiACP {
    static func agentLabel(_ agent: String) -> String {
        agent == "gemini" ? "Gemini CLI" : agent == "codex" ? "Codex" : "Claude Code"
    }
    static func request(_ method: String, id: String, params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "method": method, "id": id, "params": params]
    }
    static var initialize: [String: Any] {
        request("initialize", id: "gemini-init", params: ["protocolVersion": 1,
            "clientInfo": ["name": "research-desk", "version": "1.0"],
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]])
    }
}

/// App-owned transcripts preserve visible history across providers.
/// The actual CLI session remains on the selected local or SSH machine.
enum AgentTranscriptStore {
    struct Snapshot: Codable {
        let host: String
        let session: SavedAgentSession
        let records: [BriefHistory.Record]
        var handoff: String? = nil
    }
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResearchDesk/GeminiConversations", isDirectory: true)
    }
    private static func file(host: String, id: String, agent: String, root: URL) -> URL {
        let key = SHA256.hash(data: Data((host + "\n" + (agent == "gemini" ? "" : agent + "\n") + id).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key + ".json")
    }
    static func save(_ project: Project, id: String, title: String, records: [BriefHistory.Record], agent: String = "gemini", handoff: String? = nil, root: URL = root) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = Snapshot(host: project.host,
            session: SavedAgentSession(agent: agent, id: id, modified: Date(), workspace: project.path, name: title), records: records, handoff: handoff)
        let data = try JSONEncoder().encode(snapshot)
        let url = file(host: project.host, id: id, agent: agent, root: root)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read(_ project: Project, id: String, agent: String = "gemini", root: URL = root) -> Result<[BriefHistory.Record], Error> {
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file(host: project.host, id: id, agent: agent, root: root)))
            guard snapshot.host == project.host, snapshot.session.workspace == project.path else {
                throw ResearchError.message("This conversation belongs to another workspace.")
            }
            return .success(snapshot.records)
        } catch { return .failure(error) }
    }
    static func snapshot(_ project: Project, id: String, agent: String, root: URL = root) -> Snapshot? {
        guard let data = try? Data(contentsOf: file(host: project.host, id: id, agent: agent, root: root)),
              let value = try? JSONDecoder().decode(Snapshot.self, from: data),
              value.host == project.host, value.session.workspace == project.path else { return nil }
        return value
    }
    static func discover(host: String, root: URL = root) -> [SavedAgentSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.host == host else { return nil }
            return snapshot.session
        }
    }
}

// Retain the original name for existing Gemini callers and stored transcripts.
typealias GeminiTranscriptStore = AgentTranscriptStore
