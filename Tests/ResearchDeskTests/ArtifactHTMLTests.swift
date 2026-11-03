import XCTest
@testable import ResearchDesk

final class ArtifactHTMLTests: XCTestCase {
    func testReferencedMediaAndStylesAreCollectedWithinProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("reports"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "reports/index.html": "<img src='../plot%20one.png'><video poster='../poster.jpg'><source src='../movie.mp4'></video><link href='../style.css'><img src='https://example.com/no.png'><img src='../../outside.png'>",
            "style.css": "body { background: url('background.png') }",
            "plot one.png": "image", "poster.jpg": "poster", "movie.mp4": "video", "background.png": "image", "unrelated.bin": "skip"
        ]
        for (name, text) in files { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", ArtifactHTML.assetScript, root.path, root.appendingPathComponent("reports/index.html").path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let paths = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(Set(paths), Set(files.keys.filter { $0 != "unrelated.bin" }))
    }
}
