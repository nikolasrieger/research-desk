import XCTest
import AppKit
import SwiftTerm

private final class CopyRecordingTerminal: LocalProcessTerminalView {
    var copied: String?
    var sent: [UInt8] = []
    override func copy(_ sender: Any) { copied = getSelection() }
    override func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
}

final class ConsoleCopyTests: XCTestCase {
    func testDictationPasteUsesBracketedPasteWithoutSubmitting() async {
        await MainActor.run {
            let terminal = CopyRecordingTerminal(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            terminal.feed(text: "\u{1b}[?2004h")
            terminal.sent.removeAll()
            terminal.pasteText("Fix the camera test.")
            XCTAssertEqual(String(decoding: terminal.sent, as: UTF8.self),
                           "\u{1b}[200~Fix the camera test.\u{1b}[201~")
            XCTAssertFalse(terminal.sent.contains(13))
            XCTAssertFalse(terminal.sent.contains(10))
        }
    }

    func testCommandCCopiesWithoutClearingSelectionOrSendingInput() async {
        await MainActor.run {
            let terminal = CopyRecordingTerminal(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            terminal.feed(text: "Copy this console output")
            terminal.selectAll()
            let selected = terminal.getSelection()
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
            terminal.keyDown(with: event)
            XCTAssertTrue(selected?.contains("Copy this console output") == true)
            XCTAssertEqual(terminal.copied, selected)
            XCTAssertEqual(terminal.getSelection(), selected)
            XCTAssertTrue(terminal.sent.isEmpty)
        }
    }

    func testControlCStillInterrupts() async {
        await MainActor.run {
            let terminal = CopyRecordingTerminal(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
            terminal.keyDown(with: event)
            XCTAssertNil(terminal.copied)
            XCTAssertEqual(terminal.sent, [3])
        }
    }
}
