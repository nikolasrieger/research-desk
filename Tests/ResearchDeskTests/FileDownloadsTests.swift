import XCTest
@testable import ResearchDesk

final class FileDownloadsTests: XCTestCase {
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
