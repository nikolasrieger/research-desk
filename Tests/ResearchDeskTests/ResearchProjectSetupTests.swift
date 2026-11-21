import XCTest
@testable import ResearchDesk

final class ResearchProjectSetupTests: XCTestCase {
    func testCreatesEmptyFolderAndRefusesExistingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try ResearchProjectSetup.create(folder: "idea with spaces", parent: root.path, host: "")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path), [])
        XCTAssertThrowsError(try ResearchProjectSetup.create(folder: "idea with spaces", parent: root.path, host: ""))
    }
    func testExistingIdeasDecodeWithoutChecklistFields() throws {
        let data = Data(#"[{"id":"C1000000-0000-0000-0000-000000000001","title":"Idea","note":"Notes","host":"","parent":"/tmp","folder":"idea"}]"#.utf8)
        var ideas = try JSONDecoder().decode([ResearchIdea].self, from: data)
        XCTAssertEqual(ideas.first?.note, "Notes")
        XCTAssertNil(ideas.first?.completed)
        ideas[0].completed = true
        ideas[0].projectID = UUID()
        let restored = try JSONDecoder().decode([ResearchIdea].self, from: JSONEncoder().encode(ideas))
        XCTAssertEqual(restored[0].completed, true)
        XCTAssertEqual(restored[0].projectID, ideas[0].projectID)
    }
    func testRejectsTraversalAndRelativeParent() {
        for folder in ["", ".", "..", "../escape", "a/b"] {
            XCTAssertThrowsError(try ResearchProjectSetup.validate(folder: folder, parent: "/tmp"))
        }
        XCTAssertThrowsError(try ResearchProjectSetup.validate(folder: "idea", parent: "relative"))
    }
}
