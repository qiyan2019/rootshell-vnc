import CoreGraphics
import XCTest
@testable import rootshellVNC

final class AppleLoginTextTests: XCTestCase {
    func testStrongPhraseUsesThatLineAsThePasswordCenter() throws {
        let analysis = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Cancel",
                confidence: 1,
                bounds: CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.05)),
            AppleLoginTextLine(
                text: "Enter Password",
                confidence: 1,
                bounds: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.08)),
        ])
        XCTAssertTrue(analysis.isLoginScreen)
        XCTAssertEqual(analysis.evidence, "central password-entry phrase")
        let center = try XCTUnwrap(analysis.passwordLineCenter)
        XCTAssertEqual(center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(center.y, 0.24, accuracy: 0.0001)
    }

    func testCorroboratedPasswordUsesTheFirstPasswordLine() {
        let analysis = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Touch ID",
                confidence: 1,
                bounds: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.05)),
            AppleLoginTextLine(
                text: "Password",
                confidence: 1,
                bounds: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.04)),
        ])
        XCTAssertEqual(analysis.evidence, "password and Touch ID")
        XCTAssertEqual(
            analysis.passwordLineCenter,
            CGPoint(x: 0.4, y: 0.32))
    }

    func testWeakPasswordTextDoesNotKeepACenter() {
        let analysis = AppleLoginScreenDetector.analyze([
            AppleLoginTextLine(
                text: "Password",
                confidence: 1,
                bounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.05)),
        ])
        XCTAssertFalse(analysis.isLoginScreen)
        XCTAssertNil(analysis.passwordLineCenter)
    }

    func testRecognizerTreatsABlankFrameAsNotALoginScreen() async throws {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try XCTUnwrap(context?.makeImage())
        let detected = await VNCLoginScreenRecognizer.isLoginScreen(image)
        XCTAssertFalse(detected)
    }

    @MainActor
    func testRemoteLoginVisionStartsFalse() {
        XCTAssertFalse(VNCSession().remoteLoginVisionDetected)
    }
}
