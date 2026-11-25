import XCTest
@testable import ResearchDesk

final class PreviewInteractionTests: XCTestCase {
    func testSSHTransfersReuseConnectionWithoutRelaxingHostVerification() {
        let arguments = Command.sshArguments(host: "example-host", command: "python3 -c 'print(1)'")
        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains(where: { $0.hasPrefix("ControlPath=") }))
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("ConnectTimeout=20"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["example-host", "python3 -c 'print(1)'"])
    }
    func testImageFitsViewportAndZoomStaysBounded() {
        XCTAssertEqual(ImageZoom.fit(image: CGSize(width: 2000, height: 1000), viewport: CGSize(width: 1032, height: 1032)), 0.5)
        XCTAssertEqual(ImageZoom.fit(image: CGSize(width: 1000, height: 2000), viewport: CGSize(width: 1032, height: 1032)), 0.5)
        XCTAssertEqual(ImageZoom.clamped(100), 16)
        XCTAssertEqual(ImageZoom.clamped(0), 0.05)
    }
}
