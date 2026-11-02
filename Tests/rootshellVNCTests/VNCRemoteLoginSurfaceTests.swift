import XCTest
@testable import RFBTransport
@testable import rootshellVNC

@MainActor
final class VNCRemoteLoginSurfaceTests: XCTestCase {
    func testLockAndLoginFlagsFollowDisplayInfoAndOutliveThePrompt() {
        let session = VNCSession()
        XCTAssertEqual(session.remoteLoginSurface, VNCRemoteLoginSurface())

        session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: false,
            loginWindowLockScreenActive: true))
        XCTAssertEqual(
            session.remoteLoginSurface,
            VNCRemoteLoginSurface(isLockScreen: true, isLoginWindow: false))
        // The password prompt defaults off, so this is the state a host sees
        // after the one-shot prompt has already been consumed.
        XCTAssertFalse(session.loginPasswordPromptPending)
        XCTAssertFalse(session.consumeLoginPasswordPromptRequest())
        XCTAssertEqual(
            session.remoteLoginSurface,
            VNCRemoteLoginSurface(isLockScreen: true, isLoginWindow: false))

        session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: true,
            loginWindowLockScreenActive: false))
        XCTAssertEqual(
            session.remoteLoginSurface,
            VNCRemoteLoginSurface(isLockScreen: false, isLoginWindow: true))

        session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: false,
            loginWindowLockScreenActive: false))
        XCTAssertEqual(session.remoteLoginSurface, VNCRemoteLoginSurface())
    }

    func testDisconnectClearsThePublishedSurface() {
        let session = VNCSession()
        session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: true,
            loginWindowLockScreenActive: true))
        session.disconnect()
        XCTAssertEqual(session.remoteLoginSurface, VNCRemoteLoginSurface())
    }

    func testClipboardSentWhileLockedIsRememberedUntilUnlock() {
        let session = VNCSession()
        session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: false,
            loginWindowLockScreenActive: true))
        session.noteClipboardForUnlockReplay("phone")
        XCTAssertEqual(session.clipboardReplayOnUnlock, "phone")

        // 还没连上，解锁公告不能把待重发的文字丢掉。
        session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: false,
            loginWindowLockScreenActive: false))
        XCTAssertEqual(session.clipboardReplayOnUnlock, "phone")

        session.noteClipboardForUnlockReplay("ignored")
        XCTAssertNil(session.clipboardReplayOnUnlock)

        session.handleAppleRemoteSessionState(AppleRemoteSessionState(
            loginWindowActive: true,
            loginWindowLockScreenActive: false))
        session.noteClipboardForUnlockReplay("again")
        XCTAssertEqual(session.clipboardReplayOnUnlock, "again")
        session.sendClipboardText("not stored")
        XCTAssertEqual(session.clipboardReplayOnUnlock, "again")
        session.disconnect()
        XCTAssertNil(session.clipboardReplayOnUnlock)
    }
}
