import XCTest
@testable import ResearchDesk

final class FileDownloadsTests: XCTestCase {
    func testRemotePreviewPathsAndSymlinkDiagnostics() throws {
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
        let rejected = preview(project.path, link.path)
        XCTAssertNotEqual(rejected.2, 0)
        XCTAssertTrue(rejected.1.contains("Requested file: " + link.path))
        func resolved(_ label: String) -> String? {
            guard let line = rejected.1.components(separatedBy: "\n").first(where: { $0.hasPrefix(label) }) else { return nil }
            return URL(fileURLWithPath: String(line.dropFirst(label.count))).resolvingSymlinksInPath().path
        }
        XCTAssertEqual(resolved("Resolved file: "), outside.resolvingSymlinksInPath().path)
        XCTAssertEqual(resolved("Resolved project: "), project.resolvingSymlinksInPath().path)
        XCTAssertFalse(rejected.1.contains("Traceback"))
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

    func testDownloadRejectsSymlinkOutsideProjectAndCleansPartialFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project")
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        let link = source.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try FileBrowserIO.download(Project(name: "Test", path: source.path), path: link.path, directory: downloads))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [])
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
