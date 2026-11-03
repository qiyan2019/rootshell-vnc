import Foundation
import RFBProtocol
import RFBRenderingC

enum AppleAdaptiveDCTError: Error, LocalizedError {
    case malformed(String)
    case unsupportedMessageType(UInt8)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail): detail
        case .unsupportedMessageType(let type):
            "Unsupported Apple Adaptive DCT message type \(type)"
        }
    }

}

/// Stateful decoder for Apple's registered RFB encoding 1011. The server
/// sends quantization changes (type 2) independently from image commands
/// (type 0), and later image commands may reference tiles decoded by any
/// earlier rectangle, so one instance must live for the whole connection.
final class AppleAdaptiveDCTDecoder {
    struct BitReader {
        // Borrowed only within the enclosing Data.withUnsafeBytes call.
        private let bytes: UnsafeRawBufferPointer
        private var nextByteOffset = 0
        private var reservoir: UInt64 = 0
        private var reservoirBitCount = 0
        var bitOffset: Int { nextByteOffset * 8 - reservoirBitCount }

        init(_ bytes: UnsafeRawBufferPointer) {
            self.bytes = bytes
        }

        var remainingBitCount: Int { bytes.count * 8 - bitOffset }

        /// 储备够就不做任何边界计算，这是解码最热的路径。调用点的位数基本是字面量，内联后比较会被折叠掉。
        @inline(__always)
        mutating func readBits(_ count: Int) throws -> UInt32 {
            guard _fastPath(count >= 0 && count <= 32 && count <= reservoirBitCount) else {
                return try readBitsRefilling(count)
            }
            reservoirBitCount &-= count
            let mask = (UInt64(1) &<< UInt64(count)) &- 1
            return UInt32(truncatingIfNeeded: (reservoir &>> UInt64(reservoirBitCount)) & mask)
        }

        @inline(never)
        private mutating func readBitsRefilling(_ count: Int) throws -> UInt32 {
            guard count >= 0 && count <= 32, count <= remainingBitCount else {
                throw AppleAdaptiveDCTError.malformed(
                    "DCT command stream ended while reading \(count) bits")
            }
            refill()
            reservoirBitCount -= count
            let mask = (UInt64(1) << count) - 1
            return UInt32(truncatingIfNeeded: (reservoir >> reservoirBitCount) & mask)
        }

        /// 把储备尽量装满。未读的位在低位；高位是已读的旧值，左移时自然被挤掉。
        private mutating func refill() {
            let wholeBytes = (64 - reservoirBitCount) / 8
            if wholeBytes > 0, nextByteOffset + 8 <= bytes.count {
                let word = bytes.loadUnaligned(fromByteOffset: nextByteOffset, as: UInt64.self).bigEndian
                // wholeBytes 可能是 8，这里要用会处理超宽移位的 `<<`、`>>`。
                reservoir = (reservoir << (wholeBytes * 8)) | (word >> (64 - wholeBytes * 8))
                nextByteOffset += wholeBytes
                reservoirBitCount += wholeBytes * 8
                return
            }
            while reservoirBitCount <= 56, nextByteOffset < bytes.count {
                reservoir = (reservoir << 8) | UInt64(bytes[nextByteOffset])
                nextByteOffset += 1
                reservoirBitCount += 8
            }
        }

        /// The most frequent operation avoids general-width masks and checks
        /// availability only when fetching a new byte. Consumed high bits need
        /// not be cleared: reservoirBitCount selects only the unread low bits.
        @inline(__always)
        mutating func readBit() throws -> UInt32 {
            if _slowPath(reservoirBitCount == 0) {
                guard nextByteOffset < bytes.count else {
                    throw AppleAdaptiveDCTError.malformed(
                        "DCT command stream ended while reading 1 bits")
                }
                refill()
            }
            reservoirBitCount &-= 1
            return UInt32(truncatingIfNeeded: reservoir &>> UInt64(reservoirBitCount)) & 1
        }

        /// Apple encodes a command's tile count as 0 => one tile, followed by
        /// a compact 4-bit form for 2...16. The escape value 15 is followed
        /// by one to three little-endian base-128 groups and a bias of 17.
        mutating func readCommandRunLength() throws -> Int {
            guard try readBit() != 0 else { return 1 }
            let short = Int(try readBits(4))
            guard short == 15 else { return short + 2 }

            var extended = 0
            for group in 0..<3 {
                let byte = Int(try readBits(8))
                extended |= (byte & 0x7f) << (group * 7)
                if byte & 0x80 == 0 { return extended + 17 }
            }
            return extended + 17
        }

        /// Signed Rice variant used for each plane's DC delta. A zero unary
        /// prefix has a dedicated zero/small-value form; larger prefixes
        /// add successively wider magnitude ranges followed by a sign bit.
        mutating func readSignedDCRice() throws -> Int {
            var prefix = 0
            while try readBit() != 0 {
                prefix += 1
                guard prefix < 40 else {
                    throw AppleAdaptiveDCTError.malformed("DCT DC Rice prefix exceeds 39 bits")
                }
            }

            if prefix == 0 {
                guard try readBit() != 0 else { return 0 }
                return try readBit() == 0 ? 1 : -1
            }

            let magnitude: Int
            let sign: UInt32
            switch prefix {
            case 1:
                let suffix = try readBits(2)
                magnitude = 2 + Int(suffix >> 1)
                sign = suffix & 1
            case 2:
                let suffix = try readBits(3)
                magnitude = 4 + Int(suffix >> 1)
                sign = suffix & 1
            default:
                let suffix = try readBits(4)
                magnitude = prefix * 8 + Int(suffix >> 1) - 16
                sign = suffix & 1
            }
            return sign == 0 ? magnitude : -magnitude
        }

        /// Returns Y, Cb, and Cr expanded to eight-bit lanes. Chroma is sent
        /// with six bits of precision and occupies the high six bits.
        mutating func readYCC20() throws -> (y: UInt8, cb: UInt8, cr: UInt8) {
            let y = UInt8(try readBits(8))
            let cb = UInt8(try readBits(6) << 2)
            let cr = UInt8(try readBits(6) << 2)
            return (y, cb, cr)
        }

        /// Decode one sparse low-amplitude coefficient. A nil value means
        /// the coefficient is zero; index 64 is the end-of-block sentinel.
        mutating func readSmallCoefficient(
            at index: Int,
            amplitude: Int
        ) throws -> (nextIndex: Int, value: Int?) {
            let code = try readBits(2)
            switch code {
            case 0:
                return (index + 1, nil)
            case 2:
                return (index + 1, amplitude)
            case 3:
                return (index + 1, -amplitude)
            default:
                guard try readBit() != 0 else { return (64, nil) }
                let shortSkip = Int(try readBits(2))
                guard shortSkip == 3 else {
                    return (index + shortSkip + 3, nil)
                }
                var skip = 6
                while true {
                    let group = Int(try readBits(3))
                    skip += group
                    if group != 7 { break }
                }
                guard index + skip < 64 else {
                    throw AppleAdaptiveDCTError.malformed(
                        "DCT zero run passes coefficient 63")
                }
                return (index + skip, nil)
            }
        }
    }

    struct ImageMessage {
        let field1: UInt8
        let field2: UInt8
        let commandBytes: Data
        let dataBytes: Data
    }

    private(set) var lumaQuantization: [UInt16]
    private(set) var chromaQuantization: [UInt16]
    private var framebufferWidth = 0
    private var framebufferHeight = 0
    /// Contiguous, connection-owned storage; tile writes copy into existing slots.
    /// 细化只读 `map`，这里不存系数（4K 下省约 50MB，也少一次每块的整段拷贝）。
    private var tileStates = TileStorage(count: 0, storesCoefficients: false)
    private var pixelTags = PixelTags(count: 0)
    /// `pixelTags` 描述的帧缓冲和它当时的写代次。对不上就全部作废。
    private weak var taggedFramebuffer: Framebuffer?
    private var taggedFramebufferGeneration: UInt64 = 0
    private var didWritePixels = false
    /// 内容没变的块不写帧缓冲。关掉只用于差分测试：照常维护标识，但永不跳过。
    var skipsUnchangedTiles = true
    private(set) var skippedTileCount = 0
    private let scratch = TileStorage(count: 3)
    private var baseUpdateGeneration: UInt64 = 0
    // Allocate 256-slot pages only when refinement populates the cache ring.
    private var coefficientCache = [TileStorage?](repeating: nil, count: 254)
    private var cacheWriteIndex = 0
    private var cacheReadIndex = 0
    private var cachedSolidColor: UInt32?
    private var cachedPaletteFirst: UInt32?
    private var cachedPaletteSecond: UInt32?

    init() {
        lumaQuantization = Self.defaultLuma.map(UInt16.init)
        chromaQuantization = Self.defaultChroma.map(UInt16.init)
    }

    /// Remove the RFB UInt32 length prefix and apply a control message, or
    /// return the separated command/data streams for a type-0 image message.
    func ingest(_ payload: Data) throws -> ImageMessage? {
        guard payload.count >= 5 else {
            throw AppleAdaptiveDCTError.malformed("DCT payload is shorter than 5 bytes")
        }
        let base = payload.startIndex
        let length =
            Int(payload[base]) << 24
            | Int(payload[base + 1]) << 16
            | Int(payload[base + 2]) << 8
            | Int(payload[base + 3])
        guard length == payload.count - 4 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT length \(length) does not match \(payload.count - 4) bytes")
        }
        let message = payload.dropFirst(4)
        let type = message[message.startIndex]
        switch type {
        case 0:
            guard message.count >= 7 else {
                throw AppleAdaptiveDCTError.malformed("Type-0 message is shorter than 7 bytes")
            }
            let start = message.startIndex
            let dataOffset =
                Int(message[start + 3]) << 16
                | Int(message[start + 4]) << 8
                | Int(message[start + 5])
            guard dataOffset >= 6, dataOffset < message.count else {
                throw AppleAdaptiveDCTError.malformed(
                    "Type-0 data offset \(dataOffset) is outside \(message.count) bytes")
            }
            return ImageMessage(
                field1: message[start + 1],
                field2: message[start + 2],
                commandBytes: Data(message[(start + 6)..<(start + dataOffset)]),
                dataBytes: Data(message[(start + dataOffset)...]))

        case 1:
            // render() routes type 1 to the progressive-refinement/cache path
            // before calling ingest(). Keep direct ingestion side-effect free.
            return nil

        case 2:
            guard message.count == 129 else {
                throw AppleAdaptiveDCTError.malformed(
                    "Type-2 quantization message is \(message.count) bytes, expected 129")
            }
            let luma = message.dropFirst().prefix(64).map(UInt16.init)
            let chroma = message.dropFirst(65).prefix(64).map(UInt16.init)
            // 表变了，相同系数画出来的像素也变了。等值重发不算。
            if luma != lumaQuantization || chroma != chromaQuantization {
                lumaQuantization = luma
                chromaQuantization = chroma
                pixelTags.clear()
            }
            return nil

        default:
            throw AppleAdaptiveDCTError.unsupportedMessageType(type)
        }
    }

    /// Decode the currently implemented type-0 tile commands directly into
    /// the framebuffer. The coefficient store is intentionally connection-
    /// scoped: later Apple refinement commands refer to these exact tiles.
    func render(
        rect: FramebufferRect,
        payload: Data,
        to framebuffer: Framebuffer,
        drawPixels: Bool = true
    ) throws {
        guard payload.count >= 5 else {
            throw AppleAdaptiveDCTError.malformed("DCT payload is shorter than 5 bytes")
        }
        if payload[payload.startIndex + 4] == 1 {
            try renderRefinement(
                rect: rect, payload: payload, to: framebuffer,
                drawPixels: drawPixels)
            return
        }
        guard let message = try ingest(payload) else { return }
        guard framebuffer.bytesPerPixel == 4 else {
            throw AppleAdaptiveDCTError.malformed("Apple DCT requires a 32-bit framebuffer")
        }
        ensureFramebuffer(width: framebuffer.width, height: framebuffer.height)

        // None of the borrowed stream, coefficient, or pixel views escape render().
        defer { withExtendedLifetime(self) {} }
        try message.commandBytes.withUnsafeBytes { commandBytes in
            try message.dataBytes.withUnsafeBytes { dataBytes in
                try withRenderBuffers { kernel, lastDCTPixels, cachedDCTPixels in
                    var commands = BitReader(commandBytes)
                    var data = BitReader(dataBytes)
                    // The bitstream starts at byte zero with one reserved bit followed by
                    // seven command bits.
                    _ = try commands.readBit()
                    let tilesWide = (Int(rect.width) + 7) / 8
                    let tilesHigh = (Int(rect.height) + 7) / 8
                    let tileCount = tilesWide * tilesHigh
                    baseUpdateGeneration &+= 1
                    let updateGeneration = baseUpdateGeneration
                    // 这个循环每秒跑几百万次：行列递增代替除法，类属性先取到局部，
                    // 省掉每块的整数除法、独占检查和引用计数。
                    let rectX = Int(rect.x)
                    let rectY = Int(rect.y)
                    let framebufferTilesWide = (framebufferWidth + 7) / 8
                    let states = tileStates
                    let stateCount = states.count
                    let stateMetadata = states.metadata.baseAddress!
                    var localX = 0
                    var localY = 0
                    var tileNumber = 0
                    var predictor = scratch.values(at: 0)
                    var predictorMap = scratch.map(at: 0)
                    predictor.update(repeating: 0)
                    predictorMap.update(repeating: 0)
                    var predictorQuality = 0
                    var predictorTag = Self.emptyCoefficientTag
                    // `lastDCTPixels` 里现在是哪份系数的像素；0 表示还没算过。
                    var lastDCTPixelsTag: UInt64 = 0
                    let usesTileTags = rect.x % 8 == 0 && rect.y % 8 == 0
                    try withTrackedPixels(rect: rect, framebuffer: framebuffer) {
                        cursor, base, width, height, bytesPerRow in
                        while tileNumber < tileCount {
                            let command = Int(try commands.readBits(3))
                            let run = min(try commands.readCommandRunLength(), tileCount - tileNumber)
                            var runRemaining = run
                            while runRemaining > 0 {
                                runRemaining -= 1
                                let pixelX = rectX + localX * 8
                                let pixelY = rectY + localY * 8
                                let globalIndex = (pixelY / 8) * framebufferTilesWide + pixelX / 8
                                if globalIndex >= 0, globalIndex < stateCount {
                                    stateMetadata[globalIndex].generation = updateGeneration
                                    stateMetadata[globalIndex].validationSource = -1
                                    stateMetadata[globalIndex].pixelSource = -1
                                }
                                // 不对齐的矩形一块压两个网格，或者块落在画布外：不参与标识。
                                let tagIndex =
                                    usesTileTags && pixelX < width && pixelY < height
                                    ? globalIndex : -1
                                switch command {
                                case 0:
                                    try drawSolidTile(
                                        0xffff_ffff, x: pixelX, y: pixelY, base: base,
                                        width: width, height: height, bytesPerRow: bytesPerRow,
                                        tagIndex: tagIndex, cursor: &cursor)

                                case 1:
                                    guard tileNumber > 0 else {
                                        throw AppleAdaptiveDCTError.malformed(
                                            "DCT previous-tile command appears before the first tile")
                                    }
                                    // Both the saved pixel pointer and its generation
                                    // reference identify the preceding tile in this
                                    // rectangle's command order. At a local row boundary
                                    // that is the rightmost tile of the preceding row, not
                                    // the framebuffer tile immediately to the left.
                                    let sourcePixelX =
                                        rectX + (localX > 0 ? localX - 1 : tilesWide - 1) * 8
                                    let sourcePixelY =
                                        rectY + (localX > 0 ? localY : localY - 1) * 8
                                    let pixelSourceGlobalIndex =
                                        (sourcePixelY / 8)
                                        * framebufferTilesWide + sourcePixelX / 8
                                    drawCopiedTile(
                                        fromX: sourcePixelX, fromY: sourcePixelY,
                                        toX: pixelX, toY: pixelY,
                                        sourceIndex: pixelSourceGlobalIndex, tagIndex: tagIndex,
                                        base: base, width: width, height: height,
                                        bytesPerRow: bytesPerRow, cursor: &cursor)
                                    recordCopySource(
                                        validationSource: pixelSourceGlobalIndex,
                                        pixelSource: pixelSourceGlobalIndex,
                                        for: globalIndex)

                                case 2:
                                    guard pixelY >= 8 else {
                                        throw AppleAdaptiveDCTError.malformed(
                                            "DCT vertical-copy command appears at tile \(tileNumber) "
                                                + "(\(localX),\(localY))")
                                    }
                                    let sourceGlobalIndex = globalIndex - framebufferTilesWide
                                    drawCopiedTile(
                                        fromX: pixelX, fromY: pixelY - 8,
                                        toX: pixelX, toY: pixelY,
                                        sourceIndex: sourceGlobalIndex, tagIndex: tagIndex,
                                        base: base, width: width, height: height,
                                        bytesPerRow: bytesPerRow, cursor: &cursor)
                                    recordCopySource(
                                        validationSource: sourceGlobalIndex,
                                        pixelSource: sourceGlobalIndex,
                                        for: globalIndex)

                                case 3:
                                    try drawTwoColorTile(
                                        reader: &data, first: 0xffff_ffff, second: 0x0000_0000,
                                        x: pixelX, y: pixelY, base: base, width: width,
                                        height: height, bytesPerRow: bytesPerRow,
                                        tagIndex: tagIndex, cursor: &cursor)

                                case 4:
                                    let subtype = Int(try data.readBits(2))
                                    switch subtype {
                                    case 0:
                                        cachedSolidColor = try readBGRAColor(&data)
                                        try drawSolidTile(
                                            cachedSolidColor!, x: pixelX, y: pixelY, base: base,
                                            width: width, height: height, bytesPerRow: bytesPerRow,
                                            tagIndex: tagIndex, cursor: &cursor)
                                    case 1:
                                        guard let cachedSolidColor else {
                                            throw AppleAdaptiveDCTError.malformed(
                                                "DCT fill reuses a color before defining it")
                                        }
                                        try drawSolidTile(
                                            cachedSolidColor, x: pixelX, y: pixelY, base: base,
                                            width: width, height: height, bytesPerRow: bytesPerRow,
                                            tagIndex: tagIndex, cursor: &cursor)
                                    case 2:
                                        cachedPaletteFirst = try readBGRAColor(&data)
                                        cachedPaletteSecond = try readBGRAColor(&data)
                                        try drawTwoColorTile(
                                            reader: &data, first: cachedPaletteFirst!,
                                            second: cachedPaletteSecond!,
                                            x: pixelX, y: pixelY, base: base, width: width,
                                            height: height, bytesPerRow: bytesPerRow,
                                            tagIndex: tagIndex, cursor: &cursor)
                                    default:
                                        guard let cachedPaletteFirst, let cachedPaletteSecond else {
                                            throw AppleAdaptiveDCTError.malformed(
                                                "DCT two-color fill reuses a palette before defining it")
                                        }
                                        try drawTwoColorTile(
                                            reader: &data, first: cachedPaletteFirst,
                                            second: cachedPaletteSecond,
                                            x: pixelX, y: pixelY, base: base, width: width,
                                            height: height, bytesPerRow: bytesPerRow,
                                            tagIndex: tagIndex, cursor: &cursor)
                                    }
                                case 5:
                                    let coefficients: DecodedTile
                                    var coefficientMap: UnsafeMutableBufferPointer<Int8>
                                    let reusesPrevious = try data.readBit() != 0
                                    if reusesPrevious {
                                        coefficients = DecodedTile(
                                            values: predictor, quality: predictorQuality)
                                        coefficientMap = predictorMap
                                    } else {
                                        coefficientMap = predictorMap
                                        coefficientMap.update(repeating: 0)
                                        do {
                                            coefficients = try decodeNewTile(
                                                reader: &data, predictor: &predictor,
                                                map: &coefficientMap,
                                                lowCutoff: Int(message.field1),
                                                highCutoff: Int(message.field2), zigzag: kernel.zigzag)
                                            predictorQuality = coefficients.quality
                                            predictorTag = rfb_apple_dct_coefficient_tag(
                                                coefficientMap.baseAddress,
                                                coefficients.values[0], coefficients.values[64],
                                                coefficients.values[128])
                                        } catch {
                                            throw AppleAdaptiveDCTError.malformed(
                                                "DCT tile \(tileNumber) command 5 failed at data bit "
                                                    + "\(data.bitOffset): \(error.localizedDescription)")
                                        }
                                        predictorMap = coefficientMap
                                    }
                                    if globalIndex >= 0, globalIndex < stateCount {
                                        states.storeState(
                                            CachedTile(
                                                decoded: coefficients,
                                                map: coefficientMap,
                                                quality: coefficients.quality,
                                                cbCount: 1,
                                                crCount: 1,
                                                tag: predictorTag), at: globalIndex)
                                    }
                                    if drawPixels, cursor.needsWrite(predictorTag, at: tagIndex) {
                                        if lastDCTPixelsTag != predictorTag {
                                            decodeDCTTile(
                                                coefficients.values, into: lastDCTPixels, kernel: kernel)
                                            lastDCTPixelsTag = predictorTag
                                        }
                                        renderPixelTile(
                                            lastDCTPixels, x: pixelX, y: pixelY, base: base,
                                            width: width, height: height, bytesPerRow: bytesPerRow)
                                        cursor.didWrite(predictorTag, at: tagIndex)
                                    }

                                case 6, 7:
                                    let cacheIndex: Int
                                    if command == 6 {
                                        cacheIndex = Int(try data.readBits(16))
                                    } else {
                                        cacheIndex = nextCacheIndex(after: cacheReadIndex)
                                    }
                                    let cached = try cachedTile(at: cacheIndex)
                                    if drawPixels, cursor.needsWrite(cached.tag, at: tagIndex) {
                                        decodeDCTTile(
                                            cached.decoded.values, into: cachedDCTPixels, kernel: kernel)
                                        renderPixelTile(
                                            cachedDCTPixels, x: pixelX, y: pixelY, base: base,
                                            width: width, height: height, bytesPerRow: bytesPerRow)
                                        cursor.didWrite(cached.tag, at: tagIndex)
                                    }
                                default:
                                    throw AppleAdaptiveDCTError.malformed(
                                        "Invalid DCT tile command \(command)")
                                }
                                tileNumber += 1
                                localX += 1
                                if localX == tilesWide {
                                    localX = 0
                                    localY += 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func ensureFramebuffer(width: Int, height: Int) {
        guard width != framebufferWidth || height != framebufferHeight else { return }
        framebufferWidth = width
        framebufferHeight = height
        let count = ((width + 7) / 8) * ((height + 7) / 8)
        tileStates = TileStorage(count: count, storesCoefficients: false)
        pixelTags = PixelTags(count: count)
        baseUpdateGeneration = 0
        coefficientCache = Array(repeating: nil, count: 254)
        cacheWriteIndex = 0
        cacheReadIndex = 0
    }

    private func store(_ state: CachedTile, at index: Int) {
        guard index >= 0, index < tileStates.count else { return }
        tileStates.storeState(state, at: index)
    }

    /// 读走并清零：上次调用以来有没有写过帧缓冲。
    func takeDidWritePixels() -> Bool {
        defer { didWritePixels = false }
        return didWritePixels
    }

    /// 全零系数的标识：空缓存槽和矩形开头的预测值都是它。
    private static let emptyCoefficientTag: UInt64 = {
        let map = [Int8](repeating: 0, count: 99)
        return map.withUnsafeBufferPointer {
            rfb_apple_dct_coefficient_tag($0.baseAddress, 0, 0, 0)
        }
    }()

    /// 持锁写帧缓冲，并让标识和帧缓冲保持同步。
    private func withTrackedPixels<Result>(
        rect: FramebufferRect,
        framebuffer: Framebuffer,
        _ body: (
            inout TileTagCursor, UnsafeMutableRawPointer, Int, Int, Int
        ) throws -> Result
    ) rethrows -> Result {
        if taggedFramebuffer !== framebuffer
            || framebuffer.writeGeneration != taggedFramebufferGeneration {
            pixelTags.clear()
            taggedFramebuffer = framebuffer
        }
        var cursor = TileTagCursor(
            tags: pixelTags.tags, skipsUnchanged: skipsUnchangedTiles)
        defer {
            didWritePixels = didWritePixels || cursor.wrote
            skippedTileCount &+= cursor.skipped
            // 这次写入是自己做的，标识已经跟上了。
            taggedFramebufferGeneration = framebuffer.writeGeneration
            if rect.x % 8 != 0 || rect.y % 8 != 0 {
                pixelTags.clear(overlapping: rect, framebufferWidth: framebufferWidth, framebufferHeight: framebufferHeight)
            }
        }
        return try framebuffer.withUnsafeMutablePixelBytes { base, width, height, bytesPerRow, _ in
            try body(&cursor, base, width, height, bytesPerRow)
        }
    }

    /// 帧缓冲每个 8×8 网格当前内容的标识。0 表示未知，下一次必写。
    private final class PixelTags {
        let tags: UnsafeMutablePointer<UInt64>
        let count: Int

        init(count: Int) {
            self.count = count
            tags = .allocate(capacity: max(count, 1))
            tags.initialize(repeating: 0, count: max(count, 1))
        }

        deinit {
            tags.deallocate()
        }

        func clear() {
            tags.update(repeating: 0, count: count)
        }

        func clear(overlapping rect: FramebufferRect, framebufferWidth: Int, framebufferHeight: Int) {
            let columns = (framebufferWidth + 7) / 8
            let rows = (framebufferHeight + 7) / 8
            guard rect.width > 0, rect.height > 0, columns > 0 else { return }
            // 块按 8×8 画，不受矩形右下边裁剪，所以最后一块可能再压一个网格。
            let tilesWide = (Int(rect.width) + 7) / 8
            let tilesHigh = (Int(rect.height) + 7) / 8
            let lastColumn = min((Int(rect.x) + tilesWide * 8 - 1) / 8, columns - 1)
            let lastRow = min((Int(rect.y) + tilesHigh * 8 - 1) / 8, rows - 1)
            guard Int(rect.x) / 8 <= lastColumn, Int(rect.y) / 8 <= lastRow else { return }
            for row in (Int(rect.y) / 8)...lastRow {
                for column in (Int(rect.x) / 8)...lastColumn {
                    tags[row * columns + column] = 0
                }
            }
        }
    }

    /// 一次持锁写入期间的标识操作。用局部值，避免每块都走类属性的独占检查。
    private struct TileTagCursor {
        let tags: UnsafeMutablePointer<UInt64>
        let skipsUnchanged: Bool
        var skipped = 0
        var wrote = false

        @inline(__always)
        mutating func needsWrite(_ tag: UInt64, at index: Int) -> Bool {
            guard index >= 0, skipsUnchanged, tags[index] == tag else { return true }
            skipped &+= 1
            return false
        }

        @inline(__always)
        mutating func didWrite(_ tag: UInt64, at index: Int) {
            wrote = true
            if index >= 0 { tags[index] = tag }
        }
    }

    private func recordCopySource(
        validationSource: Int?, pixelSource: Int, for destination: Int
    ) {
        guard destination >= 0, destination < tileStates.count,
            pixelSource >= 0, pixelSource < tileStates.count
        else { return }
        tileStates.metadata[destination].validationSource = validationSource ?? -1
        tileStates.metadata[destination].pixelSource = pixelSource
    }

    private struct DecodedTile {
        var values: UnsafeMutableBufferPointer<Int16>
        let quality: Int
    }

    private struct CachedTile {
        let decoded: DecodedTile
        let map: UnsafeMutableBufferPointer<Int8>
        let quality: Int
        let cbCount: UInt8
        let crCount: UInt8
        let tag: UInt64
    }

    /// 细化需要的那部分块状态。
    private struct TileState {
        let map: UnsafeMutableBufferPointer<Int8>
        let quality: Int
        let cbCount: UInt8
        let crCount: UInt8
    }

    /// Owns initialized buffers. Borrowed CachedTile views are used synchronously
    /// while the decoder retains this storage; cache/framebuffer writes copy data,
    /// never retain a scratch view or alias a slot that can subsequently change.
    private final class TileStorage {
        struct Metadata {
            var quality = -1
            var cbCount: UInt8 = 0
            var crCount: UInt8 = 0
            // Copy references are valid only within the same base generation.
            var validationSource = -1
            var pixelSource = -1
            var generation: UInt64 = 0
            /// 这一格 `map` 对应的内容标识。相同就不用再拷一遍。
            var contentTag: UInt64 = 0
        }
        let count: Int
        private let coefficients: UnsafeMutableBufferPointer<Int16>
        private let maps: UnsafeMutableBufferPointer<Int8>
        let metadata: UnsafeMutableBufferPointer<Metadata>

        init(count: Int, storesCoefficients: Bool = true) {
            self.count = count
            coefficients = .allocate(capacity: storesCoefficients ? count * 192 : 0)
            maps = .allocate(capacity: count * 99)
            metadata = .allocate(capacity: count)
            coefficients.initialize(repeating: 0)
            maps.initialize(repeating: 0)
            metadata.initialize(repeating: Metadata())
        }

        deinit {
            coefficients.deinitialize()
            coefficients.deallocate()
            maps.deinitialize()
            maps.deallocate()
            metadata.deinitialize()
            metadata.deallocate()
        }

        func values(at index: Int) -> UnsafeMutableBufferPointer<Int16> {
            precondition(index >= 0 && index < count)
            return UnsafeMutableBufferPointer(rebasing: coefficients[(index * 192)..<(index * 192 + 192)])
        }

        func map(at index: Int) -> UnsafeMutableBufferPointer<Int8> {
            precondition(index >= 0 && index < count)
            return UnsafeMutableBufferPointer(rebasing: maps[(index * 99)..<(index * 99 + 99)])
        }

        subscript(index: Int) -> CachedTile? {
            guard index >= 0, index < count else { return nil }
            let info = metadata[index]
            guard info.quality >= 0 else { return nil }
            return CachedTile(
                decoded: DecodedTile(values: values(at: index), quality: info.quality),
                map: map(at: index), quality: info.quality,
                cbCount: info.cbCount, crCount: info.crCount, tag: info.contentTag)
        }

        func state(at index: Int) -> TileState? {
            guard index >= 0, index < count else { return nil }
            let info = metadata[index]
            guard info.quality >= 0 else { return nil }
            return TileState(
                map: map(at: index), quality: info.quality,
                cbCount: info.cbCount, crCount: info.crCount)
        }

        /// 只存细化要读的状态。系数由 `map` 和 DC 决定，标识相同时 `map` 也相同。
        @inline(__always)
        func storeState(_ tile: CachedTile, at index: Int) {
            if metadata[index].contentTag != tile.tag {
                memmove(maps.baseAddress! + index * 99, tile.map.baseAddress!, 99)
                metadata[index].contentTag = tile.tag
            }
            metadata[index].quality = tile.quality
            metadata[index].cbCount = tile.cbCount
            metadata[index].crCount = tile.crCount
        }

        func store(_ tile: CachedTile, at index: Int) {
            let destination = values(at: index)
            let destinationMap = map(at: index)
            // memmove also permits storing a view back into its own slot.
            memmove(destination.baseAddress!, tile.decoded.values.baseAddress!, 192 * 2)
            memmove(destinationMap.baseAddress!, tile.map.baseAddress!, 99)
            metadata[index].quality = tile.quality
            metadata[index].cbCount = tile.cbCount
            metadata[index].crCount = tile.crCount
            metadata[index].contentTag = tile.tag
        }
    }

    private func cache(_ tile: CachedTile, at index: Int) {
        let page = index / 256
        if coefficientCache[page] == nil { coefficientCache[page] = TileStorage(count: 256) }
        coefficientCache[page]!.store(tile, at: index % 256)
    }

    private func cachedTile(at index: Int) throws -> CachedTile {
        guard index > 0, index < 65_000 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT coefficient-cache tile \(index) is outside the valid range")
        }
        cacheReadIndex = index
        if let cached = coefficientCache[index / 256]?[index % 256] { return cached }
        return CachedTile(
            decoded: DecodedTile(values: scratch.values(at: 2), quality: 0),
            map: scratch.map(at: 2), quality: 0, cbCount: 0, crCount: 0,
            tag: Self.emptyCoefficientTag)
    }

    private func nextCacheIndex(after index: Int) -> Int {
        index >= 64_999 ? 1 : index + 1
    }

    private func renderRefinement(
        rect: FramebufferRect, payload: Data, to framebuffer: Framebuffer,
        drawPixels: Bool
    ) throws {
        let base = payload.startIndex
        let length =
            Int(payload[base]) << 24 | Int(payload[base + 1]) << 16
            | Int(payload[base + 2]) << 8 | Int(payload[base + 3])
        guard length == payload.count - 4, length >= 4 else {
            throw AppleAdaptiveDCTError.malformed("Malformed DCT type-1 message length")
        }
        guard framebuffer.bytesPerPixel == 4 else {
            throw AppleAdaptiveDCTError.malformed("Apple DCT requires a 32-bit framebuffer")
        }
        let threshold1 = Int(payload[base + 5])
        let threshold2 = Int(payload[base + 6])
        guard threshold1 < 16, threshold2 < 21 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT refinement thresholds \(threshold1),\(threshold2) exceed Apple limits")
        }
        defer { withExtendedLifetime(self) {} }
        try payload.withUnsafeBytes { payloadBytes in
            try withRenderBuffers { kernel, pixels, _ in
                var bits = BitReader(UnsafeRawBufferPointer(rebasing: payloadBytes[7...]))
                ensureFramebuffer(width: framebuffer.width, height: framebuffer.height)
                let tilesWide = (Int(rect.width) + 7) / 8
                let tilesHigh = (Int(rect.height) + 7) / 8
                let framebufferTilesWide = (framebufferWidth + 7) / 8
                let usesTileTags = rect.x % 8 == 0 && rect.y % 8 == 0

                try withTrackedPixels(rect: rect, framebuffer: framebuffer) {
                    cursor, raw, width, height, bytesPerRow in
                    var tileNumber = 0
                    while tileNumber < tilesWide * tilesHigh {
                        defer { tileNumber += 1 }
                        let localX = tileNumber % tilesWide
                        let localY = tileNumber / tilesWide
                        let pixelX = Int(rect.x) + localX * 8
                        let pixelY = Int(rect.y) + localY * 8
                        let globalIndex = (pixelY / 8) * framebufferTilesWide + pixelX / 8
                        guard globalIndex >= 0 && globalIndex < tileStates.count else {
                            throw AppleAdaptiveDCTError.malformed(
                                "DCT refinement tile lies outside the framebuffer")
                        }
                        let tagIndex =
                            usesTileTags && pixelX < width && pixelY < height ? globalIndex : -1
                        let command = Int(try bits.readBits(2))
                        let cached: CachedTile?
                        let updatesTileState: Bool
                        switch command {
                        case 0:
                            cached = nil
                            updatesTileState = false
                        case 1:
                            let refined = try refineTile(
                                at: globalIndex, reader: &bits,
                                threshold1: threshold1, threshold2: threshold2, zigzag: kernel.zigzag)
                            // The type-1 path advances the coefficient-cache ring
                            // here. Type-0 base tiles do not consume cache keys.
                            cacheWriteIndex = nextCacheIndex(after: cacheWriteIndex)
                            cache(refined, at: cacheWriteIndex)
                            cached = refined
                            updatesTileState = true
                        case 2:
                            // DecodeMVSPartialUpdate command 2 follows the source
                            // reference recorded by a type-0 horizontal/vertical
                            // copy. The source may already have been refined earlier
                            // in this update, so repeat its pixel copy now. The decoder
                            // rejects stale references by comparing the two
                            // tiles' base-update generation counters.
                            let metadata = tileStates.metadata[globalIndex]
                            let validationSource = metadata.validationSource
                            let pixelSource = metadata.pixelSource
                            if validationSource >= 0, pixelSource >= 0,
                                tileStates.metadata[validationSource].generation == metadata.generation
                            {
                                let sourcePixelX =
                                    (pixelSource % framebufferTilesWide) * 8
                                let sourcePixelY =
                                    (pixelSource / framebufferTilesWide) * 8
                                if drawPixels {
                                    drawCopiedTile(
                                        fromX: sourcePixelX, fromY: sourcePixelY,
                                        toX: pixelX, toY: pixelY,
                                        sourceIndex: pixelSource, tagIndex: tagIndex,
                                        base: raw, width: width, height: height,
                                        bytesPerRow: bytesPerRow, cursor: &cursor)
                                }
                            }
                            cached = nil
                            updatesTileState = false
                        case 3:
                            let cacheIndex: Int
                            if try bits.readBit() != 0 {
                                cacheIndex = nextCacheIndex(after: cacheReadIndex)
                            } else {
                                cacheIndex = Int(try bits.readBits(16))
                            }
                            guard cacheIndex > 0, cacheIndex < 65_000 else {
                                throw AppleAdaptiveDCTError.malformed(
                                    "DCT refinement tile \(globalIndex) read invalid cache key "
                                        + "\(cacheIndex) at bit \(bits.bitOffset)")
                            }
                            cached = try cachedTile(at: cacheIndex)
                            updatesTileState = false
                        default:
                            cached = nil
                            updatesTileState = false
                        }
                        guard let cached else { continue }
                        if updatesTileState {
                            store(cached, at: globalIndex)
                        }
                        if drawPixels, cursor.needsWrite(cached.tag, at: tagIndex) {
                            decodeDCTTile(cached.decoded.values, into: pixels, kernel: kernel)
                            renderPixelTile(
                                pixels, x: pixelX, y: pixelY, base: raw,
                                width: width, height: height, bytesPerRow: bytesPerRow)
                            cursor.didWrite(cached.tag, at: tagIndex)
                        }
                    }
                }
            }
        }
    }

    private func refineTile(
        at index: Int, reader: inout BitReader,
        threshold1: Int, threshold2: Int, zigzag: UnsafeBufferPointer<Int>
    ) throws -> CachedTile {
        guard let oldState = tileStates.state(at: index) else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT refinement tile \(index) has no coefficient state")
        }
        let old = oldState.map
        guard oldState.cbCount == 1, oldState.crCount == 1 else {
            throw AppleAdaptiveDCTError.malformed(
                "DCT refinement tile \(index) at bit \(reader.bitOffset) requires "
                    + "single-coefficient chroma predictors; found "
                    + "Cb=\(oldState.cbCount), Cr=\(oldState.crCount)")
        }
        var map = scratch.map(at: 1)
        map.update(repeating: 0)
        map[0] = old[0]
        let targetY = Int(try reader.readBits(6))
        let oldY = oldState.quality
        var next = min(oldY, targetY + 1)
        if oldY > 14 {
            if targetY == 0 {
                next = 1
            } else if next >= 2 {
                var coefficient = 1
                while coefficient < next {
                    defer { coefficient += 1 }
                    map[coefficient] = try adjustByOne(old[coefficient], reader: &reader)
                }
            }
            if next <= targetY {
                var coefficient = next
                while coefficient <= targetY && coefficient < 64 {
                    defer { coefficient += 1 }
                    map[coefficient] = try adjustOrRead(
                        old[coefficient], bits: 3, reader: &reader)
                }
            }
        } else {
            if next >= 2 {
                var coefficient = 1
                while coefficient < next {
                    defer { coefficient += 1 }
                    map[coefficient] = try adjustOrRead(
                        old[coefficient], bits: 3, reader: &reader)
                }
            } else {
                next = 1
            }
            if next <= targetY {
                var coefficient = next
                while coefficient <= targetY && coefficient < 64 {
                    defer { coefficient += 1 }
                    map[coefficient] = try adjustOrRead(
                        old[coefficient], bits: 4, reader: &reader)
                }
            }
        }
        map[84] = try adjustByOne(old[84], reader: &reader)
        try decodeLuminanceACHuffman(
            reader: &reader, into: &map, base: 84, maximum: threshold1)
        map[64] = try adjustByOne(old[64], reader: &reader)
        try decodeLuminanceACHuffman(
            reader: &reader, into: &map, base: 64, maximum: threshold2)

        let quality = min(64, targetY + 1)
        let decoded = decodedTile(from: map, quality: quality, zigzag: zigzag)
        return CachedTile(
            decoded: decoded, map: map, quality: quality,
            cbCount: UInt8(threshold2 + 1), crCount: UInt8(threshold1 + 1),
            tag: rfb_apple_dct_coefficient_tag(
                map.baseAddress, decoded.values[0], decoded.values[64], decoded.values[128]))
    }

    private func adjustByOne(
        _ coefficient: Int8, reader: inout BitReader
    ) throws -> Int8 {
        let adjustment = Int(try reader.readBit())
        let value = Int(coefficient)
        if value > 0 { return Int8(clamping: value + adjustment) }
        if value < 0 { return Int8(clamping: value - adjustment) }
        guard adjustment != 0 else { return 0 }
        return try reader.readBit() == 0 ? 1 : -1
    }

    private func adjustOrRead(
        _ coefficient: Int8, bits: Int, reader: inout BitReader
    ) throws -> Int8 {
        let value = Int(coefficient)
        guard value != 0 else {
            return Int8(clamping: try reader.readSignedDCRice())
        }
        let adjustment = Int(try reader.readBits(bits))
        let signedAdjustment = value < 0 ? -adjustment : adjustment
        return Int8(clamping: value + signedAdjustment)
    }

    private func decodedTile(
        from map: UnsafeMutableBufferPointer<Int8>, quality: Int, zigzag: UnsafeBufferPointer<Int>
    ) -> DecodedTile {
        let values = scratch.values(at: 1)
        values.update(repeating: 0)
        var coefficient = 0
        while coefficient < 64 {
            defer { coefficient += 1 }
            values[zigzag[coefficient]] = Int16(map[coefficient])
        }
        coefficient = 0
        while coefficient < 20 {
            defer { coefficient += 1 }
            values[64 + zigzag[coefficient]] = Int16(map[64 + coefficient])
        }
        coefficient = 0
        while coefficient < 15 {
            defer { coefficient += 1 }
            values[128 + zigzag[coefficient]] = Int16(map[84 + coefficient])
        }
        return DecodedTile(values: values, quality: quality)
    }

    private func decodeNewTile(
        reader: inout BitReader,
        predictor: inout UnsafeMutableBufferPointer<Int16>,
        map: inout UnsafeMutableBufferPointer<Int8>,
        lowCutoff: Int,
        highCutoff: Int, zigzag: UnsafeBufferPointer<Int>
    ) throws -> DecodedTile {
        let reuseChroma = try reader.readBit() != 0
        let cutoff = try reader.readBit() != 0 ? highCutoff : lowCutoff
        let previousY = predictor[0]
        let previousCb = predictor[64]
        let previousCr = predictor[128]
        let values = predictor
        values.update(repeating: 0)
        if reuseChroma {
            values[64] = previousCb
            values[128] = previousCr
        } else {
            values[64] = Int16(clamping: (halfTowardZero(previousCb) - (try reader.readSignedDCRice())) * 2)
            values[128] = Int16(clamping: (halfTowardZero(previousCr) - (try reader.readSignedDCRice())) * 2)
        }
        values[0] = Int16(clamping: Int(previousY) - (try reader.readSignedDCRice()))
        map[0] = Int8(truncatingIfNeeded: values[0])
        map[64] = Int8(truncatingIfNeeded: values[64])
        map[84] = Int8(truncatingIfNeeded: values[128])

        var coefficient = 1
        while coefficient < 64 {
            let amplitude: Int
            if cutoff < 15 {
                amplitude = coefficient < cutoff ? 8 : 16
            } else {
                amplitude = coefficient < cutoff ? 2 : 8
            }
            if try reader.readBit() == 0 {
                let result = try reader.readSmallCoefficient(
                    at: coefficient, amplitude: amplitude)
                if let value = result.value {
                    values[zigzag[coefficient]] = Int16(clamping: value)
                    map[coefficient] = Int8(truncatingIfNeeded: value)
                }
                coefficient = result.nextIndex
                continue
            }

            let raw = try readLargeCoefficient(
                reader: &reader, coefficient: coefficient)
            let shift: Int
            if cutoff < 15 {
                shift = coefficient < cutoff ? 3 : 4
            } else {
                shift = coefficient < cutoff ? 1 : 3
            }
            let stored = Int8(truncatingIfNeeded: raw << shift)
            map[coefficient] = stored
            values[zigzag[coefficient]] = Int16(stored)
            coefficient += 1
        }
        predictor = values
        return DecodedTile(values: values, quality: cutoff)
    }

    private func readLargeCoefficient(
        reader: inout BitReader,
        coefficient: Int
    ) throws -> Int {
        let maximumPrefix = coefficient < 6 ? 34 : 20
        var prefix = 0
        while try reader.readBit() != 0 {
            prefix += 1
            guard prefix < maximumPrefix else {
                throw AppleAdaptiveDCTError.malformed("DCT AC prefix is too long")
            }
        }
        let magnitude: Int
        let sign: UInt32
        if coefficient < 6 {
            if prefix <= 3 {
                let suffix = try reader.readBits(3)
                magnitude = prefix * 4 + Int(suffix >> 1) + 2
                sign = suffix & 1
            } else {
                let suffix = try reader.readBits(4)
                magnitude = prefix * 8 + Int(suffix >> 1) - 14
                sign = suffix & 1
            }
        } else if prefix == 0 {
            let suffix = try reader.readBits(2)
            magnitude = 2 + Int(suffix >> 1)
            sign = suffix & 1
        } else if prefix == 1 {
            let suffix = try reader.readBits(3)
            magnitude = 4 + Int(suffix >> 1)
            sign = suffix & 1
        } else {
            let suffix = try reader.readBits(4)
            magnitude = prefix * 8 + Int(suffix >> 1) - 8
            sign = suffix & 1
        }
        return sign == 0 ? magnitude : -magnitude
    }

    private func halfTowardZero(_ value: Int16) -> Int {
        Int(value) / 2
    }

    private func readBGRAColor(_ reader: inout BitReader) throws -> UInt32 {
        let color = try reader.readYCC20()
        return bgra(y: color.y, cb: color.cb, cr: color.cr)
    }

    private func drawSolidTile(
        _ color: UInt32, x: Int, y: Int, base: UnsafeMutableRawPointer,
        width: Int, height: Int, bytesPerRow: Int,
        tagIndex: Int, cursor: inout TileTagCursor
    ) throws {
        // 最高位标记纯色，低 32 位就是颜色，不用哈希。
        let tag = UInt64(1) << 63 | UInt64(color)
        guard cursor.needsWrite(tag, at: tagIndex) else { return }
        defer { cursor.didWrite(tag, at: tagIndex) }
        let maxX = min(x + 8, width)
        let maxY = min(y + 8, height)
        guard x >= 0, y >= 0, x < maxX, y < maxY else { return }
        var row = y
        while row < maxY {
            let pixels = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            var column = x
            while column < maxX {
                pixels[column] = color.littleEndian
                column += 1
            }
            row += 1
        }
    }

    /// 拷贝块继承源块的标识。两边标识相同时内容已经一样，不用读写帧缓冲。
    private func drawCopiedTile(
        fromX: Int, fromY: Int, toX: Int, toY: Int,
        sourceIndex: Int, tagIndex: Int,
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
        cursor: inout TileTagCursor
    ) {
        // 源在画布外时拷贝什么也不做，也就没有可继承的标识。
        let sourceTag =
            tagIndex >= 0 && fromX < width && fromY < height && sourceIndex >= 0
            && sourceIndex < tileStates.count ? cursor.tags[sourceIndex] : 0
        if sourceTag != 0, !cursor.needsWrite(sourceTag, at: tagIndex) { return }
        copyTile(
            fromX: fromX, fromY: fromY, toX: toX, toY: toY,
            base: base, width: width, height: height, bytesPerRow: bytesPerRow)
        // 源被画布裁掉一截时，目标只盖到一部分，不能用源的标识代表它。
        let coversDestination =
            min(8, width - max(fromX, toX)) == min(8, width - toX)
            && min(8, min(height - fromY, height - toY)) == min(8, height - toY)
        cursor.didWrite(coversDestination ? sourceTag : 0, at: tagIndex)
    }

    private func copyTile(
        fromX: Int, fromY: Int, toX: Int, toY: Int,
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int
    ) {
        let pixelCount = min(8, width - max(fromX, toX))
        let rowCount = min(8, min(height - fromY, height - toY))
        guard fromX >= 0, fromY >= 0, toX >= 0, toY >= 0,
            pixelCount > 0, rowCount > 0
        else { return }
        var row = rowCount
        while row > 0 {
            row -= 1
            let source = base.advanced(by: (fromY + row) * bytesPerRow + fromX * 4)
            let destination = base.advanced(by: (toY + row) * bytesPerRow + toX * 4)
            memmove(destination, source, pixelCount * 4)
        }
    }

    private func drawTwoColorTile(
        reader: inout BitReader, first: UInt32, second: UInt32,
        x: Int, y: Int, base: UnsafeMutableRawPointer,
        width: Int, height: Int, bytesPerRow: Int,
        tagIndex: Int, cursor: inout TileTagCursor
    ) throws {
        // 位流总要读完。整行取 first 的行，掩码等价于全 1。
        var rowControl = UInt8(try reader.readBits(8))
        var masks: UInt64 = 0
        var row = 0
        while row < 8 {
            let rowMask = rowControl & 0x80 != 0 ? UInt8(0xff) : UInt8(try reader.readBits(8))
            rowControl <<= 1
            masks = masks << 8 | UInt64(rowMask)
            row += 1
        }
        let tag = rfb_apple_dct_two_color_tag(first, second, masks)
        guard cursor.needsWrite(tag, at: tagIndex) else { return }
        defer { cursor.didWrite(tag, at: tagIndex) }
        row = 0
        while row < 8 {
            defer { row += 1 }
            guard y + row < height else { continue }
            let rowMask = UInt8(truncatingIfNeeded: masks >> UInt64((7 - row) * 8))
            let pixels = base.advanced(by: (y + row) * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            var column = 0
            while column < 8 && x + column < width {
                defer { column += 1 }
                let color = rowMask & (0x80 >> column) == 0 ? second : first
                pixels[x + column] = color.littleEndian
            }
        }
    }

    private func decodeLuminanceACHuffman(
        reader: inout BitReader,
        into map: inout UnsafeMutableBufferPointer<Int8>,
        base: Int,
        maximum: Int
    ) throws {
        guard maximum > 0 else { return }
        var coefficient = 1
        while coefficient <= maximum {
            var code = 0
            var firstCode = 0
            var valueIndex = 0
            var symbol: UInt8?
            var length = 1
            while length <= 16 {
                defer { length += 1 }
                code = (code << 1) | Int(try reader.readBit())
                let count = Self.luminanceACCodeCounts[length - 1]
                let delta = code - firstCode
                if delta >= 0, delta < count {
                    symbol = Self.luminanceACValues[valueIndex + delta]
                    break
                }
                valueIndex += count
                firstCode = (firstCode + count) << 1
            }
            guard let symbol else {
                throw AppleAdaptiveDCTError.malformed("Invalid DCT refinement Huffman code")
            }
            let zeroRun = Int(symbol >> 4)
            let amplitudeBits = Int(symbol & 0x0f)
            if amplitudeBits == 0 {
                if zeroRun == 15 {
                    coefficient += 16
                    continue
                }
                return
            }
            coefficient += zeroRun
            var amplitude = Int(try reader.readBits(amplitudeBits))
            let midpoint = 1 << (amplitudeBits - 1)
            if amplitude < midpoint {
                amplitude -= (1 << amplitudeBits) - 1
            }
            let destination = base + coefficient
            if map.indices.contains(destination) {
                map[destination] = Int8(clamping: amplitude)
            }
            coefficient += 1
        }
    }

    private struct Kernel {
        let luma: UnsafePointer<UInt16>
        let chroma: UnsafePointer<UInt16>
        let zigzag: UnsafeBufferPointer<Int>
    }

    private func withRenderBuffers<Result>(
        _ body: (Kernel, UnsafeMutableBufferPointer<UInt32>, UnsafeMutableBufferPointer<UInt32>) throws ->
            Result
    ) rethrows -> Result {
        try lumaQuantization.withUnsafeBufferPointer { luma in
            try chromaQuantization.withUnsafeBufferPointer { chroma in
                try Self.zigzag.withUnsafeBufferPointer { zigzag in
                    try withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 128) { pixels in
                        pixels.initialize(repeating: 0)
                        return try body(
                            Kernel(luma: luma.baseAddress!, chroma: chroma.baseAddress!, zigzag: zigzag),
                            UnsafeMutableBufferPointer(rebasing: pixels[0..<64]),
                            UnsafeMutableBufferPointer(rebasing: pixels[64..<128]))
                    }
                }
            }
        }
    }

    private func decodeDCTTile(
        _ coefficients: UnsafeMutableBufferPointer<Int16>,
        into tile: UnsafeMutableBufferPointer<UInt32>, kernel: Kernel
    ) {
        rfb_apple_dct_tile_bgra(tile.baseAddress, coefficients.baseAddress, kernel.luma, kernel.chroma)
    }

    private func renderPixelTile(
        _ tile: UnsafeMutableBufferPointer<UInt32>, x: Int, y: Int,
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int
    ) {
        let columns = min(8, width - x)
        let rows = min(8, height - y)
        guard x >= 0, y >= 0, columns > 0, rows > 0 else { return }
        // Supported Apple architectures are little-endian, as is BGRA storage.
        var row = 0
        while row < rows {
            defer { row += 1 }
            memcpy(
                base.advanced(by: (y + row) * bytesPerRow + x * 4),
                tile.baseAddress!.advanced(by: row * 8), columns * 4)
        }
    }

    private func bgra(y: UInt8, cb: UInt8, cr: UInt8) -> UInt32 {
        let yFixed = (Int(y) << 20) + (1 << 19)
        let cbSigned = Int(cb) - 128
        let crSigned = Int(cr) - 128
        let red = UInt32(UInt8(clamping: (yFixed + crSigned * (5_743 << 8)) >> 20))
        let greenTerm = (cbSigned * -(1_410 << 8)) & ~0xffff
        let green = UInt32(UInt8(clamping: (yFixed + crSigned * -(2_925 << 8) + greenTerm) >> 20))
        let blue = UInt32(UInt8(clamping: (yFixed + cbSigned * (7_258 << 8)) >> 20))
        return 0xff00_0000 | red << 16 | green << 8 | blue
    }
    private static let zigzag = [
        0, 1, 8, 16, 9, 2, 3, 10,
        17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63,
    ]

    // The refinement stream uses the standard JPEG luminance AC table.
    // These canonical counts/values are equivalent to the 13-node lookup
    // table embedded in compatible Adaptive DCT decoders.
    private static let luminanceACCodeCounts = [
        0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125,
    ]
    private static let luminanceACValues: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
        0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
        0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
        0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
        0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
        0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
        0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
        0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
        0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    ]

    /// JPEG-derived default quantization values for this encoding profile.
    private static let defaultLuma: [UInt8] = [
        16, 11, 11, 14, 24, 22, 24, 33,
        11, 12, 11, 11, 26, 18, 19, 23,
        13, 13, 14, 24, 20, 21, 22, 28,
        13, 17, 14, 21, 23, 25, 34, 34,
        17, 22, 18, 25, 31, 32, 34, 44,
        24, 20, 17, 27, 35, 40, 44, 54,
        30, 35, 28, 30, 34, 44, 54, 64,
        35, 30, 33, 38, 45, 55, 65, 75,
    ]
    private static let defaultChroma: [UInt8] = [
        19, 19, 24, 47, 76, 99, 99, 99,
        19, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        76, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
    ]
}
