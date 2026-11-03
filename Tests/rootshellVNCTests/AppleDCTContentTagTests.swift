import Foundation
import RFBRenderingC
import XCTest

@testable import RFBProtocol
@testable import RFBRendering

/// 内容标识的后果是跳过写入：一旦判错，屏幕上会留下旧内容，所以这里守的都是「不能漏画」。
final class AppleDCTContentTagTests: XCTestCase {
    private struct Bits {
        var bytes: [UInt8] = []
        var count = 0
        mutating func put(_ value: Int, _ width: Int) {
            for shift in stride(from: width - 1, through: 0, by: -1) {
                if count % 8 == 0 { bytes.append(0) }
                bytes[count / 8] |= UInt8((value >> shift) & 1) << (7 - count % 8)
                count += 1
            }
        }
        mutating func run(_ count: Int) {
            if count == 1 {
                put(0, 1)
                return
            }
            put(1, 1)
            if count <= 16 {
                put(count - 2, 4)
                return
            }
            put(15, 4)
            var value = count - 17
            repeat {
                let next = value >> 7
                put((value & 127) | (next == 0 ? 0 : 128), 8)
                value = next
            } while value != 0
        }
    }

    private func framed(_ bytes: [UInt8]) -> Data {
        let n = bytes.count
        return Data(
            [
                UInt8((n >> 24) & 255), UInt8((n >> 16) & 255),
                UInt8((n >> 8) & 255), UInt8(n & 255),
            ] + bytes)
    }

    private func type0(_ commands: Bits, _ data: Bits) -> Data {
        var data = data
        if data.bytes.isEmpty { data.put(0, 8) }
        let offset = 6 + commands.bytes.count
        return framed(
            [
                0, 15, 25, UInt8((offset >> 16) & 255),
                UInt8((offset >> 8) & 255), UInt8(offset & 255),
            ] + commands.bytes + data.bytes)
    }

    /// 只带一条命令的 type-0 流。`level` 改 Y DC，不同取值画出不同的像素。
    private func dctTiles(count: Int, level: Int = 0) -> Data {
        var commands = Bits()
        var data = Bits()
        commands.put(0, 1)
        commands.put(5, 3)
        commands.run(count)
        for tile in 0..<count {
            data.put(0, 1)  // 新系数
            data.put(1, 1)  // 沿用色度 DC
            data.put(0, 1)  // 低截止
            if tile == 0, level != 0 {
                // Rice：前缀 3 个 1 再一个 0，4 位后缀的高 3 位是幅值，最低位是符号。
                data.put(0b1110, 4)
                data.put((level & 7) << 1, 4)
            } else {
                data.put(0, 2)
            }
            data.put(0, 1)
            data.put(1, 2)
            data.put(0, 1)  // EOB
        }
        return type0(commands, data)
    }

    private func reuseRun(count: Int, level: Int = 0) -> Data {
        var commands = Bits()
        var data = Bits()
        commands.put(0, 1)
        commands.put(5, 3)
        commands.run(count)
        data.put(0, 1)
        data.put(1, 1)
        data.put(0, 1)
        data.put(0b1110, 4)
        data.put((level & 7) << 1, 4)
        data.put(0, 1)
        data.put(1, 2)
        data.put(0, 1)
        for _ in 1..<max(count, 1) { data.put(1, 1) }
        return type0(commands, data)
    }

    private func solid(count: Int) -> Data {
        var commands = Bits()
        commands.put(0, 1)
        commands.put(0, 3)
        commands.run(count)
        return type0(commands, Bits())
    }

    /// 命令 3：白 / 黑双色块。`masks` 是八行掩码，置位的像素是白色。
    private func twoColor(masks: [UInt8]) -> Data {
        var commands = Bits()
        var data = Bits()
        commands.put(0, 1)
        commands.put(3, 3)
        commands.run(1)
        data.put(0, 8)
        for mask in masks { data.put(Int(mask), 8) }
        return type0(commands, data)
    }

    /// 第一块是 DCT，后面的块全用「拷前一块」。
    private func copyRun(count: Int, level: Int) -> Data {
        var commands = Bits()
        var data = Bits()
        commands.put(0, 1)
        commands.put(5, 3)
        commands.run(1)
        data.put(0, 1)
        data.put(1, 1)
        data.put(0, 1)
        data.put(0b1110, 4)
        data.put((level & 7) << 1, 4)
        data.put(0, 1)
        data.put(1, 2)
        data.put(0, 1)
        commands.put(1, 3)
        commands.run(count - 1)
        return type0(commands, data)
    }

    private func refinement(tiles: Int) -> Data {
        var bits = Bits()
        for _ in 0..<tiles {
            bits.put(1, 2)
            bits.put(7, 6)
            bits.put(0, 7)
            bits.put(0, 1)
            bits.put(0, 1)
        }
        return framed([1, 0, 0] + bits.bytes)
    }

    private func cacheDraw(keys: [Int]) -> Data {
        var commands = Bits()
        var data = Bits()
        commands.put(0, 1)
        commands.put(6, 3)
        commands.run(keys.count)
        for key in keys { data.put(key, 16) }
        return type0(commands, data)
    }

    private func quantization(luma: UInt8, chroma: UInt8) -> Data {
        framed([2] + [UInt8](repeating: luma, count: 64) + [UInt8](repeating: chroma, count: 64))
    }

    private func rect(x: Int = 0, y: Int = 0, width: Int, height: Int) -> FramebufferRect {
        FramebufferRect(
            x: UInt16(x), y: UInt16(y), width: UInt16(width), height: UInt16(height),
            encoding: .appleMultiVariantScreenshare)
    }

    private func framebuffer(width: Int, height: Int) -> Framebuffer {
        Framebuffer(width: width, height: height, pixelFormat: .bgra8888)
    }

    private func allPixels(_ framebuffer: Framebuffer) -> Data {
        framebuffer.getPixels(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
    }

    /// 从一个没用过标识的解码器画出同样的流，作为这一步应有的像素。
    private func expectedPixels(
        width: Int, height: Int, steps: [(FramebufferRect, Data)]
    ) throws -> Data {
        let decoder = AppleAdaptiveDCTDecoder()
        decoder.skipsUnchangedTiles = false
        let target = framebuffer(width: width, height: height)
        for (rect, payload) in steps {
            try decoder.render(rect: rect, payload: payload, to: target)
        }
        return allPixels(target)
    }

    // MARK: - 哈希

    /// 官方向量（xxhash 文档与 python-xxhash README）。超过 32 字节的那条走条带循环。
    func testXXH64MatchesPublishedVectors() {
        func digest(_ text: String, seed: UInt64 = 0) -> UInt64 {
            let bytes = Array(text.utf8)
            return bytes.withUnsafeBytes { rfb_xxh64($0.baseAddress, $0.count, seed) }
        }
        XCTAssertEqual(digest(""), 0xEF46_DB37_51D8_E999)
        XCTAssertEqual(digest("a"), 0xD24E_C4F1_A98C_6E5B)
        XCTAssertEqual(digest("abc"), 0x44BC_2CF5_AD77_0999)
        XCTAssertEqual(digest("xxhash"), 0x32DD_3895_2C4B_C720)
        XCTAssertEqual(digest("xxhash", seed: 20_141_025), 0xB559_B98D_844E_0635)
        XCTAssertEqual(digest("Nobody inspects the spammish repetition"), 0xFBCE_A83C_8A37_8BF1)
    }

    // MARK: - 没变的不写

    func testResentContentWritesNothingForEveryTileKind() throws {
        let cases: [(String, Data, Int)] = [
            ("dct", dctTiles(count: 4, level: 3), 4),
            ("reuse", reuseRun(count: 4, level: 3), 4),
            ("copy", copyRun(count: 4, level: 3), 4),
            ("solid", solid(count: 4), 4),
            ("twoColor", twoColor(masks: [0xf0, 0x0f, 0xaa, 0x55, 0xff, 0, 0x81, 0x18]), 1),
        ]
        for (name, payload, tiles) in cases {
            let decoder = AppleAdaptiveDCTDecoder()
            let target = framebuffer(width: tiles * 8, height: 8)
            let area = rect(width: tiles * 8, height: 8)
            try decoder.render(rect: area, payload: payload, to: target)
            XCTAssertTrue(decoder.takeDidWritePixels(), name)
            let first = allPixels(target)
            try decoder.render(rect: area, payload: payload, to: target)
            XCTAssertFalse(decoder.takeDidWritePixels(), "\(name) 重发不该写帧缓冲")
            XCTAssertEqual(allPixels(target), first, name)
        }
    }

    func testChangedContentIsRepainted() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 32, height: 8)
        let area = rect(width: 32, height: 8)
        try decoder.render(rect: area, payload: reuseRun(count: 4, level: 1), to: target)
        _ = decoder.takeDidWritePixels()
        let changed = reuseRun(count: 4, level: 5)
        try decoder.render(rect: area, payload: changed, to: target)
        XCTAssertTrue(decoder.takeDidWritePixels())
        XCTAssertEqual(
            allPixels(target),
            try expectedPixels(width: 32, height: 8, steps: [(area, changed)]))
    }

    // MARK: - 标识判错的高风险位置

    /// 只差最后一行、只差一个像素：哈希收尾不好时这里最容易撞（Android 的 FNV 就撞过）。
    func testTwoColorDifferenceInAnySinglePixelIsRepainted() throws {
        let base = [UInt8](repeating: 0xa5, count: 8)
        let area = rect(width: 8, height: 8)
        for row in 0..<8 {
            for column in 0..<8 {
                var masks = base
                masks[row] ^= UInt8(0x80 >> column)
                let decoder = AppleAdaptiveDCTDecoder()
                let target = framebuffer(width: 8, height: 8)
                try decoder.render(rect: area, payload: twoColor(masks: base), to: target)
                try decoder.render(rect: area, payload: twoColor(masks: masks), to: target)
                XCTAssertEqual(
                    allPixels(target),
                    try expectedPixels(
                        width: 8, height: 8, steps: [(area, twoColor(masks: masks))]),
                    "row \(row) column \(column)")
            }
        }
    }

    func testQuantizationChangeRepaintsButIdenticalTableDoesNot() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 16, height: 8)
        let area = rect(width: 16, height: 8)
        let tiles = dctTiles(count: 2, level: 4)
        let tableA = quantization(luma: 16, chroma: 17)
        let tableB = quantization(luma: 90, chroma: 91)
        try decoder.render(rect: area, payload: tableA, to: target)
        try decoder.render(rect: area, payload: tiles, to: target)
        _ = decoder.takeDidWritePixels()

        try decoder.render(rect: area, payload: tableA, to: target)
        try decoder.render(rect: area, payload: tiles, to: target)
        XCTAssertFalse(decoder.takeDidWritePixels(), "相同的表不该让标识失效")

        try decoder.render(rect: area, payload: tableB, to: target)
        try decoder.render(rect: area, payload: tiles, to: target)
        XCTAssertTrue(decoder.takeDidWritePixels())
        XCTAssertEqual(
            allPixels(target),
            try expectedPixels(
                width: 16, height: 8, steps: [(area, tableB), (area, tiles)]))
    }

    /// 其他编码写过帧缓冲后，标识不再代表屏幕内容。
    func testAnyOtherFramebufferWriteInvalidatesTags() throws {
        let area = rect(width: 16, height: 8)
        let tiles = dctTiles(count: 2, level: 4)
        let expected = try expectedPixels(width: 16, height: 8, steps: [(area, tiles)])
        let writes: [(String, (Framebuffer) -> Void)] = [
            ("fillRect", { $0.fillRect(x: 0, y: 0, width: 8, height: 8, pixel: Data([1, 2, 3, 255])) }),
            ("update", {
                $0.update(x: 8, y: 0, width: 8, height: 8, data: Data(repeating: 9, count: 256))
            }),
            ("copyRect", { $0.copyRect(srcX: 8, srcY: 0, dstX: 0, dstY: 0, width: 4, height: 4) }),
        ]
        for (name, write) in writes {
            let decoder = AppleAdaptiveDCTDecoder()
            let target = framebuffer(width: 16, height: 8)
            try decoder.render(rect: area, payload: tiles, to: target)
            write(target)
            try decoder.render(rect: area, payload: tiles, to: target)
            XCTAssertEqual(allPixels(target), expected, name)
        }
    }

    func testResizeBackToSameSizeInvalidatesTags() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 16, height: 8)
        let area = rect(width: 16, height: 8)
        let tiles = dctTiles(count: 2, level: 4)
        try decoder.render(rect: area, payload: tiles, to: target)
        let expected = allPixels(target)
        target.resize(width: 32, height: 16)
        target.resize(width: 16, height: 8)
        try decoder.render(rect: area, payload: tiles, to: target)
        XCTAssertEqual(allPixels(target), expected)
    }

    /// 不对齐的矩形一块压两个网格，压过的网格都不能再当作已知内容。
    func testUnalignedRectInvalidatesEveryOverlappedTile() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 24, height: 24)
        let full = rect(width: 24, height: 24)
        let unaligned = rect(x: 4, y: 4, width: 8, height: 8)
        let background = reuseRun(count: 9, level: 2)
        let overlay = dctTiles(count: 1, level: 6)
        try decoder.render(rect: full, payload: background, to: target)
        try decoder.render(rect: unaligned, payload: overlay, to: target)
        try decoder.render(rect: full, payload: background, to: target)
        XCTAssertEqual(
            allPixels(target),
            try expectedPixels(width: 24, height: 24, steps: [(full, background)]))
    }

    /// 拷贝块的标识继承自源块：源变了，目标不能因为旧标识被跳过。
    func testCopyRepaintsWhenSourceChanged() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 32, height: 8)
        let area = rect(width: 32, height: 8)
        try decoder.render(rect: area, payload: copyRun(count: 4, level: 1), to: target)
        let changed = copyRun(count: 4, level: 6)
        try decoder.render(rect: area, payload: changed, to: target)
        XCTAssertEqual(
            allPixels(target),
            try expectedPixels(width: 32, height: 8, steps: [(area, changed)]))
    }

    /// 帧缓冲边长不是 8 的倍数时，换行拷贝的源可能只露出一部分。
    func testCopyFromClippedTileAcrossRowBoundaryStaysCorrect() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 12, height: 12)
        let area = rect(width: 12, height: 12)
        let first = copyRun(count: 4, level: 2)
        let second = copyRun(count: 4, level: 5)
        for payload in [first, second, first, first, second] {
            try decoder.render(rect: area, payload: payload, to: target)
            XCTAssertEqual(
                allPixels(target),
                try expectedPixels(width: 12, height: 12, steps: [(area, payload)]))
        }
    }

    /// 源被裁掉一截时，拷贝只盖到目标的一部分。之后再画和源相同的内容，不能被当成「已经一样」。
    func testPartialCopyDoesNotClaimSourceContent() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 12, height: 16)
        let full = rect(width: 12, height: 16)
        let background = reuseRun(count: 4, level: 7)

        // 第二块（只露出 4 列）是内容 T，第三块在下一行开头，从它拷贝。
        var commands = Bits()
        var data = Bits()
        commands.put(0, 1)
        commands.put(5, 3)
        commands.run(2)
        for level in [0, 2] {
            data.put(0, 1)
            data.put(1, 1)
            data.put(0, 1)
            if level == 0 {
                data.put(0, 2)
            } else {
                data.put(0b1110, 4)
                data.put(level << 1, 4)
            }
            data.put(0, 1)
            data.put(1, 2)
            data.put(0, 1)
        }
        commands.put(1, 3)
        commands.run(2)
        let copying = type0(commands, data)

        // 单独把 T 画到第三块的位置。
        let lower = rect(x: 0, y: 8, width: 8, height: 8)
        let direct = dctTiles(count: 1, level: 2)

        try decoder.render(rect: full, payload: background, to: target)
        try decoder.render(rect: full, payload: copying, to: target)
        try decoder.render(rect: lower, payload: direct, to: target)
        XCTAssertEqual(
            allPixels(target),
            try expectedPixels(
                width: 12, height: 16,
                steps: [(full, background), (full, copying), (lower, direct)]))
    }

    /// `map` 里的 DC 是截断值。相差 256 的两块 `map` 相同，像素却不同。
    func testDCDifferingByMultipleOf256IsRepainted() throws {
        func tile(dc: Int) -> Data {
            var commands = Bits()
            var data = Bits()
            commands.put(0, 1)
            commands.put(5, 3)
            commands.run(1)
            data.put(0, 1)
            data.put(1, 1)
            data.put(0, 1)
            // 幅值 = 前缀 × 8 + 后缀高 3 位 - 16，符号位 1 表示负，DC = 0 - (-幅值)。
            let prefix = (dc + 16) / 8
            for _ in 0..<prefix { data.put(1, 1) }
            data.put(0, 1)
            data.put(((dc + 16) % 8) << 1 | 1, 4)
            data.put(0, 1)
            data.put(1, 2)
            data.put(0, 1)
            return type0(commands, data)
        }
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 8, height: 8)
        let area = rect(width: 8, height: 8)
        try decoder.render(rect: area, payload: tile(dc: 10), to: target)
        let low = allPixels(target)
        try decoder.render(rect: area, payload: tile(dc: 266), to: target)
        XCTAssertNotEqual(allPixels(target), low, "两块的像素应该不同，否则这条用例没有意义")
        XCTAssertEqual(
            allPixels(target),
            try expectedPixels(width: 8, height: 8, steps: [(area, tile(dc: 266))]))
    }

    /// 复用块用的是上一次算好的像素：前一块被跳过时那份像素是旧的，不能直接拿来写。
    func testReuseAfterSkippedTileDoesNotDrawStalePixels() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 24, height: 8)
        let area = rect(width: 24, height: 8)
        // 第一块画 A，第二块画 B。
        try decoder.render(rect: area, payload: reuseRun(count: 3, level: 1), to: target)
        // 第一块内容不变被跳过（没算像素），后面两块是复用块，也是同样内容。
        // 先把后两块改掉，让它们必须重画。
        let tail = rect(x: 8, y: 0, width: 16, height: 8)
        try decoder.render(rect: tail, payload: reuseRun(count: 2, level: 6), to: target)
        let stream = reuseRun(count: 3, level: 1)
        try decoder.render(rect: area, payload: stream, to: target)
        XCTAssertEqual(
            allPixels(target),
            try expectedPixels(width: 24, height: 8, steps: [(area, stream)]))
    }

    func testCachedTilesAreSkippedOnlyWhileContentMatches() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 16, height: 8)
        let area = rect(width: 16, height: 8)
        let base = dctTiles(count: 2, level: 3)
        let refine = refinement(tiles: 2)
        let draw = cacheDraw(keys: [2, 1])
        var steps: [(FramebufferRect, Data)] = [(area, base), (area, refine), (area, draw)]
        for (rect, payload) in steps {
            try decoder.render(rect: rect, payload: payload, to: target)
        }
        XCTAssertEqual(allPixels(target), try expectedPixels(width: 16, height: 8, steps: steps))
        _ = decoder.takeDidWritePixels()

        try decoder.render(rect: area, payload: draw, to: target)
        XCTAssertFalse(decoder.takeDidWritePixels())

        // 同一个缓存槽换了量化表，画出来的像素不同。
        let table = quantization(luma: 90, chroma: 91)
        try decoder.render(rect: area, payload: table, to: target)
        try decoder.render(rect: area, payload: draw, to: target)
        steps += [(area, draw), (area, table), (area, draw)]
        XCTAssertEqual(allPixels(target), try expectedPixels(width: 16, height: 8, steps: steps))
    }

    func testRefinementAfterBaseStaysCorrectWhenResent() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 16, height: 8)
        let area = rect(width: 16, height: 8)
        let base = dctTiles(count: 2, level: 3)
        let refine = refinement(tiles: 2)
        var steps: [(FramebufferRect, Data)] = []
        for payload in [base, refine, base, refine, refine] {
            try decoder.render(rect: area, payload: payload, to: target)
            steps.append((area, payload))
            XCTAssertEqual(
                allPixels(target), try expectedPixels(width: 16, height: 8, steps: steps))
        }
    }

    /// `drawPixels: false` 只维护状态，屏幕没变，标识也不能变。
    func testUndrawnUpdateDoesNotPoisonTags() throws {
        let decoder = AppleAdaptiveDCTDecoder()
        let target = framebuffer(width: 16, height: 8)
        let area = rect(width: 16, height: 8)
        let shown = dctTiles(count: 2, level: 2)
        let hidden = dctTiles(count: 2, level: 6)
        try decoder.render(rect: area, payload: shown, to: target)
        let expected = allPixels(target)
        try decoder.render(rect: area, payload: hidden, to: target, drawPixels: false)
        XCTAssertEqual(allPixels(target), expected)
        _ = decoder.takeDidWritePixels()
        try decoder.render(rect: area, payload: hidden, to: target)
        XCTAssertTrue(decoder.takeDidWritePixels(), "这块内容还没画过，不能被跳过")
        XCTAssertEqual(
            allPixels(target),
            try expectedPixels(width: 16, height: 8, steps: [(area, hidden)]))
    }

    // MARK: - 差分

    /// 随机流（含非法流、不对齐矩形、越界矩形、重发、换表、外部写）：开关标识每一步逐像素相同。
    func testRandomStreamsMatchWithAndWithoutTags() throws {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        func randomStream() -> (Int, Int, Int, Int, Data) {
            let aligned = next(100) < 85
            let x = aligned ? next(5) * 8 : next(40)
            let y = aligned ? next(3) * 8 : next(24)
            let width = (1 + next(5)) * 8 - (next(100) < 20 ? next(8) : 0)
            let height = (1 + next(3)) * 8 - (next(100) < 20 ? next(8) : 0)
            let tiles = ((width + 7) / 8) * ((height + 7) / 8)
            switch next(100) {
            case 0..<8:
                let table = next(2) == 0 ? (UInt8(16), UInt8(17)) : (UInt8(60), UInt8(70))
                return (x, y, width, height, quantization(luma: table.0, chroma: table.1))
            case 8..<30:
                var bits = Bits()
                for _ in 0..<tiles {
                    let command = next(4)
                    bits.put(command, 2)
                    if command == 3 {
                        bits.put(1, 1)
                    } else if command == 1 {
                        bits.put(next(16), 6)
                        for _ in 0..<(4 + next(40)) { bits.put(next(2), 1) }
                    }
                }
                return (x, y, width, height, framed([1, UInt8(next(4)), UInt8(next(6))] + bits.bytes))
            default:
                var commands = Bits()
                var data = Bits()
                commands.put(0, 1)
                var remaining = tiles
                while remaining > 0 {
                    let run = min(remaining, 1 + next(6))
                    commands.put(next(100) < 60 ? 5 : next(8), 3)
                    commands.run(run)
                    remaining -= run
                }
                for _ in 0..<(tiles * (1 + next(6))) { data.put(next(256), 8) }
                let offset = 6 + commands.bytes.count
                return (
                    x, y, width, height,
                    framed(
                        [0, UInt8(1 + next(25)), UInt8(1 + next(25)), 0, UInt8(offset >> 8), UInt8(offset & 255)]
                            + commands.bytes + data.bytes)
                )
            }
        }

        let tagged = AppleAdaptiveDCTDecoder()
        let plain = AppleAdaptiveDCTDecoder()
        plain.skipsUnchangedTiles = false
        let taggedTarget = framebuffer(width: 44, height: 28)
        let plainTarget = framebuffer(width: 44, height: 28)
        var history: [(Int, Int, Int, Int, Data)] = []
        var succeeded = 0
        var failed = 0
        for iteration in 0..<4000 {
            if next(100) < 3 {
                let pixel = Data([UInt8(next(256)), 2, 3, 255])
                taggedTarget.fillRect(x: next(20), y: next(10), width: 9, height: 9, pixel: pixel)
                plainTarget.update(
                    x: 0, y: 0, width: 44, height: 28, data: allPixels(taggedTarget))
            }
            let stream: (Int, Int, Int, Int, Data)
            if !history.isEmpty, next(100) < 45 {
                stream = history[next(history.count)]
            } else {
                stream = randomStream()
                history.append(stream)
                if history.count > 24 { history.removeFirst() }
            }
            let area = rect(x: stream.0, y: stream.1, width: stream.2, height: stream.3)
            var taggedError = false
            var plainError = false
            do {
                try tagged.render(rect: area, payload: stream.4, to: taggedTarget)
            } catch is AppleAdaptiveDCTError {
                taggedError = true
            }
            do {
                try plain.render(rect: area, payload: stream.4, to: plainTarget)
            } catch is AppleAdaptiveDCTError {
                plainError = true
            }
            XCTAssertEqual(taggedError, plainError, "iteration \(iteration)")
            if taggedError { failed += 1 } else { succeeded += 1 }
            XCTAssertEqual(
                allPixels(taggedTarget), allPixels(plainTarget), "iteration \(iteration)")
            if allPixels(taggedTarget) != allPixels(plainTarget) { return }
        }
        // 防止用例空转：流要能解开，也要真的跳过过写入。
        XCTAssertGreaterThan(succeeded, 500)
        XCTAssertGreaterThan(failed, 100)
        XCTAssertGreaterThan(tagged.skippedTileCount, 1000)
        XCTAssertEqual(plain.skippedTileCount, 0)
    }

    // MARK: - 批

    func testRendererReportsWhetherBatchChangedPixels() throws {
        let target = framebuffer(width: 16, height: 8)
        let renderer = FramebufferRenderer(framebuffer: target, pixelFormat: .bgra8888)
        let area = rect(width: 16, height: 8)
        let tiles = dctTiles(count: 2, level: 4)

        var result = renderer.applyBatch([(area, tiles)], snapshot: true)
        XCTAssertTrue(result.pixelsChanged)
        XCTAssertNotNil(result.image)

        result = renderer.applyBatch([(area, tiles)], snapshot: true)
        XCTAssertFalse(result.pixelsChanged)
        XCTAssertNotNil(result.image, "默认行为不变：要快照就给")

        result = renderer.applyBatch([(area, tiles)], snapshot: true, snapshotUnchanged: false)
        XCTAssertFalse(result.pixelsChanged)
        XCTAssertNil(result.image, "内容没变时不白拷一张整帧图")

        let raw = FramebufferRect(x: 0, y: 0, width: 1, height: 1, encoding: .raw)
        result = renderer.applyBatch([(raw, Data([1, 2, 3, 255]))], snapshot: false)
        XCTAssertTrue(result.pixelsChanged, "其他编码按变了算")

        result = renderer.applyBatch([(area, tiles)], snapshot: false)
        XCTAssertTrue(result.pixelsChanged, "其他编码写过之后要重画")
    }
}
