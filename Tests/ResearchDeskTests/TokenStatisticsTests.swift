import XCTest
import SwiftUI
@testable import ResearchDesk

final class TokenStatisticsTests: XCTestCase {
    func testTranscriptUsageDeduplicatesAndSeparatesProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude/projects/test")
        let codex = root.appendingPathComponent("codex/sessions/2026/11/27")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        func write(_ events: [[String: Any]], _ url: URL) throws {
            let data = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
            try data.write(to: url, atomically: true, encoding: .utf8)
        }
        func message(_ output: Int) -> [String: Any] {
            ["type": "assistant", "cwd": "/project-a", "timestamp": "2026-11-27T12:00:00Z", "sessionId": "one",
             "message": ["id": "message", "usage": ["input_tokens": 10, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 30, "output_tokens": output]]]
        }
        try write([message(0), message(5), message(5)], claude.appendingPathComponent("one.jsonl"))
        func usage(_ total: Int) -> [String: Any] {
            ["type": "event_msg", "timestamp": "2026-11-27T12:00:00Z", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total]]]]
        }
        try write([["type": "session_meta", "payload": ["cwd": "/project-b"]], usage(100), usage(100), usage(150)], codex.appendingPathComponent("one.jsonl"))
        let command = "TZ=UTC CLAUDE_CONFIG_DIR=" + Command.shellQuote(root.appendingPathComponent("claude").path)
            + " CODEX_HOME=" + Command.shellQuote(root.appendingPathComponent("codex").path)
            + " python3 -c " + Command.shellQuote(TokenStatistics.script)
        let result = Command.run("/bin/zsh", ["-c", command])
        XCTAssertEqual(result.2, 0, result.1)
        let values = try JSONDecoder().decode([String: [String: Int64]].self, from: Data(result.0.utf8))
        XCTAssertEqual(values["/project-a"]?["2026-11-27"], 65)
        XCTAssertEqual(values["/project-b"]?["2026-11-27"], 150)
    }
    func testProjectReorderBothDirectionsAndPersistenceEncoding() throws {
        let projects = [Project(name: "A", path: "/a"), Project(name: "B", path: "/b"), Project(name: "C", path: "/c")]
        let moved = try XCTUnwrap(WorkspaceStorage.reordering(projects, moving: projects[0].id, to: projects[2].id, after: true))
        XCTAssertEqual(moved.map(\.name), ["B", "C", "A"])
        let restored = try JSONDecoder().decode([Project].self, from: JSONEncoder().encode(moved))
        XCTAssertEqual(restored.map(\.id), moved.map(\.id))
        XCTAssertEqual(WorkspaceStorage.reordering(moved, moving: projects[0].id, to: projects[1].id, after: false)?.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(WorkspaceStorage.reordering(projects, moving: projects[0].id, to: projects[2].id, after: false)?.map(\.name), ["B", "A", "C"])
        XCTAssertEqual(WorkspaceStorage.reordering(projects, moving: projects[2].id, to: projects[0].id, after: true)?.map(\.name), ["A", "C", "B"])
        XCTAssertNil(WorkspaceStorage.reordering(projects, moving: UUID(), to: projects[0].id, after: true))
        XCTAssertNil(WorkspaceStorage.reordering(projects, moving: projects[0].id, to: projects[0].id, after: true))
    }
    @MainActor
    func testTokenTotalsReplaceOnRefreshAndPersistByProjectAndYear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("stats.json")
        let store = StatisticsStore(url: url)
        let a = Project(name: "A", path: "/a"), b = Project(name: "B", path: "/b", host: "remote")
        let nested = Project(name: "Nested", path: "/a/nested")
        store.register([a, b, nested])
        store.ingestTokens(["/a": ["2026-11-27": 100, "2025-01-01": 50]], host: "")
        store.ingestTokens(["/b": ["2026-11-27": 200]], host: "remote")
        store.ingestTokens(["/a": ["2026-11-27": 120, "2025-01-01": 50], "/a/sub": ["2026-11-27": 5], "/a/nested/sub": ["2026-11-27": 7]], host: "")
        XCTAssertEqual(store.tokens(year: 2026, project: nil), 332)
        XCTAssertEqual(store.tokens(year: 2025, project: nil), 50)
        XCTAssertEqual(store.tokens(year: 2026, project: StatisticsProject(a).id), 125)
        let days = store.days(year: 2026, project: nil)
        XCTAssertEqual(days.reduce(0) { $0 + $1.tokens }, 332)
        XCTAssertEqual(days.first(where: { $0.id == "2026-11-27" })?.tokens, 332)
        XCTAssertEqual(store.days(year: 2026, project: StatisticsProject(a).id).reduce(0) { $0 + $1.tokens }, 125)
        XCTAssertEqual(store.days(year: 2025, project: nil).reduce(0) { $0 + $1.tokens }, 50)
        store.finish()
        XCTAssertEqual(StatisticsStore(url: url).tokens(year: 2026, project: nil), 332)
        let legacy = Data(#"{"projects":{},"selectedSeconds":{},"jobs":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(StatisticsState.self, from: legacy).tokenDays)
    }
}
