import XCTest
@testable import ResearchDesk

final class FileGitStatusTests: XCTestCase {
    func testUncommittedFilesAndDirectoriesIncludingRenamesAndSubprojects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        func git(_ arguments: String...) { XCTAssertEqual(Command.run("/usr/bin/git", ["-C", root.path] + arguments).2, 0) }
        func write(_ name: String, _ content: String) throws { try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        git("init", "-q")
        for file in ["clean.txt", "staged.txt", "old.txt", "nested/changed.txt"] { try write(file, "before\n") }
        git("add", ".")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Initial")
        try write("staged.txt", "staged\n"); git("add", "staged.txt")
        git("mv", "old.txt", "renamed.txt")
        try write("nested/changed.txt", "after\n")
        try write("new 'file.txt", "new\n")
        let project = Project(name: "Root", path: root.path)
        let changes = FileBrowserIO.uncommittedPaths(project)
        for name in ["staged.txt", "old.txt", "renamed.txt", "nested/changed.txt", "new 'file.txt"] {
            XCTAssertTrue(changes.contains(root.appendingPathComponent(name).path), name)
        }
        XCTAssertFalse(changes.contains(root.appendingPathComponent("clean.txt").path))
        XCTAssertTrue(FileBrowserIO.isUncommitted(nested.path, directory: true, changes: changes))
        XCTAssertFalse(FileBrowserIO.isUncommitted(nested.path + "-other", directory: true, changes: changes))
        let subchanges = FileBrowserIO.uncommittedPaths(Project(name: "Nested", path: nested.path))
        XCTAssertEqual(subchanges, [nested.appendingPathComponent("changed.txt").path])
    }
}
