import CoreGraphics
import SwiftUI
import XCTest
@testable import rootshellVNC

final class ViewportZoomChangeTests: XCTestCase {
    private let fit = RemoteViewportState.minimumScale

    func testFitScaleDoesNotEmit() {
        var change = ViewportZoomChange()

        XCTAssertNil(change.observe(scale: fit))
        XCTAssertFalse(change.isZoomedBeyondFit)
        XCTAssertNil(change.observe(scale: fit))
    }

    func testCrossingAboveFitEmitsTrueOnce() {
        var change = ViewportZoomChange()

        XCTAssertEqual(change.observe(scale: fit * 2), true)
        XCTAssertTrue(change.isZoomedBeyondFit)
        XCTAssertNil(change.observe(scale: fit * 3))
        XCTAssertNil(change.observe(scale: fit + 0.001))
    }

    func testReturningToFitEmitsFalseOnce() {
        var change = ViewportZoomChange()
        XCTAssertEqual(change.observe(scale: 4), true)

        XCTAssertEqual(change.observe(scale: fit), false)
        XCTAssertFalse(change.isZoomedBeyondFit)
        XCTAssertNil(change.observe(scale: fit))
    }

    func testZoomThenResetThenZoomAgain() {
        var change = ViewportZoomChange()

        XCTAssertEqual(change.observe(scale: 2), true)
        XCTAssertNil(change.observe(scale: 2.5))
        XCTAssertEqual(change.observe(scale: fit), false)
        XCTAssertEqual(change.observe(scale: 1.25), true)
        XCTAssertEqual(change.observe(scale: fit), false)
    }

    func testBelowFitAndNonFiniteAreNotZoomed() {
        var change = ViewportZoomChange()
        XCTAssertEqual(change.observe(scale: 2), true)

        XCTAssertEqual(change.observe(scale: 0), false)
        XCTAssertNil(change.observe(scale: .nan))
        XCTAssertNil(change.observe(scale: .infinity))
        XCTAssertNil(change.observe(scale: -.infinity))
        XCTAssertFalse(change.isZoomedBeyondFit)
    }

    /// 两个 public init 都接这三个可选参数；不传时仍能按上游方式构造。
    @MainActor
    func testBothPublicInitsAcceptHostHooks() {
        let session = VNCSession()
        var mode = RemotePointerMode.trackpad
        let binding = Binding(get: { mode }, set: { mode = $0 })
        let plain = RemoteDesktopView(
            session: session,
            showsBuiltInControls: false,
            pointerMode: binding,
            onViewportZoomChange: { _ in })
        let extras = RemoteDesktopView(
            session: session,
            showsBuiltInControls: false,
            pointerMode: binding,
            onViewportZoomChange: { _ in }
        ) {
            EmptyView()
        }
        let defaults = RemoteDesktopView(session: session)
        _ = (plain, extras, defaults)
    }
}
