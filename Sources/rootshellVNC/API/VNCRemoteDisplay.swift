import CoreGraphics

/// 一块已经发现的远端显示器。
///
/// `id` 是 Apple DisplayInfo 里的 displayIndex。原点是服务端桌面坐标里的左上角。
public struct VNCRemoteDisplay: Equatable, Sendable, Identifiable {
    public let id: UInt32
    public let origin: CGPoint
    public let size: CGSize

    public init(id: UInt32, origin: CGPoint, size: CGSize) {
        self.id = id
        self.origin = origin
        self.size = size
    }
}
