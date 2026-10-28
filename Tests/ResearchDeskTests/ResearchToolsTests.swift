import XCTest
@testable import ResearchDesk

final class ResearchToolsTests: XCTestCase {
    func testArxivIdentifiersAndMetadata() throws {
        XCTAssertEqual(ArxivID.parse("https://arxiv.org/pdf/1706.03762v7.pdf"), "1706.03762v7")
        XCTAssertEqual(ArxivID.parse("arXiv:hep-th/9901001"), "hep-th/9901001")
        XCTAssertNil(ArxivID.parse("https://example.com/abs/1706.03762"))
        XCTAssertNil(ArxivID.parse("../../file"))
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom"><entry><id>http://arxiv.org/abs/1706.03762v7</id><title>A &amp; B</title><author><name>First Author</name></author><author><name>Second Author</name></author><summary>An abstract.</summary><published>2017-06-12T00:00:00Z</published><arxiv:primary_category term="cs.CL"/></entry></feed>
        """
        let paper = try ArxivFeed.parse(Data(xml.utf8), requestedID: "1706.03762")
        XCTAssertEqual(paper.title, "A & B")
        XCTAssertEqual(paper.authors, ["First Author", "Second Author"])
        XCTAssertEqual(paper.category, "cs.CL")
        XCTAssertEqual(paper.year, "2017")
        XCTAssertTrue(paper.bibtex.contains("A \\& B"))
        XCTAssertThrowsError(try ArxivFeed.parse(Data("<feed/>".utf8), requestedID: "1706.03762"))
    }

    func testLibraryPersistenceAndCorruptionProtection() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("papers.json")
            let first = UUID(), second = UUID()
            let paper = ResearchPaper(id: "1706.03762", title: "Paper", authors: ["Author"], abstract: "Abstract", year: "2017", category: "cs.CL")
            let library = PaperLibrary(file: file)
            XCTAssertTrue(library.save([first: [paper], second: [paper]]))
            library.updateTags("Baseline, related work, baseline", paper: paper.id, project: first)
            let restored = PaperLibrary(file: file)
            XCTAssertEqual(restored.collections[first]?.first?.tags, ["baseline", "related work"])
            XCTAssertEqual(restored.collections[second]?.first?.tags, [])
            restored.remove(paper.id, project: first)
            XCTAssertEqual(PaperLibrary(file: file).collections[first]?.count, 0)
            let damaged = Data("broken".utf8)
            try damaged.write(to: file)
            XCTAssertFalse(PaperLibrary(file: file).save([:]))
            XCTAssertEqual(try Data(contentsOf: file), damaged)
        }
    }

    func testPasteControlsAndParagraphs() {
        XCTAssertEqual(ConsolePaste.text("one\ntwo\r\u{1b}\u{4}", multiline: false), "one two   ")
        XCTAssertEqual(ConsolePaste.text("one\ntwo", multiline: true), "one\ntwo")
    }

    func testArtifactDiscoveryIsSessionSpecificAndIgnoresUserLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projects = folder.appendingPathComponent("projects/workspace")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let session = UUID().uuidString.lowercased()
        let url = "https://claude.ai/code/artifact/abc-123"
        let records: [[String: Any]] = [
            ["type": "assistant", "message": ["content": "Created: \(url)"]],
            ["type": "user", "message": ["content": "https://claude.ai/code/artifact/not-created"]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        data.append(Data("{\"type\":\"assistant\"".utf8))
        try data.write(to: projects.appendingPathComponent(session + ".jsonl"))
        XCTAssertEqual(ArtifactLink.latest(in: data)?.absoluteString, url)
        XCTAssertEqual(try ArtifactDiscovery.local(root: folder.appendingPathComponent("projects"), sessionID: session)?.absoluteString, url)
        XCTAssertThrowsError(try ArtifactDiscovery.local(root: folder.appendingPathComponent("projects"), sessionID: UUID().uuidString))
        XCTAssertNil(ArtifactLink.parse("https://claude.ai.evil.com/code/artifact/abc"))
        XCTAssertNil(ArtifactLink.parse("http://claude.ai/code/artifact/abc"))
        XCTAssertNil(ArtifactLink.parse("https://claude.ai/chat/abc"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", ArtifactDiscovery.remoteScript, session]
        process.environment = ProcessInfo.processInfo.environment.merging(["CLAUDE_CONFIG_DIR": folder.path]) { _, new in new }
        let output = Pipe(); process.standardOutput = output
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        XCTAssertEqual(object?["url"] as? String, url)
    }
}
