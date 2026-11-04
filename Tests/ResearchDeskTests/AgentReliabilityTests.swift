import XCTest
@testable import ResearchDesk

final class AgentReliabilityTests: XCTestCase {
    @MainActor
    func testProjectUnreadPersistsAndCanBeCleared() throws {
        let name = "ResearchDeskTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let project = Project(name: "Test", path: "/tmp/unread-test")
        let first = BriefAgentStore(defaults: defaults)
        first.mark(project, unread: true)
        XCTAssertEqual(BriefAgentStore(defaults: defaults).activity(for: project), .unread)
        first.mark(project, unread: false)
        XCTAssertEqual(BriefAgentStore(defaults: defaults).activity(for: project), .idle)
        let chat = first.session(for: project)
        chat.consume(try JSONSerialization.data(withJSONObject: ["type": "result", "result": "Done"]))
        XCTAssertEqual(BriefAgentStore(defaults: defaults).activity(for: project), .unread)
        chat.markLatestRead()
        XCTAssertEqual(BriefAgentStore(defaults: defaults).activity(for: project), .idle)
    }
    @MainActor
    func testUsageFailureIsNotOverwrittenByGitRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "No repository", path: root.path)
        let changes = try BriefChanges.read(project).get()
        XCTAssertTrue(changes.isEmpty)
        let chat = BriefAgentModel(project: project)
        chat.consume(try JSONSerialization.data(withJSONObject: ["type": "assistant", "error": "rate_limit", "message": ["content": [["type": "text", "text": "You've hit your limit · resets 3pm"]]]]))
        chat.consume(try JSONSerialization.data(withJSONObject: ["type": "result", "is_error": true]))
        while chat.loadingChanges { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(chat.error, "You've hit your limit · resets 3pm")
        XCTAssertEqual(chat.status, chat.error)
        XCTAssertTrue(chat.changesError.isEmpty)
    }
}
