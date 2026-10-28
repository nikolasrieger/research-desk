import XCTest
import AppKit
@testable import SwiftTerm
@testable import ResearchDesk

private final class OutputRecorder: LocalProcessDelegate, @unchecked Sendable {
    let queue: DispatchQueue
    let complete: XCTestExpectation
    let expectedCount: Int
    var bytes: [UInt8] = []
    var yieldedAt = 0
    init(queue: DispatchQueue, complete: XCTestExpectation, expectedCount: Int) {
        self.queue = queue; self.complete = complete; self.expectedCount = expectedCount
    }
    func dataReceived(slice: ArraySlice<UInt8>) {
        if bytes.isEmpty {
            queue.async { self.yieldedAt = self.bytes.count }
            // Simulate a costly parser batch, requiring a yield.
            Thread.sleep(forTimeInterval: 0.003)
        }
        bytes.append(contentsOf: slice)
        if bytes.count == expectedCount { complete.fulfill() }
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
    func getWindowSize() -> winsize { winsize() }
}

final class ConsolePerformanceTests: XCTestCase {
    func testOutputPreservesBytesAndYieldsBetweenBatches() async {
        let queue = DispatchQueue(label: "test.terminal.output")
        let complete = expectation(description: "All bytes delivered")
        let input = (0..<131072).map { UInt8($0 % 256) }
        let delegate = OutputRecorder(queue: queue, complete: complete, expectedCount: input.count)
        let process = LocalProcess(delegate: delegate, dispatchQueue: queue)
        let data = input.withUnsafeBytes { DispatchData(bytes: $0) }
        process.childProcessRead(done: false, data: data, errno: 0)
        await fulfillment(of: [complete], timeout: 5)
        queue.sync {
            XCTAssertEqual(delegate.bytes, input)
            XCTAssertGreaterThan(delegate.yieldedAt, 0)
            XCTAssertLessThan(delegate.yieldedAt, input.count)
        }
        withExtendedLifetime(process) {}
    }

    func testHiddenConsoleParsesWithoutSchedulingPresentationAndResumes() async {
        await MainActor.run {
            let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            view.presentationSuspended = true
            view.pendingDisplay = false
            view.feed(text: "hidden output")
            XCTAssertFalse(view.pendingDisplay)
            XCTAssertNotNil(view.getTerminal().getUpdateRange())
            XCTAssertTrue(view.getTerminal().getLine(row: 0)!.translateToString().contains("hidden output"))
            view.presentationSuspended = false
            XCTAssertNil(view.getTerminal().getUpdateRange())
        }
    }

    func testDictationCannotSubmitOrInjectTerminalControls() async {
        await MainActor.run {
            let result = ConsoleDictation.inputText("hello\r\nworld\t\u{1b}test\u{7}")
            XCTAssertFalse(result.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
            XCTAssertTrue(result.contains("hello"))
            XCTAssertTrue(result.contains("world"))
            XCTAssertEqual(ConsoleDictation.inputText("  Fix the camera test.  "), "Fix the camera test.")
        }
    }
}
