import CoreGraphics

/// 视口相对适配比例是否被放大。
///
/// 适配是完整画面（`RemoteViewportState.minimumScale`）。只比较缩放，
/// 平移不改变结果。`observe` 只在放大与回到适配之间翻转时给出新值。
struct ViewportZoomChange: Equatable, Sendable {
    private(set) var isZoomedBeyondFit = false

    mutating func observe(scale: CGFloat) -> Bool? {
        let zoomed = Self.isZoomedBeyondFit(scale)
        guard zoomed != isZoomedBeyondFit else { return nil }
        isZoomedBeyondFit = zoomed
        return zoomed
    }

    static func isZoomedBeyondFit(_ scale: CGFloat) -> Bool {
        scale.isFinite && scale > RemoteViewportState.minimumScale
    }
}
