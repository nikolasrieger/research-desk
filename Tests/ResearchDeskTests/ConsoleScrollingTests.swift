import XCTest
import AppKit
import SwiftTerm
@testable import ResearchDesk

private final class RecordingTerminal: LocalProcessTerminalView {
    var sent: [UInt8] = []
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }
}

final class ConsoleScrollingTests: XCTestCase {
    func testClaudeKeepsLongTranscriptAndCanPageThroughIt() async {
        await MainActor.run {
            let project = Project(name: "Scrolling", path: "/tmp")
            let session = AgentSession(project: project, agent: "claude", executable: nil)
            let terminal = session.terminal
            XCTAssertEqual(terminal.getTerminal().options.scrollback, 20_000)
            XCTAssertTrue(terminal.alternateScreenScrollsByPage)
            terminal.feed(text: (0..<800).map { "Message \($0)\r\n" }.joined())
            XCTAssertTrue(terminal.canScroll)
            terminal.scroll(toPosition: 1)
            let bottom = terminal.scrollPosition
            terminal.pageUp()
            XCTAssertLessThan(terminal.scrollPosition, bottom)
            terminal.pageDown()
            XCTAssertEqual(terminal.scrollPosition, bottom)
        }
    }

    func testFullScreenPagingIsSentToApplication() async {
        await MainActor.run {
            let terminal = RecordingTerminal(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            terminal.feed(text: "\u{1b}[?1049h")
            terminal.sent.removeAll()
            terminal.pageUp()
            terminal.pageDown()
            XCTAssertEqual(String(decoding: terminal.sent, as: UTF8.self), "\u{1b}[5~\u{1b}[6~")
        }
    }
}
