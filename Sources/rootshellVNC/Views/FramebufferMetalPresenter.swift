import CoreGraphics
import Foundation
import Metal
import QuartzCore
import RFBProtocol
import RFBRendering

/// 画面视口。语义和被替换的 SwiftUI 布局一致：
/// `.aspectRatio(.fit)` + `.frame(viewSize)` + `.scaleEffect(scale)` + `.offset(offset)`。
struct FramebufferViewport: Equatable, Sendable {
    /// 视图尺寸（点）。
    var viewSize: CGSize
    /// 相对 aspect-fit 的放大倍数，1 是整屏。
    var scale: CGFloat
    /// 相对居中位置的平移（点）。
    var offset: CGSize
    /// 只显示帧缓冲的这一部分（选显示器时），单位是帧缓冲像素。nil 表示全部。
    var sourceRegion: CGRect?
}

/// 一帧的绘制参数。内存布局和着色器里的 `Uniforms` 一一对应。
struct FramebufferQuadGeometry: Equatable {
    /// 画面四边形在裁剪空间的中心（y 朝上）。
    var center: SIMD2<Float>
    /// 画面四边形在裁剪空间的半宽、半高。
    var halfSize: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    /// 一个屏幕物理像素在纹理坐标里有多大，缩小取平均时用。
    var uvPerPixel: SIMD2<Float>
    /// 每个方向的采样次数。
    var taps: Int32

    /// 单次采样的上限：再高对画质没有可见帮助，只增加 GPU 负担。
    private static let maximumTaps = 4

    init(framebufferSize: CGSize, viewport: FramebufferViewport, drawablePixelSize: CGSize) {
        let source = viewport.sourceRegion
            ?? CGRect(origin: .zero, size: framebufferSize)
        let view = viewport.viewSize
        let fit = min(view.width / max(1, source.width), view.height / max(1, source.height))
        let drawnWidth = source.width * fit * viewport.scale
        let drawnHeight = source.height * fit * viewport.scale
        let centerX = view.width / 2 + viewport.offset.width
        let centerY = view.height / 2 + viewport.offset.height

        center = SIMD2(
            Float(centerX / max(1, view.width) * 2 - 1),
            Float(1 - centerY / max(1, view.height) * 2))
        halfSize = SIMD2(
            Float(drawnWidth / max(1, view.width)),
            Float(drawnHeight / max(1, view.height)))
        uvOrigin = SIMD2(
            Float(source.minX / max(1, framebufferSize.width)),
            Float(source.minY / max(1, framebufferSize.height)))
        uvSize = SIMD2(
            Float(source.width / max(1, framebufferSize.width)),
            Float(source.height / max(1, framebufferSize.height)))

        let pixelsPerPoint = drawablePixelSize.width / max(1, view.width)
        let drawnPixelWidth = max(1, drawnWidth * pixelsPerPoint)
        let drawnPixelHeight = max(1, drawnHeight * pixelsPerPoint)
        uvPerPixel = SIMD2(
            uvSize.x / Float(drawnPixelWidth),
            uvSize.y / Float(drawnPixelHeight))

        // 每次采样是双线性，本身覆盖约 2 个源像素，所以按缩小倍数的一半取整。
        let minification = max(
            source.width / drawnPixelWidth,
            source.height / drawnPixelHeight)
        let wanted = Int((minification / 2).rounded(.up))
        taps = Int32(max(1, min(Self.maximumTaps, wanted)))
    }
}

/// 把帧缓冲直接当纹理画到 `CAMetalLayer`。
///
/// 解码写的就是纹理底下那块内存，没有上传，也没有整帧图片；主线程不参与逐帧绘制。
/// 整帧画面走的路径从「整帧快照 → SwiftUI 重绘位图 → 渲染服务合成」变成一次 GPU 采样。
///
/// 两个入口：
/// - `presentFrame(from:)`：解码队列在一批矩形写完后调用，等 GPU 读完才返回，
///   所以下一批写入不会混进这一帧，画面保持按批原子。
/// - `requestRedraw()`：视口或布局变了，异步重画，不等解码。手势跟手优先，
///   恰逢解码写到一半时这一帧可能带着半批内容，下一帧立刻纠正。
final class FramebufferMetalPresenter: @unchecked Sendable {

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let redrawQueue = DispatchQueue(
        label: "rootshell.framebuffer-metal-redraw",
        qos: .userInteractive)

    /// 保护下面这组状态，持有时间极短，不在里面做 GPU 操作。
    private let stateLock = NSLock()
    private var framebuffer: Framebuffer?
    private var viewport: FramebufferViewport?
    private weak var layer: CAMetalLayer?
    /// 会话这边（页面关闭、后台）。
    private var isPresentationAllowed = true
    /// 视图这边（不在窗口里、App 失活）。两边都放行才画，互相不能覆盖。
    private var isViewPresentationAllowed = true
    private var redrawPending = false
    private var presentRequests = 0
    private var framesPresented = 0

    /// 串行化绘制。`nextDrawable()` 可能阻塞，所以和 `stateLock` 分开。
    private let drawLock = NSLock()
    private var pipeline: (any MTLRenderPipelineState)?
    private var sampler: (any MTLSamplerState)?
    private var textureStorage: FramebufferStorage?
    private var texture: (any MTLTexture)?
    private var texturesCreated = 0
    /// 最后提交的命令，排空时等它。
    private var lastCommandBuffer: (any MTLCommandBuffer)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        // 采样时区分绘制来源：GPU 统计里这条队列标成屏幕共享呈现。
        commandQueue.label = "agito.vnc.present"
        self.device = device
        self.commandQueue = commandQueue
    }

    /// 这条路径只处理 32 位帧缓冲；16 位「千色」继续走图片路径。
    static func supports(pixelFormat: PixelFormat) -> Bool {
        pixelFormat.bytesPerPixel == 4
    }

    // MARK: - 状态（任意线程）

    func attach(layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.presentsWithTransaction = false
        // 帧缓冲按 sRGB 显示（和原来的 DeviceRGB 图片一致），广色域屏由系统做颜色匹配。
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        stateLock.withLock { self.layer = layer }
    }

    func setViewport(_ viewport: FramebufferViewport) {
        stateLock.withLock { self.viewport = viewport }
    }

    /// 会话这边的开关：页面关闭、App 进后台时由会话关掉。
    func setPresentationAllowed(_ allowed: Bool) {
        stateLock.withLock { isPresentationAllowed = allowed }
    }

    /// 视图这边的开关。关掉之后不碰 GPU：后台提交命令会失败，
    /// 设备锁屏时还在用 Metal 画会被系统直接杀掉（"insecure drawing while in secure mode"）。
    func setViewPresentationAllowed(_ allowed: Bool) {
        stateLock.withLock { isViewPresentationAllowed = allowed }
    }

    /// 等手里的 GPU 工作做完。先关门再调：iOS 在 willResignActive 返回后立刻抓场景快照，
    /// 不能留一帧还在绘制（Ghostty 终端同样要在这一刻排空渲染器）。
    func drainToIdle() {
        // 拿到锁说明没有正在编码的一帧；之后门已关，不会再有新的。
        let commandBuffer = drawLock.withLock { lastCommandBuffer }
        commandBuffer?.waitUntilCompleted()
    }

    /// 还有命令没做完。
    var isGPUBusy: Bool {
        guard let status = drawLock.withLock({ lastCommandBuffer?.status }) else { return false }
        return status != .completed && status != .error
    }

    /// 换帧缓冲但不立刻画（重连后第一帧出来之前继续显示旧画面）。
    func setFramebuffer(_ framebuffer: Framebuffer) {
        stateLock.withLock { self.framebuffer = framebuffer }
    }

    /// 解码线程发起过多少次呈现。
    var presentRequestCount: Int { stateLock.withLock { presentRequests } }
    /// 实际提交给 GPU 的帧数。
    var framesPresentedCount: Int { stateLock.withLock { framesPresented } }
    var textureCreationCount: Int { drawLock.withLock { texturesCreated } }

    // MARK: - 绘制

    /// 在解码队列上调用。返回时 GPU 已经读完，帧缓冲可以继续写。
    @discardableResult
    func presentFrame(from framebuffer: Framebuffer) -> Bool {
        stateLock.withLock {
            self.framebuffer = framebuffer
            presentRequests += 1
        }
        return draw(waitUntilCompleted: true)
    }

    /// 视口变了或页面回到前台时重画。连续请求会合并。
    func requestRedraw() {
        let shouldSchedule = stateLock.withLock { () -> Bool in
            guard !redrawPending else { return false }
            redrawPending = true
            return true
        }
        guard shouldSchedule else { return }
        redrawQueue.async { [self] in
            stateLock.withLock { redrawPending = false }
            draw(waitUntilCompleted: false)
        }
    }

    private struct DrawState {
        let framebuffer: Framebuffer
        let viewport: FramebufferViewport
        let layer: CAMetalLayer
    }

    @discardableResult
    private func draw(waitUntilCompleted: Bool) -> Bool {
        drawLock.lock()
        defer { drawLock.unlock() }

        // 门控要在绘制锁里查：`drainToIdle` 拿到锁之后，后来者一定看到门已关，不会漏一帧。
        let state = stateLock.withLock { () -> DrawState? in
            guard isPresentationAllowed, isViewPresentationAllowed,
                  let framebuffer, let viewport, let layer else { return nil }
            return DrawState(framebuffer: framebuffer, viewport: viewport, layer: layer)
        }
        guard let state else { return false }

        let info = state.framebuffer.presentationStorage()
        let drawableSize = state.layer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0,
              let texture = currentTexture(for: info),
              let pipeline = currentPipeline(),
              let sampler = currentSampler(),
              let drawable = state.layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        var geometry = FramebufferQuadGeometry(
            framebufferSize: CGSize(width: info.width, height: info.height),
            viewport: state.viewport,
            drawablePixelSize: drawableSize)
        guard encode(
            into: commandBuffer,
            target: drawable.texture,
            source: texture,
            pipeline: pipeline,
            sampler: sampler,
            geometry: &geometry) else { return false }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
        stateLock.withLock { framesPresented += 1 }
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
        }
        return true
    }

    private func encode(
        into commandBuffer: any MTLCommandBuffer,
        target: any MTLTexture,
        source: any MTLTexture,
        pipeline: any MTLRenderPipelineState,
        sampler: any MTLSamplerState,
        geometry: inout FramebufferQuadGeometry
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        // 留黑透明，透出宿主页底色。
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&geometry, length: MemoryLayout<FramebufferQuadGeometry>.stride, index: 0)
        encoder.setFragmentBytes(&geometry, length: MemoryLayout<FramebufferQuadGeometry>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    // MARK: - 资源（持有 drawLock）

    /// 帧缓冲的 IOSurface 直接映射成纹理。解码写内存，GPU 下一帧就读到，不需要上传。
    /// 只有 resize 换了内存才会重建。纹理持有 IOSurface，命令缓冲还在用旧纹理时旧内存不会被释放。
    private func currentTexture(for info: FramebufferPresentationStorage) -> (any MTLTexture)? {
        if textureStorage === info.storage, let texture { return texture }
        guard let surface = info.storage.surface else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: info.width,
            height: info.height,
            mipmapped: false)
        descriptor.usage = .shaderRead
        guard let created = device.makeTexture(
            descriptor: descriptor,
            iosurface: surface,
            plane: 0)
        else { return nil }
        texture = created
        textureStorage = info.storage
        texturesCreated += 1
        return created
    }

    /// 着色器从源码编译：不给包加资源，也不依赖构建机的 Metal 工具链。
    /// 放在第一次绘制时（解码队列或重画队列），不占主线程。
    private func currentPipeline() -> (any MTLRenderPipelineState)? {
        if let pipeline { return pipeline }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "framebufferVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "framebufferFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let created = try device.makeRenderPipelineState(descriptor: descriptor)
            pipeline = created
            return created
        } catch {
            VNCLogger(category: "FramebufferMetal").error(
                "Framebuffer pipeline failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func currentSampler() -> (any MTLSamplerState)? {
        if let sampler { return sampler }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: descriptor)
        return sampler
    }

    /// 第四字节是 depth-24 填充（有的服务端发 0），一律按不透明处理。
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 center;
        float2 halfSize;
        float2 uvOrigin;
        float2 uvSize;
        float2 uvPerPixel;
        int taps;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut framebufferVertex(uint vertexID [[vertex_id]],
                                       constant Uniforms &uniforms [[buffer(0)]]) {
        // 三角形带：左上、右上、左下、右下。
        float2 corner = float2((vertexID & 1) ? 1.0 : -1.0, (vertexID & 2) ? -1.0 : 1.0);
        VertexOut out;
        out.position = float4(uniforms.center + corner * uniforms.halfSize, 0.0, 1.0);
        out.uv = uniforms.uvOrigin
            + float2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5) * uniforms.uvSize;
        return out;
    }

    fragment float4 framebufferFragment(VertexOut in [[stage_in]],
                                        constant Uniforms &uniforms [[buffer(0)]],
                                        texture2d<float> source [[texture(0)]],
                                        sampler linearSampler [[sampler(0)]]) {
        int taps = uniforms.taps;
        if (taps <= 1) {
            return float4(source.sample(linearSampler, in.uv).rgb, 1.0);
        }
        // 缩小时在一个屏幕像素的覆盖范围内均匀取样后平均，避免文字闪烁。
        float3 sum = float3(0.0);
        for (int y = 0; y < taps; y++) {
            for (int x = 0; x < taps; x++) {
                float2 position = (float2(x, y) + 0.5) / float(taps) - 0.5;
                sum += source.sample(linearSampler, in.uv + position * uniforms.uvPerPixel).rgb;
            }
        }
        return float4(sum / float(taps * taps), 1.0);
    }
    """

    // MARK: - 测试

    /// 把当前状态画进一张离屏纹理并读回（BGRA 8 位，从上到下）。
    /// 和屏幕走同一套纹理、管线和编码，只是目标不同。
    func renderForTesting(
        framebuffer: Framebuffer,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [UInt8]? {
        guard let viewport = stateLock.withLock({ self.viewport }) else { return nil }
        drawLock.lock()
        defer { drawLock.unlock() }

        let info = framebuffer.presentationStorage()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let rowBytes = pixelWidth * 4
        guard let target = device.makeTexture(descriptor: descriptor),
              let readback = device.makeBuffer(
                length: rowBytes * pixelHeight, options: .storageModeShared),
              let texture = currentTexture(for: info),
              let pipeline = currentPipeline(),
              let sampler = currentSampler(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        var geometry = FramebufferQuadGeometry(
            framebufferSize: CGSize(width: info.width, height: info.height),
            viewport: viewport,
            drawablePixelSize: CGSize(width: pixelWidth, height: pixelHeight))
        guard encode(
            into: commandBuffer,
            target: target,
            source: texture,
            pipeline: pipeline,
            sampler: sampler,
            geometry: &geometry),
            let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: pixelWidth, height: pixelHeight, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * pixelHeight)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return Array(UnsafeRawBufferPointer(
            start: readback.contents(), count: rowBytes * pixelHeight))
    }
}
