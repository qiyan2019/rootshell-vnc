import XCTest
import CoreGraphics
import IOSurface
@testable import RFBProtocol
@testable import RFBRendering

/// 帧缓冲内存要能直接给 GPU 当纹理；换了行距之后所有读写接口仍要按行距走。
final class FramebufferStorageTests: XCTestCase {

    func testFullColorFramebufferLivesInSurfaceWithAlignedRows() throws {
        let framebuffer = Framebuffer(width: 101, height: 3, pixelFormat: .bgra8888)
        let info = framebuffer.presentationStorage()
        let surface = try XCTUnwrap(info.storage.surface, "32 位帧缓冲要能映射成纹理")
        XCTAssertEqual(IOSurfaceGetBaseAddress(surface), info.storage.base)
        XCTAssertEqual(IOSurfaceGetBytesPerRow(surface), info.bytesPerRow)
        XCTAssertEqual(info.bytesPerRow % FramebufferStorage.rowAlignment, 0)
        XCTAssertGreaterThanOrEqual(info.bytesPerRow, 101 * 4)
        XCTAssertGreaterThanOrEqual(info.storage.byteCount, info.bytesPerRow * 3)
    }

    func testThousandsColorAndOversizedFramebuffersStayOutOfSurface() {
        XCTAssertNil(
            Framebuffer(width: 8, height: 8, pixelFormat: .rgb555).presentationStorage().storage.surface)
        let oversized = Framebuffer(
            width: FramebufferStorage.maximumSurfaceDimension + 1,
            height: 1,
            pixelFormat: .bgra8888)
        XCTAssertNil(oversized.presentationStorage().storage.surface)
        // 没有 IOSurface 也要能正常读写，它们继续走图片路径。
        oversized.update(x: 3, y: 0, width: 1, height: 1, data: Data([1, 2, 3, 4]))
        XCTAssertEqual(oversized.getPixels(x: 3, y: 0, width: 1, height: 1), Data([1, 2, 3, 4]))
    }

    func testNewFramebufferStartsBlack() throws {
        let framebuffer = Framebuffer(width: 4, height: 4, pixelFormat: .bgra8888)
        XCTAssertEqual(
            framebuffer.getPixels(x: 0, y: 0, width: 4, height: 4),
            Data(count: 4 * 4 * 4))
    }

    func testWritesAndReadsRespectRowStride() {
        let framebuffer = Framebuffer(width: 3, height: 3, pixelFormat: .bgra8888)
        framebuffer.update(x: 1, y: 1, width: 1, height: 1, data: Data([1, 2, 3, 255]))
        XCTAssertEqual(framebuffer.getPixels(x: 1, y: 1, width: 1, height: 1), Data([1, 2, 3, 255]))
        XCTAssertEqual(framebuffer.getPixels(x: 0, y: 1, width: 1, height: 1), Data([0, 0, 0, 0]))

        framebuffer.fillRect(x: 0, y: 2, width: 3, height: 1, pixel: Data([9, 8, 7, 255]))
        XCTAssertEqual(framebuffer.getPixels(x: 2, y: 2, width: 1, height: 1), Data([9, 8, 7, 255]))

        framebuffer.copyRect(srcX: 1, srcY: 1, dstX: 0, dstY: 0, width: 1, height: 1)
        XCTAssertEqual(framebuffer.getPixels(x: 0, y: 0, width: 1, height: 1), Data([1, 2, 3, 255]))
    }

    func testImageIsAnIsolatedCopyWithCorrectColors() throws {
        let framebuffer = Framebuffer(width: 2, height: 2, pixelFormat: .bgra8888)
        // BGRX：(1,1) 写纯红。
        framebuffer.update(x: 1, y: 1, width: 1, height: 1, data: Data([0, 0, 255, 0]))
        let image = try XCTUnwrap(framebuffer.createImage())
        // 之后再写帧缓冲，已经发布的图不能跟着变。
        framebuffer.update(x: 1, y: 1, width: 1, height: 1, data: Data([0, 255, 0, 0]))

        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        var rgba = [UInt8](repeating: 0, count: 16)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        // 位图上下文的内存第 0 行是图的顶行，所以图的 (1,1) 在内存第 1 行第 1 列。
        XCTAssertEqual(Array(rgba[12..<16]), [255, 0, 0, 255])
        XCTAssertEqual(Array(rgba[0..<4]), [0, 0, 0, 255])
    }

    func testResizeKeepsPixelsAndOldStorageStaysValidWhileHeld() {
        let framebuffer = Framebuffer(width: 2, height: 2, pixelFormat: .bgra8888)
        framebuffer.update(x: 1, y: 1, width: 1, height: 1, data: Data([1, 2, 3, 4]))
        let old = framebuffer.presentationStorage()

        framebuffer.resize(width: 40, height: 3)

        let new = framebuffer.presentationStorage()
        XCTAssertFalse(old.storage === new.storage)
        XCTAssertEqual(new.width, 40)
        XCTAssertEqual(new.height, 3)
        XCTAssertEqual(framebuffer.getPixels(x: 1, y: 1, width: 1, height: 1), Data([1, 2, 3, 4]))
        // GPU 还在读旧内存时不能被释放：只要有人持有旧 storage，内容就还在。
        let oldPixel = old.storage.base
            .advanced(by: old.bytesPerRow + 4)
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(oldPixel[3], 4)
    }
}
