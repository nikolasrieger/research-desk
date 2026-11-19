import XCTest
import AppKit
@testable import ResearchDesk

final class NotesTests: XCTestCase {
    func testImportedImageSurvivesSourceRemovalAndMarkdownRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("plot [final].png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
        let project = Project(name: "Notes", path: root.path)
        let imported = try NoteAttachments.importImage(project: project, path: source.path, root: root.appendingPathComponent("attachments"))
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        let parsed = try XCTUnwrap(NoteImageLink.parse(NoteAttachments.markdown(url: imported, name: "plot [final].png")))
        XCTAssertEqual(parsed.url, imported)
        XCTAssertEqual(parsed.alt, "plot final.png")
    }
    func testInvalidImageDoesNotLeaveAnAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fake.png")
        try Data("Not an image".utf8).write(to: source)
        let project = Project(name: "Notes", path: root.path)
        let attachments = root.appendingPathComponent("attachments")
        XCTAssertThrowsError(try NoteAttachments.importImage(project: project, path: source.path, root: attachments))
        let files = try FileManager.default.contentsOfDirectory(atPath: attachments.appendingPathComponent(project.id.uuidString).path)
        XCTAssertTrue(files.isEmpty)
    }
    func testImageParserDoesNotTreatCodeOrRemoteURLsAsLocalImages() {
        XCTAssertNil(NoteImageLink.parse("![plot](https://example.com/image.png)"))
        XCTAssertNil(NoteImageLink.parse("`![plot](file:///tmp/image.png)`"))
    }
}
