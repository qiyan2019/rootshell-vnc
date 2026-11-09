import CoreGraphics
import RFBProtocol
import XCTest
@testable import rootshellVNC

final class RemoteDisplaySelectionTests: XCTestCase {
    @MainActor
    func testRemoteDisplaysFollowAnnouncementOrderAndDropEmptyRecords() async {
        let session = VNCSession()
        await session.updateRemoteDisplayRegions([
            AppleDisplayInfo(
                displayIndex: 4,
                originX: 1920, originY: 0,
                width: 800, height: 600,
                flags: 0),
            AppleDisplayInfo(
                displayIndex: 1,
                originX: 0, originY: 0,
                width: 0, height: 0,
                flags: 0),
            AppleDisplayInfo(
                displayIndex: 9,
                originX: 0, originY: 100,
                width: 100, height: 200,
                flags: 1),
        ])

        XCTAssertEqual(session.remoteDisplays, [
            VNCRemoteDisplay(
                id: 4,
                origin: CGPoint(x: 1920, y: 0),
                size: CGSize(width: 800, height: 600)),
            VNCRemoteDisplay(
                id: 9,
                origin: CGPoint(x: 0, y: 100),
                size: CGSize(width: 100, height: 200)),
        ])
    }

    /// 手动切屏后不能再按第一块显示器裁剪，否则会采样到帧缓冲之外。
    @MainActor
    func testManualSelectionPresentsWholeFramebuffer() async {
        let session = VNCSession()
        await session.updateRemoteDisplayRegions([
            AppleDisplayInfo(
                displayIndex: 5, originX: 2992, originY: 0,
                width: 3840, height: 2160, flags: 0),
            AppleDisplayInfo(
                displayIndex: 1, originX: 0, originY: 0,
                width: 2992, height: 1934, flags: 0),
        ])
        session.framebufferWidth = 2992
        session.framebufferHeight = 1934
        XCTAssertNotNil(session.presentedFramebufferRegion)

        session.presentsWholeFramebuffer = true
        XCTAssertNil(session.presentedFramebufferRegion)
        XCTAssertEqual(session.presentedFramebufferSize, CGSize(width: 2992, height: 1934))
    }

    @MainActor
    func testSelectRemoteDisplayRefusesWhenNothingIsConnected() async {
        let session = VNCSession()
        let disconnectedCombined = await session.selectRemoteDisplay(id: nil)
        let disconnectedSpecific = await session.selectRemoteDisplay(id: 1)
        XCTAssertFalse(disconnectedCombined)
        XCTAssertFalse(disconnectedSpecific)

        await session.updateRemoteDisplayRegions([
            AppleDisplayInfo(
                displayIndex: 4,
                originX: 0, originY: 0,
                width: 10, height: 10,
                flags: 0),
        ])
        let known = await session.selectRemoteDisplay(id: 4)
        let unknown = await session.selectRemoteDisplay(id: 99)
        XCTAssertFalse(known)
        XCTAssertFalse(unknown)
    }
}
