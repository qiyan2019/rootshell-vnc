import Foundation
import XCTest
@testable import rootshellVNC

/// 手动放行的等待：测试决定每段等待何时结束。
private final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [CheckedContinuation<Void, Never>] = []
    private var durations: [Duration] = []

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                durations.append(duration)
                waits.append(continuation)
            }
        }
    }

    var pending: Int { lock.withLock { waits.count } }
    var requested: [Duration] { lock.withLock { durations } }

    func resumeFirst() {
        let wait = lock.withLock { waits.isEmpty ? nil : waits.removeFirst() }
        wait?.resume()
    }

    func resumeAll() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waits = [] }
            return waits
        }
        all.forEach { $0.resume() }
    }
}

@MainActor
final class UnlockStimulusTests: XCTestCase {
    private var locked = true
    private var fired = 0
    private let sleeper = ManualSleeper()

    private func makeScheduler() -> UnlockStimulusScheduler {
        let sleeper = sleeper
        return UnlockStimulusScheduler(
            sleep: { await sleeper.sleep($0) },
            isLocked: { [unowned self] in self.locked },
            fire: { [unowned self] in self.fired += 1 })
    }

    /// 让挂起的任务跑到下一个 await。
    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func resumeNextWait() async {
        await drain()
        XCTAssertGreaterThan(sleeper.pending, 0, "应该有一段等待")
        sleeper.resumeFirst()
        await drain()
    }

    func testReturnWhileLockedFiresAtBothDelays() async {
        let scheduler = makeScheduler()
        scheduler.noteKey(down: true, keysym: 0xFF0D)
        await resumeNextWait()
        XCTAssertEqual(fired, 1)
        await resumeNextWait()
        XCTAssertEqual(fired, 2)
        // 相对回车按下是 1.5 秒和 4 秒，所以第二段只等 2.5 秒。
        XCTAssertEqual(sleeper.requested, [.milliseconds(1500), .milliseconds(2500)])
        await drain()
        XCTAssertEqual(sleeper.pending, 0)
    }

    func testKeypadEnterAlsoArms() async {
        let scheduler = makeScheduler()
        scheduler.noteKey(down: true, keysym: 0xFF8D)
        await resumeNextWait()
        XCTAssertEqual(fired, 1)
        scheduler.cancel()
        sleeper.resumeAll()
    }

    func testOtherKeysAndKeyUpDoNotArm() async {
        let scheduler = makeScheduler()
        scheduler.noteKey(down: true, keysym: 0x61)
        scheduler.noteKey(down: false, keysym: 0xFF0D)
        await drain()
        XCTAssertEqual(sleeper.pending, 0)
    }

    func testReturnWhileUnlockedDoesNotArm() async {
        locked = false
        let scheduler = makeScheduler()
        scheduler.noteKey(down: true, keysym: 0xFF0D)
        await drain()
        XCTAssertEqual(sleeper.pending, 0)
    }

    /// 回到桌面就停，不再动指针。
    func testStopsOnceDesktopIsBack() async {
        let scheduler = makeScheduler()
        scheduler.noteKey(down: true, keysym: 0xFF0D)
        await resumeNextWait()
        XCTAssertEqual(fired, 1)
        locked = false
        await resumeNextWait()
        XCTAssertEqual(fired, 1)
        await drain()
        XCTAssertEqual(sleeper.pending, 0)
    }

    /// 再按一次回车，旧批次作废，从头计时。
    func testNewReturnSupersedesPendingBatch() async {
        let scheduler = makeScheduler()
        scheduler.noteKey(down: true, keysym: 0xFF0D)
        await drain()
        scheduler.noteKey(down: true, keysym: 0xFF0D)
        await drain()
        XCTAssertEqual(sleeper.pending, 2)
        // 放行旧批次的等待：它已作废，不触发。
        sleeper.resumeFirst()
        await drain()
        XCTAssertEqual(fired, 0)
        sleeper.resumeFirst()
        await drain()
        XCTAssertEqual(fired, 1)
        scheduler.cancel()
        sleeper.resumeAll()
    }

    /// 断开时取消，迟到的等待不触发。
    func testCancelStopsPendingBatch() async {
        let scheduler = makeScheduler()
        scheduler.noteKey(down: true, keysym: 0xFF0D)
        await drain()
        scheduler.cancel()
        sleeper.resumeAll()
        await drain()
        XCTAssertEqual(fired, 0)
    }

    func testNudgeMovesOnePixelThenBack() {
        XCTAssertEqual(
            UnlockStimulusScheduler.nudgePoints(x: 50, y: 30, framebufferWidth: 100),
            [.init(x: 51, y: 30), .init(x: 50, y: 30)])
    }

    /// 已在最右一列：往左移，坐标不出界。
    func testNudgeAtRightEdgeMovesLeft() {
        XCTAssertEqual(
            UnlockStimulusScheduler.nudgePoints(x: 99, y: 30, framebufferWidth: 100),
            [.init(x: 98, y: 30), .init(x: 99, y: 30)])
    }

    /// 还没发过指针：落点取画面中心。
    func testAnchorDefaultsToCenter() {
        XCTAssertEqual(
            UnlockStimulusScheduler.anchor(
                lastX: nil, lastY: nil, framebufferWidth: 100, framebufferHeight: 60),
            .init(x: 50, y: 30))
        XCTAssertEqual(
            UnlockStimulusScheduler.anchor(
                lastX: 7, lastY: 9, framebufferWidth: 100, framebufferHeight: 60),
            .init(x: 7, y: 9))
    }
}
