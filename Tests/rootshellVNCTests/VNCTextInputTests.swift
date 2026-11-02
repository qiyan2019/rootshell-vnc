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

    func testPrepareForKeyRunsBeforeTheKeyAndIsSkippedWhenNil() {
        var order: [String] = []
        UpcomingKeyPreparation.perform({ order.append("prepare") }) {
            order.append("key")
        }
        XCTAssertEqual(order, ["prepare", "key"])

        order.removeAll()
        UpcomingKeyPreparation.perform(nil) { order.append("key") }
        XCTAssertEqual(order, ["key"])
    }

    func testNewlinePiecesStayOutOfTheCommitHook() {
        let crlf = "\r\n".first!
        XCTAssertEqual(crlf.unicodeScalars.count, 2)
        XCTAssertTrue(crlf.isNewline)
        XCTAssertEqual(
            KeyboardInputHandler.keysymForCharacter(crlf),
            KeyboardInputHandler.keysymReturn)

        XCTAssertEqual(SoftKeyboardInsert.pieces(in: "a\nb"), [
            .text("a"), .newline("\n"), .text("b"),
        ])
        XCTAssertEqual(SoftKeyboardInsert.pieces(in: "\r\n"), [
            .newline(crlf),
        ])
        XCTAssertEqual(SoftKeyboardInsert.pieces(in: "a\r\nb🙂"), [
            .text("a"), .newline(crlf), .text("b🙂"),
        ])
        XCTAssertEqual(SoftKeyboardInsert.pieces(in: "🙂"), [.text("🙂")])
        XCTAssertEqual(SoftKeyboardInsert.pieces(in: ""), [])

        var order: [String] = []
        for piece in SoftKeyboardInsert.pieces(in: "a\nb") {
            switch piece {
            case .text(let text):
                VNCSoftKeyboardCommit.deliver(text, hook: { chunk in
                    order.append("hook \(chunk)")
                    return true
                }, send: { _ in
                    order.append("keystroke")
                })
            case .newline:
                UpcomingKeyPreparation.perform({ order.append("prepare") }) {
                    order.append("return")
                }
            }
        }
        XCTAssertEqual(order, ["hook a", "prepare", "return", "hook b"])
    }

    func testCommitHookReceivesEmojiIntact() {
        var seen: String?
        var sent = ""
        VNCSoftKeyboardCommit.deliver("🙂", hook: { text in
            seen = text
            return true
        }, send: { sent.append($0) })
        XCTAssertEqual(seen, "🙂")
        XCTAssertEqual(seen?.unicodeScalars.count, 1)
        XCTAssertEqual(sent, "")
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

    func testPasteDeviceTextStaysAheadOfTheFollowingKey() {
        var queue = SessionInputQueue()
        queue.enqueue(.pasteDeviceText("hi"))
        queue.enqueue(.key(downFlag: true, keysym: 0x76))
        XCTAssertEqual(queue.pending, [
            .pasteDeviceText("hi"),
            .key(downFlag: true, keysym: 0x76),
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

    func testDeleteBackwardPreparesBeforeBackspace() {
        let log = EventLog()
        let capture = VNCKeyboardCapture()
        var order: [String] = []
        capture.onPrepareForKey = { order.append("prepare") }
        let view = makeView(capture: capture, log: log)
        view.deleteBackward()
        XCTAssertEqual(order, ["prepare"])
        XCTAssertEqual(log.events.map(\.keysym), [
            KeyboardInputHandler.keysymBackspace,
            KeyboardInputHandler.keysymBackspace,
        ])
        XCTAssertEqual(log.events.map(\.downFlag), [true, false])
    }

    func testNewlinePreparesBeforeCharactersButPlainTextDoesNot() {
        let log = EventLog()
        let capture = VNCKeyboardCapture()
        var prepared = 0
        capture.onPrepareForKey = { prepared += 1 }
        let view = makeView(capture: capture, log: log)

        view.insertText("a")
        XCTAssertEqual(prepared, 0)
        XCTAssertFalse(log.events.isEmpty)

        log.events.removeAll()
        view.insertText("\n")
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(log.events.map(\.keysym).first, KeyboardInputHandler.keysymReturn)
    }

    func testNewlineIsReturnBetweenCommitHooks() {
        let log = EventLog()
        let capture = VNCKeyboardCapture()
        var seen: [String] = []
        var order: [String] = []
        capture.onCommitText = { text in
            seen.append(text)
            order.append("hook")
            return true
        }
        capture.onPrepareForKey = { order.append("prepare") }
        let view = makeView(capture: capture, log: log)
        view.insertText("a\nb")
        XCTAssertEqual(seen, ["a", "b"])
        XCTAssertEqual(order, ["hook", "prepare", "hook"])
        XCTAssertEqual(log.events.map(\.keysym), [
            KeyboardInputHandler.keysymReturn,
            KeyboardInputHandler.keysymReturn,
        ])
        XCTAssertEqual(log.events.map(\.downFlag), [true, false])
    }

    func testCarriageReturnNewlineIsOneReturnAndSkipsTheHook() {
        let log = EventLog()
        let capture = VNCKeyboardCapture()
        var seen: [String] = []
        capture.onCommitText = { text in
            seen.append(text)
            return true
        }
        var prepared = 0
        capture.onPrepareForKey = { prepared += 1 }
        let view = makeView(capture: capture, log: log)
        view.insertText("\r\n")
        XCTAssertTrue(seen.isEmpty)
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(log.events.map(\.keysym), [
            KeyboardInputHandler.keysymReturn,
            KeyboardInputHandler.keysymReturn,
        ])
    }

    func testReturnStillConsumesStickyModifiersWhenSurroundingTextIsPasted() {
        let log = EventLog()
        let capture = VNCKeyboardCapture()
        var consumed = 0
        capture.supplementalModifiers = [.command]
        capture.onSupplementalModifiersConsumed = { consumed += 1 }
        capture.onCommitText = { _ in true }
        let view = makeView(capture: capture, log: log)
        view.insertText("a\nb")
        XCTAssertEqual(consumed, 1)
        XCTAssertEqual(log.events.map(\.keysym), [
            KeyboardInputHandler.keysymSuperL,
            KeyboardInputHandler.keysymReturn,
            KeyboardInputHandler.keysymReturn,
            KeyboardInputHandler.keysymSuperL,
        ])
    }
}
#endif
