import SwiftUI
import XCTest
@testable import rootshellVNC

final class LoginPasswordPromptRouteTests: XCTestCase {
    func testAutomaticNilConsumesPendingEvenWhenSendIsUnavailable() {
        XCTAssertEqual(
            LoginPasswordPromptRoute.automatic(
                hostHandlesRequest: false,
                pending: true,
                canSend: true),
            .presentBuiltIn(consumingPending: true))
        XCTAssertEqual(
            LoginPasswordPromptRoute.automatic(
                hostHandlesRequest: false,
                pending: true,
                canSend: false),
            .presentBuiltIn(consumingPending: true))
    }

    func testAutomaticNilWithoutPendingDoesNothing() {
        XCTAssertEqual(
            LoginPasswordPromptRoute.automatic(
                hostHandlesRequest: false,
                pending: false,
                canSend: true),
            .ignore)
    }

    func testAutomaticHostLeavesPendingUntouched() {
        XCTAssertEqual(
            LoginPasswordPromptRoute.automatic(
                hostHandlesRequest: true,
                pending: true,
                canSend: true),
            .ignore)
        XCTAssertEqual(
            LoginPasswordPromptRoute.automatic(
                hostHandlesRequest: true,
                pending: true,
                canSend: false),
            .ignore)
    }

    func testManualNilPresentsOnlyWhenSendIsAllowed() {
        XCTAssertEqual(
            LoginPasswordPromptRoute.manual(
                hostHandlesRequest: false,
                canSend: true),
            .presentBuiltIn(consumingPending: false))
        XCTAssertEqual(
            LoginPasswordPromptRoute.manual(
                hostHandlesRequest: false,
                canSend: false),
            .ignore)
    }

    func testManualHostIsNotifiedOnlyWhenSendIsAllowed() {
        XCTAssertEqual(
            LoginPasswordPromptRoute.manual(
                hostHandlesRequest: true,
                canSend: true),
            .notifyHost)
        XCTAssertEqual(
            LoginPasswordPromptRoute.manual(
                hostHandlesRequest: true,
                canSend: false),
            .ignore)
    }

    @MainActor
    func testBothPublicInitsAcceptLoginPasswordCallback() {
        let session = VNCSession()
        let plain = RemoteDesktopView(
            session: session,
            onLoginPasswordRequest: {})
        let extras = RemoteDesktopView(
            session: session,
            onLoginPasswordRequest: {}
        ) {
            EmptyView()
        }
        _ = (plain, extras)
    }
}
