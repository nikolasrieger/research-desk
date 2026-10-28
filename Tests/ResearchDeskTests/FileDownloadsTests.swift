import XCTest
@testable import ResearchDesk

final class FileDownloadsTests: XCTestCase {
    func testRemotePreviewFollowsWorkspaceSymlinksAndRejectsUnrelatedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let nested = project.appendingPathComponent("plots/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let png = nested.appendingPathComponent("plot 'one.png")
        let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        try bytes.write(to: png)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        func preview(_ base: String, _ path: String) -> (String, String, Int32) {
            Command.run("/usr/bin/python3", ["-c", FileBrowserIO.remotePreviewScript, base, path])
        }
        let normal = preview(project.path, png.path)
        XCTAssertEqual(normal.2, 0, normal.1)
        XCTAssertEqual(Data(base64Encoded: normal.0), bytes)
        let aliased = preview(alias.path, alias.appendingPathComponent("plots/nested/plot 'one.png").path)
        XCTAssertEqual(aliased.2, 0, aliased.1)
        XCTAssertEqual(Data(base64Encoded: aliased.0), bytes)
        let outside = root.appendingPathComponent("outside.png")
        try bytes.write(to: outside)
        let link = nested.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linked = preview(project.path, link.path)
        XCTAssertEqual(linked.2, 0, linked.1)
        XCTAssertEqual(Data(base64Encoded: linked.0), bytes)
        for path in [outside.path, project.appendingPathComponent("../outside.png").path] {
            let rejected = preview(project.path, path)
            XCTAssertNotEqual(rejected.2, 0)
            XCTAssertTrue(rejected.1.contains("File path is outside this project"))
            XCTAssertFalse(rejected.1.contains("Traceback"))
        }
    }

    func testDownloadsPreserveBytesAndExistingFilesBeyondPreviewLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project")
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("a 'movie.mp4")
        let bytes = Data(repeating: 0x9a, count: 15_000_001)
        try bytes.write(to: file)
        let project = Project(name: "Test", path: source.path)
        let first = try FileBrowserIO.download(project, path: file.path, directory: downloads)
        let second = try FileBrowserIO.download(project, path: file.path, directory: downloads)
        XCTAssertEqual(first.lastPathComponent, "a 'movie.mp4")
        XCTAssertEqual(second.lastPathComponent, "a 'movie (1).mp4")
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try Data(contentsOf: second), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).count, 2)
    }

    func testLocalWorkspaceFollowsLinkedArtifactFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project")
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        let link = source.appendingPathComponent("artifacts")
        let storage = root.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data("plot".utf8).write(to: storage.appendingPathComponent("plot.png"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: storage)
        let project = Project(name: "Test", path: source.path)
        let listing = FileBrowserIO.listing(project, path: link.path)
        XCTAssertEqual(listing.0?.path, link.path, listing.1)
        XCTAssertEqual(listing.0?.entries.first?.name, "plot.png")
        let path = link.appendingPathComponent("plot.png").path
        XCTAssertEqual(Command.fileData(project, path: path).0, Data("plot".utf8))
        let downloaded = try FileBrowserIO.download(project, path: path, directory: downloads)
        XCTAssertEqual(try Data(contentsOf: downloaded), Data("plot".utf8))
        XCTAssertThrowsError(try FileBrowserIO.download(project, path: outside.path, directory: downloads))
        XCTAssertNil(Command.fileData(project, path: outside.path).0)
        XCTAssertNil(FileBrowserIO.listing(project, path: storage.path).0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["plot.png"])
    }

    func testMoviePreviewLimitAndTemporaryFileCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("clip.MP4")
        try Data(repeating: 1, count: 20).write(to: source)
        XCTAssertTrue(FilePreview.isMovie(source.lastPathComponent))
        XCTAssertFalse(FilePreview.isMovie("image.gif"))
        XCTAssertThrowsError(try FileBrowserIO.copyFile(Project(name: "Test", path: root.path), path: source.path, to: root.appendingPathComponent("copy.mp4"), limit: 10))
        let folder = root.appendingPathComponent("preview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var media: MediaPreviewFile? = MediaPreviewFile(url: folder.appendingPathComponent("clip.mp4"))
        try Data([1]).write(to: media!.url)
        media = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
