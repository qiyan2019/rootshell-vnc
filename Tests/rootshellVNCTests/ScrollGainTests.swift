import CoreGraphics
import XCTest
@testable import rootshellVNC

/// ScrollGain / FlickStacker 的纯函数测试向量。计划 §2.1–2.3 的合同：
/// 常量以屏幕单位（iOS pt / Android dp）表达，两端数值一致；
/// s = 屏幕单位 / 远端点。改动前后的 point 差在报告里按同一张表对比。
final class ScrollGainTests: XCTestCase {

    // MARK: - 默认值

    func testDefaultTuningMatchesContract() {
        let t = RemoteScrollTuning.default
        XCTAssertEqual(t.vLo, 400)
        XCTAssertEqual(t.vHi, 2500)
        XCTAssertEqual(t.gMax, 2.5)
        XCTAssertEqual(t.zoomGainMin, 0.25)
        XCTAssertEqual(t.zoomGainMax, 8)
        XCTAssertEqual(t.horizontalMinGain, 2)
        XCTAssertEqual(t.flingMinSpeed, 25)
        XCTAssertEqual(t.flingMaxSpeed, 12_000)
        XCTAssertEqual(t.stopSpeed, 5)
        XCTAssertEqual(t.stackWindow, 0.8)
        XCTAssertEqual(t.stackFactor, 1)
        XCTAssertNil(t.remotePixelsPerPoint)
    }

    // MARK: - G_speed 分段边界

    func testSpeedGainBelowLowThresholdIsUnity() {
        XCTAssertEqual(ScrollGain.speedGain(forScreenSpeed: 0), 1)
        XCTAssertEqual(ScrollGain.speedGain(forScreenSpeed: 399.9), 1)
    }

    func testSpeedGainAtLowThresholdIsUnity() {
        XCTAssertEqual(ScrollGain.speedGain(forScreenSpeed: 400), 1)
    }

    func testSpeedGainRisesLinearlyBetweenThresholds() {
        // 线性中点：1 + (1450-400)/(2500-400) * (2.5-1) = 1.75
        XCTAssertEqual(
            ScrollGain.speedGain(forScreenSpeed: 1450), 1.75, accuracy: 1e-9)
        XCTAssertEqual(
            ScrollGain.speedGain(forScreenSpeed: 600), 1 + 200.0 / 2100 * 1.5,
            accuracy: 1e-9)
    }

    func testSpeedGainCapsAtHighThreshold() {
        XCTAssertEqual(ScrollGain.speedGain(forScreenSpeed: 2500), 2.5)
        XCTAssertEqual(ScrollGain.speedGain(forScreenSpeed: 2500.1), 2.5)
        XCTAssertEqual(ScrollGain.speedGain(forScreenSpeed: 100_000), 2.5)
    }

    // MARK: - G_zoom 缩放补偿与夹紧

    func testZoomGainCompensatesTypicalFit() {
        // s = 0.27：手机适配远端桌面，1/s ≈ 3.7
        XCTAssertEqual(
            ScrollGain.zoomGain(s: 0.27), 1 / 0.27, accuracy: 1e-9)
    }

    func testZoomGainAtUnityAndZoomedIn() {
        XCTAssertEqual(ScrollGain.zoomGain(s: 1), 1)
        XCTAssertEqual(ScrollGain.zoomGain(s: 2), 0.5)
    }

    func testZoomGainClampsToBounds() {
        // s = 5 → 1/s = 0.2 < 0.25 → 0.25
        XCTAssertEqual(ScrollGain.zoomGain(s: 5), 0.25)
        // s = 0.05 → 1/s = 20 > 8 → 8
        XCTAssertEqual(ScrollGain.zoomGain(s: 0.05), 8)
        // 恰好等于上下限
        XCTAssertEqual(ScrollGain.zoomGain(s: 0.125), 8)
        XCTAssertEqual(ScrollGain.zoomGain(s: 4), 0.25)
    }

    // MARK: - 拖动倍率（不锁定）

    func testDragGainCombinesZoomAndSpeed() {
        // s = 0.27, v = 200（慢） → 3.7037 × 1
        XCTAssertEqual(
            ScrollGain.dragGain(
                screenSpeed: 200, s: 0.27, horizontallyLocked: false),
            1 / 0.27, accuracy: 1e-9)
        // s = 0.27, v = 1450 → 3.7037 × 1.75 ≈ 6.481
        XCTAssertEqual(
            ScrollGain.dragGain(
                screenSpeed: 1450, s: 0.27, horizontallyLocked: false),
            1 / 0.27 * 1.75, accuracy: 1e-9)
        // s = 0.27, v = 3000 → 3.7037 × 2.5 ≈ 9.259
        XCTAssertEqual(
            ScrollGain.dragGain(
                screenSpeed: 3000, s: 0.27, horizontallyLocked: false),
            1 / 0.27 * 2.5, accuracy: 1e-9)
        // s = 2（放大）, v = 200 → 0.5 × 1
        XCTAssertEqual(
            ScrollGain.dragGain(
                screenSpeed: 200, s: 2, horizontallyLocked: false),
            0.5, accuracy: 1e-9)
    }

    // MARK: - 拖动倍率（横向锁定）

    func testDragGainHorizontalLockIgnoresSpeedGain() {
        // 锁定后下限 horizontalMinGain，不再乘 G_speed
        XCTAssertEqual(
            ScrollGain.dragGain(
                screenSpeed: 3000, s: 1, horizontallyLocked: true),
            2)
        XCTAssertEqual(
            ScrollGain.dragGain(
                screenSpeed: 3000, s: 2, horizontallyLocked: true),
            2)
        // s = 0.27 → 1/s ≈ 3.7 > 2，按缩放补偿走
        XCTAssertEqual(
            ScrollGain.dragGain(
                screenSpeed: 3000, s: 0.27, horizontallyLocked: true),
            1 / 0.27, accuracy: 1e-9)
        // s = 5 → clamp 后 0.25，仍取下限 2
        XCTAssertEqual(
            ScrollGain.dragGain(
                screenSpeed: 3000, s: 5, horizontallyLocked: true),
            2)
    }

    // MARK: - 惯性初速

    func testMomentumBelowMinSpeedProducesNoFling() {
        XCTAssertNil(ScrollGain.momentumInitialVelocity(
            releaseVelocity: CGPoint(x: 0, y: -24.9),
            s: 1, horizontallyLocked: false))
        // (17, 17) 模长 24.04 < 25，斜向低速也不进惯性
        XCTAssertNil(ScrollGain.momentumInitialVelocity(
            releaseVelocity: CGPoint(x: 17, y: 17),
            s: 1, horizontallyLocked: false))
    }

    func testMomentumAtMinSpeedProducesFling() {
        let initial = ScrollGain.momentumInitialVelocity(
            releaseVelocity: CGPoint(x: 0, y: -25),
            s: 1, horizontallyLocked: false)
        XCTAssertNotNil(initial)
        XCTAssertEqual(initial?.screenVelocity.y ?? 0, -25, accuracy: 1e-9)
    }

    func testMomentumAppliesZoomAndSpeedGain() {
        // v = 2000, s = 0.27 → G_speed = 1 + 1600/2100*1.5 ≈ 2.143
        let initial = ScrollGain.momentumInitialVelocity(
            releaseVelocity: CGPoint(x: 0, y: -2000),
            s: 0.27, horizontallyLocked: false)
        let expectedGain = (1 / 0.27) * (1 + 1600.0 / 2100 * 1.5)
        XCTAssertEqual(initial?.gain ?? 0, expectedGain, accuracy: 1e-9)
        // 屏幕初速保持原值，远端换算乘 gain
        XCTAssertEqual(initial?.screenVelocity.y ?? 0, -2000, accuracy: 1e-9)
    }

    func testMomentumCapsAtMaxScreenSpeed() throws {
        // |v| = 17000 > 12000 → 先按屏幕速度收到 12000
        let initial = ScrollGain.momentumInitialVelocity(
            releaseVelocity: CGPoint(x: 8000, y: 15_000),
            s: 1, horizontallyLocked: false)
        let v = try XCTUnwrap(initial)
        XCTAssertEqual(
            hypot(v.screenVelocity.x, v.screenVelocity.y), 12_000, accuracy: 1e-6)
        // 上限之后仍乘 gain（G_speed 取 |v释放| = 17000 → gMax）
        XCTAssertEqual(v.gain, 2.5, accuracy: 1e-9)
    }

    func testMomentumHorizontalLockDropsVerticalComponent() throws {
        let initial = ScrollGain.momentumInitialVelocity(
            releaseVelocity: CGPoint(x: 3000, y: 800),
            s: 1, horizontallyLocked: true)
        let v = try XCTUnwrap(initial)
        XCTAssertEqual(v.screenVelocity.y, 0)
        XCTAssertEqual(v.screenVelocity.x, 3000, accuracy: 1e-9)
        // gain 用 |v释放| = 3104.6 → gMax
        XCTAssertEqual(v.gain, 2.5, accuracy: 1e-9)
    }

    // MARK: - 惯性停止判断

    func testMomentumStopThresholdUsesRemoteSpeedTimesS() {
        // 远端速度 × s < 5 才停
        XCTAssertFalse(ScrollGain.shouldStopMomentum(remoteSpeed: 20, s: 0.27))
        XCTAssertTrue(ScrollGain.shouldStopMomentum(remoteSpeed: 18, s: 0.27))
        XCTAssertTrue(ScrollGain.shouldStopMomentum(remoteSpeed: 4, s: 1))
        // 恰好在阈值上不停（严格小于）
        XCTAssertFalse(ScrollGain.shouldStopMomentum(remoteSpeed: 5, s: 1))
    }

    // MARK: - 惯性衰减步进

    func testMomentumDecayUsesNormalDecelerationRate() {
        // UIScrollView .normal 减速率：0.998 / 毫秒，elapsed 是秒
        let v = ScrollGain.decayedMomentumVelocity(
            CGPoint(x: 1000, y: -2000), elapsed: 0.0167)
        let factor = pow(0.998 as CGFloat, 16.7)
        XCTAssertEqual(v.x, 1000 * factor, accuracy: 1e-6)
        XCTAssertEqual(v.y, -2000 * factor, accuracy: 1e-6)
    }

    func testMomentumDecayCompoundsAcrossSteps() {
        // 两步 16.7ms 与一步 33.4ms 等价
        var v = CGPoint(x: 0, y: -4000)
        v = ScrollGain.decayedMomentumVelocity(v, elapsed: 0.0167)
        v = ScrollGain.decayedMomentumVelocity(v, elapsed: 0.0167)
        XCTAssertEqual(
            v.y, -4000 * pow(0.998 as CGFloat, 33.4), accuracy: 1e-6)
    }

    // MARK: - FlickStacker 叠加

    func testFlickStackSameDirectionAddsVelocity() {
        var stacker = FlickStacker()
        stacker.recordCatch(
            velocity: CGPoint(x: 0, y: -3000), at: 10)
        let stacked = stacker.stackedReleaseVelocity(
            CGPoint(x: 0, y: -2000), at: 10.3)
        XCTAssertEqual(stacked.y, -5000, accuracy: 1e-9)
        XCTAssertEqual(stacked.x, 0)
    }

    func testFlickStackOppositeDirectionDoesNotAdd() {
        var stacker = FlickStacker()
        stacker.recordCatch(
            velocity: CGPoint(x: 0, y: -3000), at: 10)
        let stacked = stacker.stackedReleaseVelocity(
            CGPoint(x: 0, y: 2000), at: 10.3)
        XCTAssertEqual(stacked.y, 2000)
    }

    func testFlickStackExpiresAfterWindow() {
        var stacker = FlickStacker()
        stacker.recordCatch(
            velocity: CGPoint(x: 0, y: -3000), at: 10)
        let stacked = stacker.stackedReleaseVelocity(
            CGPoint(x: 0, y: -2000), at: 10.9)
        XCTAssertEqual(stacked.y, -2000)
        // 恰好在窗口内仍算（0.8 - 0 可精确表示，10.8 - 10 浮点会溢出窗口）
        stacker.recordCatch(
            velocity: CGPoint(x: 0, y: -3000), at: 0)
        XCTAssertEqual(
            stacker.stackedReleaseVelocity(
                CGPoint(x: 0, y: -2000), at: 0.8).y,
            -5000, accuracy: 1e-9)
    }

    func testFlickStackRequiresReleaseAboveMinSpeed() {
        var stacker = FlickStacker()
        stacker.recordCatch(
            velocity: CGPoint(x: 0, y: -3000), at: 10)
        let stacked = stacker.stackedReleaseVelocity(
            CGPoint(x: 0, y: -20), at: 10.3)
        XCTAssertEqual(stacked.y, -20)
    }

    func testFlickStackIsConsumedOnce() {
        var stacker = FlickStacker()
        stacker.recordCatch(
            velocity: CGPoint(x: 0, y: -3000), at: 10)
        _ = stacker.stackedReleaseVelocity(
            CGPoint(x: 0, y: -2000), at: 10.3)
        // 第二次抬手不再叠加
        XCTAssertEqual(
            stacker.stackedReleaseVelocity(
                CGPoint(x: 0, y: -2000), at: 10.4).y,
            -2000)
    }

    func testFlickStackWithoutCatchPassesThrough() {
        var stacker = FlickStacker()
        XCTAssertEqual(
            stacker.stackedReleaseVelocity(
                CGPoint(x: 0, y: -2000), at: 10).y,
            -2000)
    }

    func testFlickStackThenMomentumCapsAtMaxSpeed() throws {
        // 叠加后再进惯性门槛/上限：9000 + 8000 = 17000 → 12000
        var stacker = FlickStacker()
        stacker.recordCatch(
            velocity: CGPoint(x: 0, y: -9000), at: 0)
        let stacked = stacker.stackedReleaseVelocity(
            CGPoint(x: 0, y: -8000), at: 0.2)
        let initial = try XCTUnwrap(ScrollGain.momentumInitialVelocity(
            releaseVelocity: stacked, s: 1, horizontallyLocked: false))
        XCTAssertEqual(
            hypot(initial.screenVelocity.x, initial.screenVelocity.y),
            12_000, accuracy: 1e-6)
    }

    // MARK: - P（帧缓冲像素 / 远端 point）解析

    func testRemotePixelsPerPointResolution() {
        XCTAssertEqual(
            ScrollGain.resolvedRemotePixelsPerPoint(
                override: 3, isAppleVirtualDisplay: true), 3)
        XCTAssertEqual(
            ScrollGain.resolvedRemotePixelsPerPoint(
                override: nil, isAppleVirtualDisplay: true), 2)
        XCTAssertEqual(
            ScrollGain.resolvedRemotePixelsPerPoint(
                override: nil, isAppleVirtualDisplay: false), 1)
    }

    // MARK: - 接线顺序（屏幕增量 → 过滤 → 增益 → 取整）

    /// 与 RemoteInputUIView 相同的调用顺序：
    /// HorizontalScrollIntentFilter.consume → ScrollGain.dragGain →
    /// ScrollPointAccumulator.consume。验证同一手势的样本按增益放大后取整。
    func testDirectScrollPipelineAppliesGain() {
        var filter = HorizontalScrollIntentFilter()
        var accumulator = ScrollPointAccumulator()
        let tuning = RemoteScrollTuning.default
        let s: CGFloat = 0.27

        // 慢速竖拖 10pt：G_speed = 1 → 远端点 = 10 / 0.27 ≈ 37
        var filtered = filter.consume(deltaX: 0, deltaY: -10)
        var gain = ScrollGain.dragGain(
            screenSpeed: 200, s: s,
            horizontallyLocked: filter.isHorizontallyLocked,
            tuning: tuning)
        var points = accumulator.consume(
            deltaX: filtered.x * gain, deltaY: filtered.y * gain)
        XCTAssertEqual(points.y, -37)

        // 快速竖拖 10pt：v = 3000 → G_speed = 2.5 → ≈ 92.6 → 92
        filtered = filter.consume(deltaX: 0, deltaY: -10)
        gain = ScrollGain.dragGain(
            screenSpeed: 3000, s: s,
            horizontallyLocked: filter.isHorizontallyLocked,
            tuning: tuning)
        points = accumulator.consume(
            deltaX: filtered.x * gain, deltaY: filtered.y * gain)
        XCTAssertEqual(points.y, -92)
    }

    /// 横向锁定：增益 max(2, 1/s)，且 y 已被过滤器清零。
    func testDirectScrollPipelineHorizontalLock() {
        var filter = HorizontalScrollIntentFilter()
        var accumulator = ScrollPointAccumulator()
        let tuning = RemoteScrollTuning.default
        let s: CGFloat = 1

        // 明显的横向滑动触发锁定（pending ≥4 且 x 占优 1.25 倍）
        let filtered = filter.consume(deltaX: -10, deltaY: 1)
        XCTAssertTrue(filter.isHorizontallyLocked)
        XCTAssertEqual(filtered.y, 0)
        let gain = ScrollGain.dragGain(
            screenSpeed: 3000, s: s,
            horizontallyLocked: filter.isHorizontallyLocked,
            tuning: tuning)
        let points = accumulator.consume(
            deltaX: filtered.x * gain, deltaY: filtered.y * gain)
        XCTAssertEqual(points.x, -20)
        XCTAssertEqual(points.y, 0)
    }
}
