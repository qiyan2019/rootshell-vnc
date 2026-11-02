import XCTest
import RFBProtocol
@testable import rootshellVNC
@testable import RFBTransport

@MainActor
final class VNCTextInputTests: XCTestCase {
    func testCommitWithoutHookSendsEveryCharacter() {
        var sent = ""
        VNCSoftKeyboardCommit.deliver("ab中", hook: nil) { sent.append($0) }
        XCTAssertEqual(sent, "ab中")
    }

    func testCommitHookTrueSendsNoKeys() {
        var sent = ""
        var seen: String?
        VNCSoftKeyboardCommit.deliver("ab", hook: { text in
            seen = text
            return true
        }) { sent.append($0) }
        XCTAssertEqual(seen, "ab")
        XCTAssertEqual(sent, "")
    }

    func testCommitHookFalseContinuesKeystrokes() {
        var sent = ""
        VNCSoftKeyboardCommit.deliver("ab", hook: { _ in false }) { sent.append($0) }
        XCTAssertEqual(sent, "ab")
    }

    func testPasteKeysymsMatchKeyboardHandler() {
        XCTAssertEqual(
            AppleTextPaste.commandKeysym,
            KeyboardInputHandler.keysymSuperL)
        XCTAssertEqual(
            AppleTextPaste.pasteKeysym,
            KeyboardInputHandler.keysymForCharacter("v"))
    }

    func testInsufficientCapabilityFallsBackToUpstreamKeystrokes() {
        XCTAssertFalse(VNCTextPaste.usesPackedScrap(nil))
        var bitmap = Data(repeating: 0, count: 16)
        var field = Data([0, 0, 0, 0, 0, 0])
        field.append(bitmap)
        let without = AppleServerCapabilities(serverInitNameField: field)
        XCTAssertFalse(VNCTextPaste.usesPackedScrap(without))

        bitmap[3] = 0x01
        field = Data([0, 0, 0, 0, 0, 0])
        field.append(bitmap)
        let withBit = AppleServerCapabilities(serverInitNameField: field)
        XCTAssertTrue(VNCTextPaste.usesPackedScrap(withBit))

        let events = VNCTextPaste.keyEvents(for: "a中")
        XCTAssertEqual(events.map(\.keysym), [
            KeyboardInputHandler.keysymForCharacter("a"),
            KeyboardInputHandler.keysymForCharacter("a"),
            KeyboardInputHandler.keysymForCharacter("中"),
            KeyboardInputHandler.keysymForCharacter("中"),
        ])
        XCTAssertEqual(events.map(\.downFlag), [true, false, true, false])
        XCTAssertEqual(
            KeyboardInputHandler.keysymForCharacter("中"),
            0x01004E2D)
    }

    func testPasteTextIsAnOrderingBarrier() {
        var queue = SessionInputQueue()
        queue.enqueue(.pasteText("hi"))
        queue.enqueue(.pointer(buttonMask: 0, x: 1, y: 2))
        queue.enqueue(.pasteText("yo"))
        XCTAssertEqual(queue.pending, [
            .pasteText("hi"),
            .pointer(buttonMask: 0, x: 1, y: 2),
            .pasteText("yo"),
        ])
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class VNCTextInputViewTests: XCTestCase {
    private final class EventLog {
        var events: [HardwareKeyboardTransition] = []
    }

    private func makeView(
        capture: VNCKeyboardCapture,
        log: EventLog
    ) -> RemoteInputUIView {
        RemoteInputUIView(
            touchHandler: TouchInputHandler { _, _, _ in },
            keyboardHandler: KeyboardInputHandler(sendKeyEvent: { down, keysym in
                log.events.append(HardwareKeyboardTransition(downFlag: down, keysym: keysym))
            }),
            keyboardCapture: capture,
            requestPasswordSend: {},
            requestDictation: {},
            toggleFullScreen: nil,
            disconnect: {})
    }

    func testInsertTextWithoutHookMatchesCharacterKeystrokes() {
        let log = EventLog()
        let capture = VNCKeyboardCapture()
        let view = makeView(capture: capture, log: log)
        view.insertText("a中")
        XCTAssertEqual(log.events.map(\.keysym), [
            KeyboardInputHandler.keysymForCharacter("a"),
            KeyboardInputHandler.keysymForCharacter("a"),
            KeyboardInputHandler.keysymForCharacter("中"),
            KeyboardInputHandler.keysymForCharacter("中"),
        ])
        XCTAssertEqual(log.events.map(\.downFlag), [true, false, true, false])
    }

    func testInsertTextHookTrueSendsNothingAndDoesNotConsumeModifiers() {
        let log = EventLog()
        let capture = VNCKeyboardCapture()
        var consumed = false
        capture.supplementalModifiers = [.command]
        capture.onSupplementalModifiersConsumed = { consumed = true }
        capture.onCommitText = { _ in true }
        let view = makeView(capture: capture, log: log)
        view.insertText("a")
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertFalse(consumed)
    }

    func testInsertTextHookFalseStillSendsKeysWithStickyModifiers() {
        let log = EventLog()
        let capture = VNCKeyboardCapture()
        var consumed = false
        capture.supplementalModifiers = [.command]
        capture.onSupplementalModifiersConsumed = { consumed = true }
        capture.onCommitText = { _ in false }
        let view = makeView(capture: capture, log: log)
        view.insertText("a")
        XCTAssertEqual(log.events.map(\.keysym), [
            KeyboardInputHandler.keysymSuperL,
            KeyboardInputHandler.keysymForCharacter("a"),
            KeyboardInputHandler.keysymForCharacter("a"),
            KeyboardInputHandler.keysymSuperL,
        ])
        XCTAssertTrue(consumed)
    }
}
#endif
