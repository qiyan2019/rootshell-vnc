import Foundation

/// 解锁后促重绘（同 Android V20-H）：Mac 报锁屏时按下回车，稍后补发两次指针事件。
/// Android 实测指针移动能促服务端刷新采集，否则解锁后画面可能还停在锁屏。回到桌面就停。
@MainActor
final class UnlockStimulusScheduler {
    struct Point: Equatable {
        let x: UInt16
        let y: UInt16
    }

    /// 主键盘 Return + 小键盘 Enter。
    nonisolated static let returnKeysyms: Set<UInt32> = [0xFF0D, 0xFF8D]
    /// 相对回车按下是 1.5 秒和 4 秒，这里写成相邻两段等待。
    nonisolated static let waits: [Duration] = [.milliseconds(1500), .milliseconds(2500)]

    private let sleep: @Sendable (Duration) async -> Void
    private let isLocked: () -> Bool
    private let fire: () -> Void
    private var task: Task<Void, Never>?

    init(
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        isLocked: @escaping () -> Bool,
        fire: @escaping () -> Void
    ) {
        self.sleep = sleep
        self.isLocked = isLocked
        self.fire = fire
    }

    /// 每个发出去的按键都过这里；只有锁屏时按下回车才排一批，新批次替换旧批次。
    func noteKey(down: Bool, keysym: UInt32) {
        guard down, Self.returnKeysyms.contains(keysym), isLocked() else { return }
        task?.cancel()
        task = Task { [sleep, weak self] in
            for wait in Self.waits {
                await sleep(wait)
                guard let self, !Task.isCancelled, self.isLocked() else { return }
                self.fire()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 落点是这条连接最近发过的指针位置；没发过取画面中心。
    nonisolated static func anchor(
        lastX: UInt16?,
        lastY: UInt16?,
        framebufferWidth: Int,
        framebufferHeight: Int
    ) -> Point {
        if let lastX, let lastY { return Point(x: lastX, y: lastY) }
        return Point(
            x: UInt16(clamping: framebufferWidth / 2),
            y: UInt16(clamping: framebufferHeight / 2))
    }

    /// 移 1 像素再移回，净坐标不变。已在最右一列时往左移，坐标不出界。
    nonisolated static func nudgePoints(x: UInt16, y: UInt16, framebufferWidth: Int) -> [Point] {
        let nudgedX = Int(x) + 1 < framebufferWidth ? x + 1 : (x > 0 ? x - 1 : x)
        return [Point(x: nudgedX, y: y), Point(x: x, y: y)]
    }
}
