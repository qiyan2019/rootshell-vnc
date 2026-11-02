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
}
