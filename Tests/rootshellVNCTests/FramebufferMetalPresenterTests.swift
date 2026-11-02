import CoreGraphics
import Metal
import QuartzCore
import XCTest
@testable import RFBProtocol
@testable import RFBRendering
@testable import rootshellVNC

/// 视口映射必须和被它替换的 SwiftUI 布局
/// `.aspectRatio(.fit)` + `.frame(viewSize)` + `.scaleEffect(s)` + `.offset(o)` 完全一致，
/// 否则画面和触控坐标（`RemoteInteractionView` 按同一语义换算）会错位。
final class FramebufferQuadGeometryTests: XCTestCase {

    private func geometry(
        framebuffer: CGSize = CGSize(width: 400, height: 200),
        view: CGSize = CGSize(width: 100, height: 200),
        scale: CGFloat = 1,
        offset: CGSize = .zero,
        region: CGRect? = nil,
        pixels: CGSize = CGSize(width: 300, height: 600)
    ) -> FramebufferQuadGeometry {
        FramebufferQuadGeometry(
            framebufferSize: framebuffer,
            viewport: FramebufferViewport(
                viewSize: view, scale: scale, offset: offset, sourceRegion: region),
            drawablePixelSize: pixels)
    }

    func testFitsCenteredAtIdentity() {
        // 400×200 放进 100×200：宽铺满，高 50，上下留黑。
        let g = geometry()
        XCTAssertEqual(g.center, SIMD2<Float>(0, 0))
        XCTAssertEqual(g.halfSize.x, 1, accuracy: 1e-5)
        XCTAssertEqual(g.halfSize.y, 0.25, accuracy: 1e-5)
        XCTAssertEqual(g.uvOrigin, SIMD2<Float>(0, 0))
        XCTAssertEqual(g.uvSize, SIMD2<Float>(1, 1))
    }

    func testScaleAndOffsetMatchSwiftUITransform() {
        // 视图点坐标 p = C + o + s(q - C)。放大 2 倍后高 100、宽 200，
        // 中心平移到 (50 + 10, 100 - 20) = (60, 80)。
        let g = geometry(scale: 2, offset: CGSize(width: 10, height: -20))
        XCTAssertEqual(g.center.x, (60 / 100) * 2 - 1, accuracy: 1e-5)
        // NDC 的 y 朝上。
        XCTAssertEqual(g.center.y, 1 - (80 / 200) * 2, accuracy: 1e-5)
        XCTAssertEqual(g.halfSize.x, 2, accuracy: 1e-5)
        XCTAssertEqual(g.halfSize.y, 0.5, accuracy: 1e-5)
    }

    func testRegionCropsSourceAndDrivesAspectFit() {
        // 只显示右半边（200×200），在 100×200 的视图里变成 100×100。
        let g = geometry(region: CGRect(x: 200, y: 0, width: 200, height: 200))
        XCTAssertEqual(g.uvOrigin.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(g.uvOrigin.y, 0, accuracy: 1e-5)
        XCTAssertEqual(g.uvSize.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(g.uvSize.y, 1, accuracy: 1e-5)
        XCTAssertEqual(g.halfSize.x, 1, accuracy: 1e-5)
        XCTAssertEqual(g.halfSize.y, 0.5, accuracy: 1e-5)
    }

    func testTapCountFollowsMinification() {
        // 每次采样是双线性，已覆盖约 2 个源像素，所以按「缩小倍数 / 2」取整。
        // 400 源像素 → 300 物理像素：1.33 倍。
        XCTAssertEqual(geometry().taps, 1)
        // 3840 → 1206：约 3.2 倍，2×2 就够。
        XCTAssertEqual(
            geometry(
                framebuffer: CGSize(width: 3840, height: 2160),
                view: CGSize(width: 402, height: 874),
                pixels: CGSize(width: 1206, height: 2622)
            ).taps,
            2)
        // 放大后每个屏幕像素不到一个源像素，只采一次。
        XCTAssertEqual(geometry(scale: 4).taps, 1)
        // 极端缩小也有上限，不能让 GPU 无限采样。
        XCTAssertEqual(
            geometry(framebuffer: CGSize(width: 16000, height: 8000), pixels: CGSize(width: 100, height: 200)).taps,
            4)
    }

    func testUVStepIsOneScreenPixelInTextureSpace() {
        let g = geometry()
        // 400 源像素铺满 300 物理像素：一个屏幕像素 = 1/300 的纹理宽。
        XCTAssertEqual(g.uvPerPixel.x, 1.0 / 300, accuracy: 1e-5)
    }
}

final class FramebufferMetalPresenterTests: XCTestCase {

    private func makePresenter() throws -> FramebufferMetalPresenter {
        guard let presenter = FramebufferMetalPresenter() else {
            throw XCTSkip("没有可用的 Metal 设备")
        }
        return presenter
    }

    private func pixel(_ data: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(data[offset..<(offset + 4)])
    }

    func testRendersBGRXWithCorrectChannelsOpaqueAndClearLetterbox() throws {
        let presenter = try makePresenter()
        let framebuffer = Framebuffer(width: 2, height: 1, pixelFormat: .bgra8888)
        // 左红右绿，第四字节故意为 0（depth-24 填充）。
        framebuffer.update(x: 0, y: 0, width: 2, height: 1, data: Data([
            0, 0, 255, 0,
            0, 255, 0, 0,
        ]))
        presenter.setViewport(FramebufferViewport(
            viewSize: CGSize(width: 40, height: 40), scale: 1, offset: .zero, sourceRegion: nil))

        let bgra = try XCTUnwrap(
            presenter.renderForTesting(framebuffer: framebuffer, pixelWidth: 40, pixelHeight: 40))

        // 2:1 放进正方形：中间 20 行是画面，上下留黑透明。
        XCTAssertEqual(pixel(bgra, width: 40, x: 20, y: 2), [0, 0, 0, 0])
        XCTAssertEqual(pixel(bgra, width: 40, x: 2, y: 20), [0, 0, 255, 255])
        XCTAssertEqual(pixel(bgra, width: 40, x: 37, y: 20), [0, 255, 0, 255])
    }

    func testFirstMemoryRowIsTopOfScreen() throws {
        let presenter = try makePresenter()
        let framebuffer = Framebuffer(width: 1, height: 2, pixelFormat: .bgra8888)
        framebuffer.update(x: 0, y: 0, width: 1, height: 1, data: Data([0, 0, 255, 255]))
        framebuffer.update(x: 0, y: 1, width: 1, height: 1, data: Data([255, 0, 0, 255]))
        presenter.setViewport(FramebufferViewport(
            viewSize: CGSize(width: 20, height: 40), scale: 1, offset: .zero, sourceRegion: nil))

        let bgra = try XCTUnwrap(
            presenter.renderForTesting(framebuffer: framebuffer, pixelWidth: 20, pixelHeight: 40))

        XCTAssertEqual(pixel(bgra, width: 20, x: 10, y: 2), [0, 0, 255, 255])
        XCTAssertEqual(pixel(bgra, width: 20, x: 10, y: 37), [255, 0, 0, 255])
    }

    /// 零拷贝的证据：直接写帧缓冲内存，不调任何上传接口，下一帧就能看到。
    func testGPUSeesFramebufferWritesWithoutUpload() throws {
        let presenter = try makePresenter()
        let framebuffer = Framebuffer(width: 4, height: 4, pixelFormat: .bgra8888)
        presenter.setViewport(FramebufferViewport(
            viewSize: CGSize(width: 4, height: 4), scale: 1, offset: .zero, sourceRegion: nil))
        _ = try XCTUnwrap(
            presenter.renderForTesting(framebuffer: framebuffer, pixelWidth: 4, pixelHeight: 4))
        let texturesAfterFirstFrame = presenter.textureCreationCount

        framebuffer.fillRect(x: 0, y: 0, width: 4, height: 4, pixel: Data([255, 255, 255, 255]))
        let bgra = try XCTUnwrap(
            presenter.renderForTesting(framebuffer: framebuffer, pixelWidth: 4, pixelHeight: 4))

        XCTAssertEqual(pixel(bgra, width: 4, x: 1, y: 1), [255, 255, 255, 255])
        XCTAssertEqual(presenter.textureCreationCount, texturesAfterFirstFrame, "同一块内存不该重建纹理")
    }

    func testResizeRebuildsTextureAndKeepsRendering() throws {
        let presenter = try makePresenter()
        let framebuffer = Framebuffer(width: 2, height: 2, pixelFormat: .bgra8888)
        presenter.setViewport(FramebufferViewport(
            viewSize: CGSize(width: 8, height: 8), scale: 1, offset: .zero, sourceRegion: nil))
        _ = try XCTUnwrap(
            presenter.renderForTesting(framebuffer: framebuffer, pixelWidth: 8, pixelHeight: 8))

        framebuffer.resize(width: 8, height: 8)
        framebuffer.fillRect(x: 0, y: 0, width: 8, height: 8, pixel: Data([0, 0, 255, 255]))
        let bgra = try XCTUnwrap(
            presenter.renderForTesting(framebuffer: framebuffer, pixelWidth: 8, pixelHeight: 8))

        XCTAssertEqual(pixel(bgra, width: 8, x: 4, y: 4), [0, 0, 255, 255])
        XCTAssertEqual(presenter.textureCreationCount, 2)
    }

    func testDownscaleAveragesInsteadOfAliasing() throws {
        let presenter = try makePresenter()
        // 1 像素宽的黑白竖条缩小 8 倍：只采一次会闪烁，取平均应接近中灰。
        let width = 64
        let framebuffer = Framebuffer(width: width, height: 64, pixelFormat: .bgra8888)
        for x in stride(from: 0, to: width, by: 2) {
            framebuffer.fillRect(x: x, y: 0, width: 1, height: 64, pixel: Data([255, 255, 255, 255]))
        }
        presenter.setViewport(FramebufferViewport(
            viewSize: CGSize(width: 8, height: 8), scale: 1, offset: .zero, sourceRegion: nil))

        let bgra = try XCTUnwrap(
            presenter.renderForTesting(framebuffer: framebuffer, pixelWidth: 8, pixelHeight: 8))

        for x in 0..<8 {
            XCTAssertEqual(Int(pixel(bgra, width: 8, x: x, y: 4)[0]), 128, accuracy: 24)
        }
    }

    func testPresentationGateBlocksDrawing() throws {
        let presenter = try makePresenter()
        let framebuffer = Framebuffer(width: 2, height: 2, pixelFormat: .bgra8888)
        presenter.setPresentationAllowed(false)
        XCTAssertFalse(presenter.presentFrame(from: framebuffer))
    }

    /// 两个开关各管各的：会话恢复呈现不能打开视图关上的门，
    /// 否则 App 失活、锁屏时会继续画（系统会直接杀进程）。
    func testBothGatesMustBeOpenToDraw() throws {
        let presenter = try makePresenter()
        let framebuffer = Framebuffer(width: 4, height: 4, pixelFormat: .bgra8888)
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 4, height: 4)
        presenter.attach(layer: layer)
        presenter.setViewport(FramebufferViewport(
            viewSize: CGSize(width: 4, height: 4), scale: 1, offset: .zero, sourceRegion: nil))
        XCTAssertTrue(presenter.presentFrame(from: framebuffer))
        XCTAssertEqual(presenter.framesPresentedCount, 1)

        presenter.setViewPresentationAllowed(false)
        presenter.setPresentationAllowed(true)
        XCTAssertFalse(presenter.presentFrame(from: framebuffer), "视图关门时会话不能把它打开")

        presenter.setViewPresentationAllowed(true)
        presenter.setPresentationAllowed(false)
        XCTAssertFalse(presenter.presentFrame(from: framebuffer))

        presenter.setPresentationAllowed(true)
        XCTAssertTrue(presenter.presentFrame(from: framebuffer))
        XCTAssertEqual(presenter.framesPresentedCount, 2)
    }

    /// 失活时要等手里的 GPU 工作做完才返回：系统紧接着就抓场景快照。
    func testDrainWaitsForRedrawInFlight() throws {
        let presenter = try makePresenter()
        let framebuffer = Framebuffer(width: 4, height: 4, pixelFormat: .bgra8888)
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 4, height: 4)
        presenter.attach(layer: layer)
        presenter.setFramebuffer(framebuffer)
        presenter.setViewport(FramebufferViewport(
            viewSize: CGSize(width: 4, height: 4), scale: 1, offset: .zero, sourceRegion: nil))
        presenter.requestRedraw()

        presenter.setViewPresentationAllowed(false)
        presenter.drainToIdle()

        XCTAssertFalse(presenter.isGPUBusy, "排空之后不该还有命令在跑")
        XCTAssertFalse(presenter.presentFrame(from: framebuffer))
    }

    func testOnlyFullColorFramebuffersAreSupported() {
        XCTAssertTrue(FramebufferMetalPresenter.supports(pixelFormat: .bgra8888))
        XCTAssertFalse(FramebufferMetalPresenter.supports(pixelFormat: .rgb555))
    }
}
