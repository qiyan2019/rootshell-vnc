import CoreGraphics
import Foundation
import XCTest

@testable import RFBProtocol
@testable import rootshellVNC

/// 首帧底图恢复：首帧门的强制放行，以及补发 / 放行的判定。
/// 背景见 `StandardInitialFrameRecoveryPolicy` 的说明。
final class StandardInitialFrameRecoveryTests: XCTestCase {
    private typealias Policy = StandardInitialFrameRecoveryPolicy
    private let second: UInt64 = 1_000_000_000

    // MARK: - 首帧门

    func testForcedPresentationKeepsTrackingCoverage() {
        var tracker = StandardInitialFramePresentationTracker()
        XCTAssertFalse(tracker.ingest(
            [dctRect(x: 0, y: 0, width: 8, height: 8, type: 0)],
            framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertEqual(tracker.uncoveredArea, 64)

        tracker.forcePresentation()
        XCTAssertFalse(tracker.suppressesPresentation)
        XCTAssertTrue(tracker.awaitsInitialCoverage)
        // 放行后的批次照常呈现，覆盖度继续累计。
        XCTAssertTrue(tracker.ingest(
            [dctRect(x: 0, y: 0, width: 4, height: 4, type: 1)],
            framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertTrue(tracker.awaitsInitialCoverage)

        XCTAssertTrue(tracker.ingest(
            [dctRect(x: 8, y: 0, width: 8, height: 8, type: 0)],
            framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertFalse(tracker.awaitsInitialCoverage)
        XCTAssertEqual(tracker.uncoveredArea, 0)
    }

    func testForcePresentationIsIgnoredOutsideTheDCTGate() {
        var tracker = StandardInitialFramePresentationTracker()
        tracker.forcePresentation()
        XCTAssertFalse(tracker.presentationForced)

        XCTAssertTrue(tracker.ingest(
            [dctRect(x: 0, y: 0, width: 16, height: 8, type: 0)],
            framebufferWidth: 16, framebufferHeight: 8))
        tracker.forcePresentation()
        XCTAssertFalse(tracker.presentationForced)
    }

    func testResetClearsForcedPresentation() {
        var tracker = StandardInitialFramePresentationTracker()
        _ = tracker.ingest(
            [dctRect(x: 0, y: 0, width: 0, height: 0, type: 2)],
            framebufferWidth: 16, framebufferHeight: 8)
        tracker.forcePresentation()
        tracker.reset()

        XCTAssertFalse(tracker.ingest(
            [dctRect(x: 0, y: 0, width: 0, height: 0, type: 2)],
            framebufferWidth: 16, framebufferHeight: 8))
        XCTAssertTrue(tracker.suppressesPresentation)
    }

    // MARK: - 补发

    /// 实测的卡死形态：变化区域一直在到，未覆盖面积不动。
    func testRenewsWhenOnlyChangedRegionsArrive() {
        var policy = Policy(startNanos: 0)
        XCTAssertFalse(policy.evaluate(sample(1, area: 100, batches: 2, bytes: 10)).renew)
        // 距开头那条请求满 2 秒、这一拍有批次但面积没缩小：补发。
        let decision = policy.evaluate(sample(2, area: 100, batches: 5, bytes: 30))
        XCTAssertTrue(decision.renew)
        XCTAssertEqual(decision.batchesSinceLastCheck, 3)
        XCTAssertEqual(decision.bytesSinceLastCheck, 20)
        XCTAssertEqual(policy.renewals, 1)
    }

    func testDoesNotRenewWhileCoverageGrows() {
        var policy = Policy(startNanos: 0)
        _ = policy.evaluate(sample(1, area: 100, batches: 1, bytes: 10))
        for tick in 2...9 {
            let area = Double(100 - tick * 10)
            XCTAssertFalse(
                policy.evaluate(sample(UInt64(tick), area: area, batches: UInt64(tick), bytes: UInt64(tick * 10))).renew,
                "tick \(tick)")
        }
        XCTAssertEqual(policy.renewals, 0)
    }

    /// 一条大的整帧消息还在路上：字节在进、没有批次应用完，不能叠加整帧请求。
    func testDoesNotRenewWhileAFrameIsStillArriving() {
        var policy = Policy(startNanos: 0)
        _ = policy.evaluate(sample(1, area: 100, batches: 0, bytes: 100))
        for tick in 2...12 {
            XCTAssertFalse(
                policy.evaluate(sample(UInt64(tick), area: 100, batches: 0, bytes: UInt64(tick * 100))).renew,
                "tick \(tick)")
        }
    }

    func testRenewsAfterDeadAir() {
        var policy = Policy(startNanos: 0)
        _ = policy.evaluate(sample(1, area: 100, batches: 0, bytes: 50))
        XCTAssertFalse(policy.evaluate(sample(2, area: 100, batches: 0, bytes: 50)).renew)
        XCTAssertFalse(policy.evaluate(sample(3, area: 100, batches: 0, bytes: 50)).renew)
        XCTAssertTrue(policy.evaluate(sample(4, area: 100, batches: 0, bytes: 50)).renew)
    }

    func testRenewalsBackOffAndStopAtTheLimit() {
        var policy = Policy(startNanos: 0)
        var renewedAt: [UInt64] = []
        var limitReports = 0
        _ = policy.evaluate(sample(1, area: 100, batches: 0, bytes: 0))
        for tick in UInt64(2)...60 {
            let decision = policy.evaluate(sample(tick, area: 100, batches: tick, bytes: tick))
            if decision.renew { renewedAt.append(tick) }
            if decision.reachedRenewalLimit { limitReports += 1 }
        }
        // 间隔 2、4、8 秒，之后都按 8 秒；最多 6 次。
        XCTAssertEqual(renewedAt, [2, 6, 14, 22, 30, 38])
        XCTAssertEqual(limitReports, 1)
        XCTAssertEqual(policy.renewals, Policy.maximumRenewals)
    }

    // MARK: - 先显示部分画面

    func testPresentsPartialFrameOnceAfterDelay() {
        var policy = Policy(startNanos: 0)
        var partialAt: [UInt64] = []
        for tick in UInt64(1)...15 {
            if policy.evaluate(sample(tick, area: 50, batches: tick, bytes: tick)).presentPartial {
                partialAt.append(tick)
            }
        }
        XCTAssertEqual(partialAt, [10])
        XCTAssertTrue(policy.presentedPartial)
    }

    /// 一个像素都没到时不放行，界面继续显示「正在接收画面」和字节停滞提示。
    func testDoesNotPresentWithoutAnyPixels() {
        var policy = Policy(startNanos: 0)
        for tick in UInt64(1)...20 {
            XCTAssertFalse(policy.evaluate(sample(tick, area: 100, batches: 0, bytes: 0)).presentPartial)
        }
    }

    // MARK: - 工具

    private func sample(
        _ seconds: UInt64,
        area: Double,
        batches: UInt64,
        bytes: UInt64
    ) -> Policy.Sample {
        Policy.Sample(
            nanos: seconds * second,
            uncoveredArea: area,
            appliedPixelBatches: batches,
            receivedBytes: bytes)
    }

    private func dctRect(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        type: UInt8
    ) -> (FramebufferRect, Data) {
        (FramebufferRect(
            x: UInt16(x), y: UInt16(y),
            width: UInt16(width), height: UInt16(height),
            encoding: .appleMultiVariantScreenshare),
         Data([0, 0, 0, 1, type]))
    }
}
