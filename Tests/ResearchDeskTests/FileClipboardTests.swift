import XCTest
import AppKit
@testable import ResearchDesk

final class FileClipboardTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor
    func testImageClipboardContainsOriginalImageAndDurableFile() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let original = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = root.appendingPathComponent("figure.png")
        try original.write(to: source)
        let file = try FileClipboard.prepare(project: Project(name: "Fixture", path: root.path), path: source.path, root: root.appendingPathComponent("clipboard"))
        try FileManager.default.removeItem(at: source)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try FileClipboard.write(file, to: pasteboard)
        XCTAssertEqual(pasteboard.data(forType: .png), original)
        let tiff = try XCTUnwrap(pasteboard.data(forType: .tiff))
        XCTAssertEqual(NSBitmapImageRep(data: tiff)?.pixelsWide, 3000)
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])
        XCTAssertEqual(urls, [file.url])
        XCTAssertEqual(try Data(contentsOf: file.url), original)
        XCTAssertEqual(file.url.lastPathComponent, "figure.png")
        XCTAssertNil(pasteboard.string(forType: .string), "Copy must not degrade to a path string")
    }
    @MainActor
    func testGenericFileCopiesBytesAndSameNamesDoNotCollide() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("result.bin")
        let data = Data([0, 255, 42, 0])
        try data.write(to: source)
        let project = Project(name: "Fixture", path: root.path)
        let cache = root.appendingPathComponent("clipboard")
        let first = try FileClipboard.prepare(project: project, path: source.path, root: cache)
        let second = try FileClipboard.prepare(project: project, path: source.path, root: cache)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertNil(first.imageData)
        XCTAssertEqual(try Data(contentsOf: first.url), data)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try FileClipboard.write(first, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), first.url.absoluteString)
        XCTAssertNil(pasteboard.data(forType: .tiff))
    }
    func testFailureCleansUpIncompleteClipboardCopy() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("clipboard")
        XCTAssertThrowsError(try FileClipboard.prepare(project: Project(name: "Fixture", path: root.path), path: root.appendingPathComponent("missing.png").path, root: cache))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }
}
