import Foundation

struct ChatContextUsage: Equatable {
    var tokens: Int?
    var limit: Int?
    var warningThreshold: Int { limit.map { max(1, $0 * 3 / 4) } ?? 150_000 }
    var isLarge: Bool { (tokens ?? 0) >= warningThreshold }
    mutating func observe(_ event: [String: Any]) {
        guard event["parent_tool_use_id"] as? String == nil, event["isSidechain"] as? Bool != true else { return }
        if event["type"] as? String == "system", event["subtype"] as? String == "compact_boundary" { tokens = nil }
        if event["type"] as? String == "assistant", let message = event["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any], usage["input_tokens"] != nil {
            tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                .reduce(0) { $0 + max(0, (usage[$1] as? NSNumber)?.intValue ?? 0) }
        }
        if let models = event["modelUsage"] as? [String: [String: Any]] {
            let active = event["model"] as? String
            let values = active.flatMap { models[$0] }.map { [$0] } ?? Array(models.values)
            if let reported = values.compactMap({ ($0["contextWindow"] as? NSNumber)?.intValue }).filter({ $0 > 0 }).min() { limit = reported }
        }
    }
    var label: String {
        guard let tokens else { return "Context: awaiting token count" }
        let count = tokens.formatted()
        return "Context: " + count + (limit.map { " / " + $0.formatted() } ?? "") + " tokens"
    }
    static func handoff(from chatID: String, project: Project, draft: String) -> String {
        "Continue from Claude Code conversation \(chatID).\nWorkspace: \(project.path)\(project.isRemote ? " on " + project.host : " on this Mac").\nRecover the relevant goals, decisions, and next steps from that session's saved transcript (<CLAUDE_CONFIG_DIR or ~/.claude>/projects/*/\(chatID).jsonl). Read only the relevant portions and summarize what you need; keep this new chat's context concise. If the transcript is unavailable, ask me for the missing context.\n\nNew instructions:\n" + draft
    }
}
