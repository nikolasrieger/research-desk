import XCTest
import AppKit
@testable import ResearchDesk

final class ChatInputTests: XCTestCase {
    @MainActor
    func testEnterSubmitsButShiftEnterAndCompositionDoNot() throws {
        func event(_ modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 36) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(ChatInputTextView.submits(try event(), composing: false))
        XCTAssertTrue(ChatInputTextView.submits(try event(code: 76), composing: false))
        XCTAssertTrue(ChatInputTextView.submits(try event(.command), composing: false))
        XCTAssertFalse(ChatInputTextView.submits(try event(.shift), composing: false))
        XCTAssertFalse(ChatInputTextView.submits(try event(.option), composing: false))
        XCTAssertFalse(ChatInputTextView.submits(try event(), composing: true))
        let view = ChatInputTextView()
        view.string = "Draft"
        var submissions = 0
        view.submit = { submissions += 1 }
        view.canSubmit = true
        view.keyDown(with: try event())
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(view.string, "Draft")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.keyDown(with: try event(.shift))
        XCTAssertEqual(view.string, "Draft\n")
        XCTAssertEqual(submissions, 1)
        view.string = "Draft"
        view.canSubmit = false
        view.keyDown(with: try event())
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(view.string, "Draft")
    }
}
