import XCTest
import AppKit
@testable import ResearchDesk

final class PreviewPerformanceTests: XCTestCase {
    func testLargeImageIsDownsampledForPreview() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4800, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let preview = PreviewContent(data: data, extension: "png")
        let image = try XCTUnwrap(preview.image)
        XCTAssertLessThanOrEqual(image.representations.first!.pixelsWide, 2400)
        XCTAssertNil(preview.text)
    }

    func testCancelledCopyNeverStartsRemoteTransfer() throws {
        let cancellation = PreviewCancellation()
        cancellation.cancel()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try FileBrowserIO.copyFile(Project(name: "Test", path: "/tmp", host: "does-not-exist"), path: "/tmp/test", to: destination, cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTextPreviewPreservesUnicodeAndRejectsBinary() {
        XCTAssertEqual(PreviewContent(data: Data("Hello 🌙\nWorld".utf8), extension: "md").text, "Hello 🌙\nWorld")
        XCTAssertNil(PreviewContent(data: Data([65, 0, 66]), extension: "bin").text)
    }
}
