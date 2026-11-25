import XCTest
@testable import ResearchDesk

final class HistoryConnectionTests: XCTestCase {
    @MainActor
    func testFailedHistoryLoadIsNotPresentedAsAnEmptyNewChat() async throws {
        let project = Project(name: "Missing transcript fixture", path: "/")
        let model = BriefAgentModel(project: project)
        model.useSession(SavedAgentSession(agent: "claude", id: UUID().uuidString, modified: Date(), workspace: project.path))
        for _ in 0..<100 {
            if !model.loadingHistory { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.loadingHistory)
        XCTAssertTrue(model.historyLoadFailed)
        XCTAssertTrue(model.hasStoredSession)
        XCTAssertEqual(model.status, "Could not load saved messages")
        model.newConversation()
        XCTAssertFalse(model.historyLoadFailed)
    }
    func testConfiguredRemoteHistoryDecodes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["RD_HISTORY_HOST"], let id = environment["RD_HISTORY_ID"] else {
            throw XCTSkip("Set RD_HISTORY_HOST and RD_HISTORY_ID for the optional remote history check.")
        }
        let project = Project(name: "History diagnostic", path: "/", host: host)
        switch BriefHistory.read(project, id: id) {
        case .success(let records):
            print("Decoded saved responses:", records.filter { $0.incomplete != true }.count)
            XCTAssertFalse(records.filter { $0.incomplete != true }.isEmpty)
        case .failure(let error): XCTFail(error.localizedDescription)
        }
    }
}
