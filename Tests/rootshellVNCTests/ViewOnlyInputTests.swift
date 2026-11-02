import CoreGraphics
import Foundation
import RFBProtocol
import RFBTransport
import XCTest
@testable import rootshellVNC

final class ViewOnlyInputTests: XCTestCase {
    func testGesturesWhileViewingStillPanAndZoomButDoNotClick() {
        XCTAssertEqual(
            RemoteViewOnlyGestures.effect(of: .singleFingerMove, viewOnly: true),
            .panViewport)
        XCTAssertEqual(
            RemoteViewOnlyGestures.effect(of: .twoFingerMove, viewOnly: true),
            .panViewport)
        XCTAssertEqual(
            RemoteViewOnlyGestures.effect(of: .pinch, viewOnly: true),
            .zoom)
        XCTAssertEqual(
            RemoteViewOnlyGestures.effect(of: .tap, viewOnly: true),
            .drop)
        XCTAssertEqual(
            RemoteViewOnlyGestures.effect(of: .longPress, viewOnly: true),
            .drop)
    }

    func testGesturesReachTheRemoteWhenNotViewOnly() {
        for gesture in [
            RemoteViewOnlyGesture.singleFingerMove,
            .twoFingerMove, .pinch, .tap, .longPress,
        ] {
            XCTAssertEqual(
                RemoteViewOnlyGestures.effect(of: gesture, viewOnly: false),
                .deliverToRemote)
        }
    }

    func testReleaseLiftsKeysInReverseThenTheMouseButton() {
        var held = ViewOnlyHeldInput()
        held.noteKey(down: true, keysym: 0xFFE3)
        held.noteKey(down: true, keysym: 0x61)
        held.noteKey(down: false, keysym: 0x61)
        held.notePointer(buttonMask: 0x01, x: 10, y: 20)
        // 滚轮位不应当作按住的鼠标键。
        held.notePointer(buttonMask: 0x08, x: 11, y: 21)

        XCTAssertEqual(held.releaseEvents(), [
            .key(downFlag: false, keysym: 0xFFE3),
        ])

        held.notePointer(buttonMask: 0x05, x: 4, y: 5)
        XCTAssertEqual(held.releaseEvents(), [
            .key(downFlag: false, keysym: 0xFFE3),
            .pointer(buttonMask: 0, x: 4, y: 5),
        ])
    }
}

@MainActor
final class ViewOnlySessionTests: XCTestCase {
    private let keyA = ClientMessage.keyEvent(downFlag: true, key: 0x61).serialize()
    private let keyAUp = ClientMessage.keyEvent(downFlag: false, key: 0x61).serialize()
    private let keyB = ClientMessage.keyEvent(downFlag: true, key: 0x62).serialize()
    private let pointerDown = ClientMessage.pointerEvent(
        buttonMask: 1, x: 8, y: 9).serialize()
    private let pointerUp = ClientMessage.pointerEvent(
        buttonMask: 0, x: 8, y: 9).serialize()

    func testEnablingViewOnlyReleasesHeldKeysAndButtonsBeforeTheGate() async throws {
        let harness = try await ViewOnlyHarness.connected()
        harness.session.sendKeyEvent(downFlag: true, key: 0x61)
        harness.session.sendPointerEvent(buttonMask: 1, x: 8, y: 9)
        try await harness.waitUntilSent(keyA)
        try await harness.waitUntilSent(pointerDown)

        harness.session.isViewOnly = true
        try await harness.waitUntilSent(keyAUp)
        try await harness.waitUntilSent(pointerUp)

        let frozen = await harness.connection.sentBytes()
        harness.session.sendKeyEvent(downFlag: true, key: 0x62)
        harness.session.sendPointerEvent(buttonMask: 1, x: 1, y: 1)
        try await Task.sleep(for: .milliseconds(50))
        let after = await harness.connection.sentBytes()
        XCTAssertEqual(after, frozen)
        XCTAssertNil(after.range(of: keyB))
        harness.session.disconnect()
    }

    func testViewOnlyDropsEveryInputMethodThenSendingResumes() async throws {
        let harness = try await ViewOnlyHarness.connected()
        harness.session.isViewOnly = true
        let frozen = await harness.connection.sentBytes()

        harness.session.sendKeyEvent(downFlag: true, key: 0x61)
        harness.session.sendPointerEvent(buttonMask: 1, x: 1, y: 2)
        harness.session.sendScrollEvent(AppleScrollEvent(
            pointDeltaX: 0, pointDeltaY: -1,
            x: 1, y: 2))
        harness.session.sendGestureEvent(AppleGestureEvent(
            kind: .began, x: 1, y: 2))
        harness.session.sendClipboardText("hidden")
        harness.session.pasteText("hidden")
        harness.session.sendLoginPassword()
        try await Task.sleep(for: .milliseconds(80))
        let blocked = await harness.connection.sentBytes()
        XCTAssertEqual(blocked, frozen)

        harness.session.isViewOnly = false
        harness.session.sendKeyEvent(downFlag: true, key: 0x62)
        try await harness.waitUntilSent(keyB)
        harness.session.disconnect()
    }
}

@MainActor
final class LoginPasswordDeliveryTests: XCTestCase {
    func testUnconnectedOrViewOnlySendIsNotSent() async throws {
        let idle = await VNCSession().sendLoginPassword { true }
        XCTAssertEqual(idle, .notSent)

        let harness = try await ViewOnlyHarness.connected()
        let session = harness.session
        session.isViewOnly = true
        let blocked = await session.sendLoginPassword { true }
        XCTAssertEqual(blocked, .notSent)
        session.disconnect()
    }

    func testContinueFalseStopsBeforeTheKeysAfterTheFocusPause() async throws {
        let harness = try await ViewOnlyHarness.connected()
        let before = await harness.connection.sentBytes().count
        var checks = 0
        let result = await harness.session.sendLoginPassword {
            checks += 1
            return false
        }
        XCTAssertEqual(result, .stopped)
        XCTAssertGreaterThan(checks, 0)
        let added = Data((await harness.connection.sentBytes()).dropFirst(before))
        let click = ClientMessage.pointerEvent(buttonMask: 0, x: 4, y: 4).serialize()
        let selectAll = ClientMessage.keyEvent(downFlag: true, key: 0x61).serialize()
        XCTAssertNotNil(added.range(of: click))
        XCTAssertNil(added.range(of: selectAll))
        harness.session.disconnect()
    }

    func testDeliverySendsTheReturnKeyWhenContinuing() async throws {
        let harness = try await ViewOnlyHarness.connected()
        let before = await harness.connection.sentBytes().count
        let result = await harness.session.sendLoginPassword { true }
        XCTAssertEqual(result, .delivered)
        let added = Data((await harness.connection.sentBytes()).dropFirst(before))
        let returnDown = ClientMessage.keyEvent(
            downFlag: true,
            key: KeyboardInputHandler.keysymReturn).serialize()
        XCTAssertNotNil(added.range(of: returnDown))
        harness.session.disconnect()
    }

    func testDisconnectDuringDeliveryStops() async throws {
        let harness = try await ViewOnlyHarness.connected()
        var stoppedTheSession = false
        let result = await harness.session.sendLoginPassword {
            if !stoppedTheSession {
                stoppedTheSession = true
                harness.session.disconnect()
            }
            return true
        }
        XCTAssertEqual(result, .stopped)
    }

    func testServerInitNameFieldIsLengthAndSixBytePrefix() async throws {
        let harness = try await ViewOnlyHarness.connected()
        let diagnostics = harness.session.getDiagnostics()
        XCTAssertEqual(diagnostics.serverInitNameFieldLength, 9)
        XCTAssertEqual(diagnostics.serverInitPrefixHex, "766965772d6f")
        harness.session.disconnect()
    }

    func testUnknownClipboardReplaysOnceOnTheFirstUnlockedAnnouncement() async throws {
        let harness = try await ViewOnlyHarness.connected()
        harness.session.noteClipboardForUnlockReplay("early")
        XCTAssertEqual(harness.session.clipboardReplayOnUnlock, "early")
        let before = (await harness.connection.sentBytes()).count
        harness.session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: false,
            loginWindowLockScreenActive: false))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(harness.session.clipboardReplayOnUnlock)
        let once = await harness.connection.sentBytes()
        XCTAssertGreaterThan(once.count, before)
        harness.session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: false,
            loginWindowLockScreenActive: false))
        try await Task.sleep(for: .milliseconds(200))
        let twice = await harness.connection.sentBytes()
        XCTAssertEqual(twice, once)
        harness.session.disconnect()
    }

    func testRecheckOffersThePromptWhenLoginStaysActive() async throws {
        let harness = try await ViewOnlyHarness.connected()
        harness.session.configuration.promptForLoginPasswordAtLoginWindow = true
        harness.session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: true,
            loginWindowLockScreenActive: false))
        XCTAssertTrue(harness.session.consumeLoginPasswordPromptRequest())
        harness.session.sendLoginPassword()
        harness.session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: false,
            loginWindowLockScreenActive: false))
        harness.session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: true,
            loginWindowLockScreenActive: false))
        XCTAssertFalse(harness.session.loginPasswordPromptPending)
        try await Task.sleep(for: .seconds(12))
        XCTAssertTrue(harness.session.loginPasswordPromptPending)
        harness.session.disconnect()
    }
}

@MainActor
private struct ViewOnlyHarness {
    let session: VNCSession
    let connection: ViewOnlyScriptedConnection

    static func connected() async throws -> ViewOnlyHarness {
        let connection = ViewOnlyScriptedConnection()
        var script = Data("RFB 003.008\n".utf8)
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(serverInit(width: 8, height: 8, name: "view-only"))
        await connection.enqueueServerBytes(script)

        var configuration = VNCConfiguration(
            enableHighPerformanceMode: false,
            videoQualityMode: .standard,
            displaySizingMode: .remoteDisplay,
            enableRemoteAudio: false,
            promptForLoginPasswordAtLoginWindow: false,
            reconnectionPolicy: VNCReconnectionPolicy(isEnabled: false))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)
        try await session.connect(credentials: VNCCredentials(
            host: "view-only.test",
            port: 5900,
            password: "secret"))
        let harness = ViewOnlyHarness(session: session, connection: connection)
        try await harness.waitUntilConnected()
        return harness
    }

    func waitUntilConnected() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if session.connectionState.isConnected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(session.connectionState.isConnected)
    }

    func waitUntilSent(_ needle: Data) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            let sent = await connection.sentBytes()
            if sent.range(of: needle) != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await connection.sentBytes()
        XCTAssertNotNil(sent.range(of: needle), "missing \(needle as NSData)")
    }
}

private func serverInit(width: UInt16, height: UInt16, name: String) -> Data {
    var data = Data()
    data.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xff)])
    data.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xff)])
    data.append(PixelFormat.bgra8888.wireBytes())
    let nameBytes = Data(name.utf8)
    let length = UInt32(nameBytes.count)
    data.append(contentsOf: [
        UInt8((length >> 24) & 0xff),
        UInt8((length >> 16) & 0xff),
        UInt8((length >> 8) & 0xff),
        UInt8(length & 0xff),
    ])
    data.append(nameBytes)
    return data
}

private actor ViewOnlyScriptedConnection: RFBConnection {
    private var serverBytes = Data()
    private var readOffset = 0
    private var closed = false
    private var sent = Data()
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueueServerBytes(_ data: Data) {
        serverBytes.append(data)
        let waiters = readWaiters
        readWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func sentBytes() -> Data { sent }

    func connect() async throws {
        if closed { throw VNCProtocolError.connectionClosed }
    }

    func read(exactly count: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            if serverBytes.count - readOffset >= count {
                return consume(count)
            }
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }

    func read(upTo maxCount: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            let available = serverBytes.count - readOffset
            if available > 0 { return consume(min(available, maxCount)) }
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }

    func send(_ data: Data) async throws {
        if closed { throw VNCProtocolError.connectionClosed }
        sent.append(data)
    }

    func close() async {
        closed = true
        let waiters = readWaiters
        readWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async {}

    private func consume(_ count: Int) -> Data {
        let start = serverBytes.startIndex + readOffset
        let result = serverBytes.subdata(in: start..<(start + count))
        readOffset += count
        return result
    }
}
