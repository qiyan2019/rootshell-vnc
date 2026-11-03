import Foundation
import RFBProtocol

/// Apple 自适应 DCT 矩形（encoding 1011）的解码器接口。宿主可以在建会话前
/// 注入自己的实现（比如 Agito 的 C 解码器），不注入就用内置 Swift 实现。
public protocol AppleDCTDecoding: AnyObject {
    /// 把一条完整 DCT 消息（含 4 字节长度前缀）解到帧缓冲的指定矩形。
    /// `drawPixels` 为 false 时只维护解码状态，不写像素。
    func render(
        rect: FramebufferRect, payload: Data, to framebuffer: Framebuffer,
        drawPixels: Bool
    ) throws

    /// 读走并清零：上次调用以来有没有写过帧缓冲。
    func takeDidWritePixels() -> Bool
}

/// 解码器工厂注册表。宿主在建任何会话之前注册一次；之后新建的
/// `FramebufferRenderer` 都用注册的实现。
public enum AppleDCTDecoderRegistry {
    private static let lock = NSLock()
    // 读写都在 lock 保护下，关掉编译器的并发安全检查。
    nonisolated(unsafe) private static var factory: (@Sendable () -> any AppleDCTDecoding)?

    /// 宿主在建任何会话之前注册一次；之后新建的 FramebufferRenderer 都用它。
    public static func register(_ factory: @escaping @Sendable () -> any AppleDCTDecoding) {
        lock.lock()
        self.factory = factory
        lock.unlock()
    }

    /// 宿主注册过就用宿主的，否则用内置 Swift 解码器。
    public static func makeDecoder() -> any AppleDCTDecoding {
        lock.lock()
        let factory = self.factory
        lock.unlock()
        return factory?() ?? AppleAdaptiveDCTDecoder()
    }

    /// 内置 Swift 解码器，给差分用例。
    public static func makeSwiftDecoder() -> any AppleDCTDecoding {
        AppleAdaptiveDCTDecoder()
    }

    /// 测试用：恢复成没注册过的状态。
    static func resetForTesting() {
        lock.lock()
        factory = nil
        lock.unlock()
    }
}
