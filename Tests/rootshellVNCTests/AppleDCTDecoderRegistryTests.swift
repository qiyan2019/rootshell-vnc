import Foundation
import XCTest

@testable import RFBProtocol
@testable import RFBRendering

/// 注册表和注入钩子：宿主能换掉默认 Swift 解码器，没注册时行为不变。
final class AppleDCTDecoderRegistryTests: XCTestCase {
    /// 只数调用、不写像素的桩。测试串行跑，共享实例只在本用例里被触达。
    private final class StubDecoder: AppleDCTDecoding, @unchecked Sendable {
        var renderCount = 0
        var takeCount = 0
        var didWrite = true

        func render(
            rect: FramebufferRect, payload: Data, to framebuffer: Framebuffer,
            drawPixels: Bool
        ) throws {
            renderCount += 1
        }

        func takeDidWritePixels() -> Bool {
            takeCount += 1
            return didWrite
        }
    }

    override func setUp() {
        super.setUp()
        AppleDCTDecoderRegistry.resetForTesting()
    }

    override func tearDown() {
        AppleDCTDecoderRegistry.resetForTesting()
        super.tearDown()
    }

    /// 一条只有一个白块（命令 0）的 type-0 消息。
    private func solidTile() -> Data {
        Data([0, 0, 0, 8, 0, 15, 25, 0, 0, 7, 0x00, 0x00])
    }

    private func rect(width: Int, height: Int) -> FramebufferRect {
        FramebufferRect(
            x: 0, y: 0, width: UInt16(width), height: UInt16(height),
            encoding: .appleMultiVariantScreenshare)
    }

    func testUnregisteredUsesBuiltinSwiftDecoder() throws {
        XCTAssertTrue(AppleDCTDecoderRegistry.makeDecoder() is AppleAdaptiveDCTDecoder)
        // 端到端：渲染器真的走内置解码器，白块写出来。
        let framebuffer = Framebuffer(width: 8, height: 8, pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(framebuffer: framebuffer, pixelFormat: .bgra8888)
        try renderer.applyRect(rect: rect(width: 8, height: 8), data: solidTile())
        XCTAssertEqual(
            framebuffer.getPixels(x: 0, y: 0, width: 8, height: 8),
            Data(repeating: 0xff, count: 8 * 8 * 4))
    }

    func testRegisteredDecoderIsUsedByApplyRectAndApplyBatch() throws {
        let stub = StubDecoder()
        AppleDCTDecoderRegistry.register { stub }
        XCTAssertTrue(AppleDCTDecoderRegistry.makeDecoder() is StubDecoder)

        let framebuffer = Framebuffer(width: 8, height: 8, pixelFormat: .bgra8888)
        let renderer = FramebufferRenderer(framebuffer: framebuffer, pixelFormat: .bgra8888)
        try renderer.applyRect(rect: rect(width: 8, height: 8), data: solidTile())
        XCTAssertEqual(stub.renderCount, 1)

        // applyBatch：DCT 矩形走桩，takeDidWritePixels 决定 pixelsChanged。
        stub.didWrite = false
        var result = renderer.applyBatch(
            [(rect(width: 8, height: 8), solidTile())], snapshot: false)
        XCTAssertEqual(stub.renderCount, 2)
        XCTAssertEqual(stub.takeCount, 1)
        XCTAssertFalse(result.pixelsChanged)

        stub.didWrite = true
        result = renderer.applyBatch(
            [(rect(width: 8, height: 8), solidTile())], snapshot: false)
        XCTAssertEqual(stub.renderCount, 3)
        XCTAssertEqual(stub.takeCount, 2)
        XCTAssertTrue(result.pixelsChanged)
    }

    func testMakeSwiftDecoderIgnoresRegistration() {
        let stub = StubDecoder()
        AppleDCTDecoderRegistry.register { stub }
        XCTAssertTrue(AppleDCTDecoderRegistry.makeSwiftDecoder() is AppleAdaptiveDCTDecoder)
        XCTAssertTrue(AppleDCTDecoderRegistry.makeDecoder() is StubDecoder)
    }
}
