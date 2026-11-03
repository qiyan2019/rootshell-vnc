import Foundation
import CoreGraphics
import IOSurface
import RFBProtocol

/// 一块帧缓冲内存。32 位帧缓冲放在 IOSurface 里，GPU 能直接把它当纹理读（零拷贝）。
/// 选 IOSurface 而不是共享 MTLBuffer 上的线性纹理：后者在模拟器里不支持
/// （驱动报 "Linear texture can only be created on buffers with MTLStorageModePrivate"），
/// 用 IOSurface 时真机和模拟器走同一条路径。
/// 单独成类是为了引用计数：resize 换内存时，纹理和正在读它的 GPU 命令还持有旧的这块。
public final class FramebufferStorage: @unchecked Sendable {
    /// 有值时可以映射成纹理。16 位帧缓冲或超大尺寸没有，走图片路径。
    public let surface: IOSurfaceRef?
    public let base: UnsafeMutableRawPointer
    public let byteCount: Int
    public let bytesPerRow: Int

    /// 超过这个尺寸不建 IOSurface。Apple GPU 的纹理边长上限（iOS 18 能跑的设备都是 16384）。
    public static let maximumSurfaceDimension = 16_384
    /// 行距对齐。线性纹理和 IOSurface 的要求都不超过 256 字节。
    public static let rowAlignment = 256

    private let mappedLength: Int

    init(width: Int, height: Int, bytesPerPixel: Int) {
        let unalignedRow = width * bytesPerPixel
        let alignedRow = (unalignedRow + Self.rowAlignment - 1)
            / Self.rowAlignment * Self.rowAlignment
        let length = alignedRow * height
        bytesPerRow = alignedRow

        if bytesPerPixel == 4,
           max(width, height) <= Self.maximumSurfaceDimension,
           let surface = Self.makeSurface(
            width: width, height: height, bytesPerRow: alignedRow, byteCount: length) {
            self.surface = surface
            IOSurfaceLock(surface, [], nil)
            base = IOSurfaceGetBaseAddress(surface)
            byteCount = IOSurfaceGetAllocSize(surface)
            // 从黑屏开始。
            memset(base, 0, byteCount)
            IOSurfaceUnlock(surface, [], nil)
            mappedLength = 0
            return
        }

        surface = nil
        // 匿名映射由内核清零，从黑屏开始。
        let pageSize = Int(getpagesize())
        let mapped = max(pageSize, (length + pageSize - 1) / pageSize * pageSize)
        let pointer = mmap(nil, mapped, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let pointer, pointer != MAP_FAILED else {
            fatalError("Framebuffer allocation of \(mapped) bytes failed")
        }
        base = pointer
        byteCount = mapped
        mappedLength = mapped
    }

    deinit {
        if mappedLength > 0 {
            munmap(base, mappedLength)
        }
    }

    private static func makeSurface(
        width: Int, height: Int, bytesPerRow: Int, byteCount: Int
    ) -> IOSurfaceRef? {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: byteCount,
            // 'BGRA'：帧缓冲的内存顺序是 B、G、R、X。
            kIOSurfacePixelFormat: 0x4247_5241 as UInt32,
        ]
        return IOSurfaceCreate(properties as CFDictionary)
    }

    /// 碰内存前后必须成对调用（IOSurface 的合同）。
    func beginAccess(readOnly: Bool) {
        guard let surface else { return }
        IOSurfaceLock(surface, readOnly ? .readOnly : [], nil)
    }

    func endAccess(readOnly: Bool) {
        guard let surface else { return }
        IOSurfaceUnlock(surface, readOnly ? .readOnly : [], nil)
    }
}

/// 呈现层读帧缓冲需要的全部信息，取的时候是一致的一份。
public struct FramebufferPresentationStorage: Sendable {
    public let storage: FramebufferStorage
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bytesPerPixel: Int
}

/// Thread-safe framebuffer backed by memory the GPU can read directly.
/// Uses NSLock (not actor) for synchronous read access from the render path.
public final class Framebuffer: @unchecked Sendable {

    // MARK: - Public properties

    public private(set) var width: Int
    public private(set) var height: Int
    public let bytesPerPixel: Int
    public private(set) var bytesPerRow: Int

    // MARK: - Private state

    private let lock = NSLock()
    private var storage: FramebufferStorage
    private var pixelData: UnsafeMutableRawPointer
    private let colorSpace: CGColorSpace
    private let bitmapInfo: UInt32
    private let bitsPerComponent: Int

    /// Take a consistent geometry snapshot while resize may be running on the
    /// render queue.
    package var size: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return CGSize(width: width, height: height)
    }

    // MARK: - Init

    /// Create a framebuffer with the given dimensions.
    public init(width: Int, height: Int, pixelFormat: PixelFormat) {
        precondition(width > 0 && height > 0, "Framebuffer dimensions must be positive")

        self.width = width
        self.height = height
        self.bytesPerPixel = pixelFormat.bytesPerPixel
        self.storage = FramebufferStorage(
            width: width, height: height, bytesPerPixel: pixelFormat.bytesPerPixel)
        self.bytesPerRow = storage.bytesPerRow
        self.pixelData = storage.base
        self.colorSpace = CGColorSpaceCreateDeviceRGB()

        if pixelFormat.bytesPerPixel == 2 {
            // XRGB1555 little-endian — wire pixels from a 16bpp "thousands"
            // session are stored (and displayed) without conversion.
            self.bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
            self.bitsPerComponent = 5
        } else {
            // BGRX: the fourth byte is depth-24 padding, which Raw/Zlib servers
            // such as wayshare send as zero; treating it as alpha draws black.
            self.bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            self.bitsPerComponent = 8
        }

    }

    // MARK: - Write operations

    /// 任何写入都会递增。解码器靠它发现别人写过帧缓冲；新增写入口忘了处理也只会多画，不会漏画。
    private var writeGenerationStorage: UInt64 = 0

    /// 当前写代次。Thread-safe.
    public var writeGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return writeGenerationStorage
    }

    /// Perform one compound render operation while holding the framebuffer
    /// lock. ZRLE consists of hundreds or thousands of 64×64 tiles; exposing a
    /// scoped buffer avoids acquiring the lock once per tile (or once per
    /// palette row) while keeping the raw storage private and thread-safe.
    public func withUnsafeMutablePixelBytes<Result>(
        _ body: (
            UnsafeMutableRawPointer,
            Int,
            Int,
            Int,
            Int
        ) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        writeGenerationStorage &+= 1
        storage.beginAccess(readOnly: false)
        defer { storage.endAccess(readOnly: false) }
        return try body(pixelData, width, height, bytesPerRow, bytesPerPixel)
    }

    /// Write raw pixel data for a rectangle region. Thread-safe.
    public func update(x: Int, y: Int, width w: Int, height h: Int, data: Data) {
        guard w > 0, h > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        writeGenerationStorage &+= 1
        storage.beginAccess(readOnly: false)
        defer { storage.endAccess(readOnly: false) }

        let srcBytesPerRow = w * bytesPerPixel
        data.withUnsafeBytes { srcBuffer in
            guard let srcBase = srcBuffer.baseAddress else { return }
            for row in 0 ..< h {
                let dstY = y + row
                guard dstY >= 0, dstY < self.height else { continue }

                let srcOffset = row * srcBytesPerRow
                let dstOffset = dstY * self.bytesPerRow + x * self.bytesPerPixel

                let copyBytes = min(srcBytesPerRow, (self.width - x) * self.bytesPerPixel)
                guard copyBytes > 0 else { continue }
                guard srcOffset + copyBytes <= srcBuffer.count else { continue }

                memcpy(
                    pixelData.advanced(by: dstOffset),
                    srcBase.advanced(by: srcOffset),
                    copyBytes
                )
            }
        }
    }

    /// Copy a rectangle from one position to another. Thread-safe.
    /// Handles overlapping regions correctly. Clips to framebuffer bounds.
    public func copyRect(srcX: Int, srcY: Int, dstX: Int, dstY: Int, width w: Int, height h: Int) {
        guard w > 0, h > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        writeGenerationStorage &+= 1
        storage.beginAccess(readOnly: false)
        defer { storage.endAccess(readOnly: false) }

        // Clip to framebuffer bounds to prevent out-of-bounds access
        let clippedW = min(w, min(width - srcX, width - dstX))
        let clippedH = min(h, min(height - srcY, height - dstY))
        guard clippedW > 0, clippedH > 0,
              srcX >= 0, srcY >= 0, dstX >= 0, dstY >= 0,
              srcX + clippedW <= width, srcY + clippedH <= height,
              dstX + clippedW <= width, dstY + clippedH <= height else {
            return
        }

        let rowBytes = clippedW * bytesPerPixel

        // Determine copy order to handle overlapping regions
        if dstY > srcY {
            // Copy bottom-to-top to avoid overwriting source data
            for row in stride(from: clippedH - 1, through: 0, by: -1) {
                let srcOffset = (srcY + row) * bytesPerRow + srcX * bytesPerPixel
                let dstOffset = (dstY + row) * bytesPerRow + dstX * bytesPerPixel
                memmove(
                    pixelData.advanced(by: dstOffset),
                    pixelData.advanced(by: srcOffset),
                    rowBytes
                )
            }
        } else {
            for row in 0 ..< clippedH {
                let srcOffset = (srcY + row) * bytesPerRow + srcX * bytesPerPixel
                let dstOffset = (dstY + row) * bytesPerRow + dstX * bytesPerPixel
                memmove(
                    pixelData.advanced(by: dstOffset),
                    pixelData.advanced(by: srcOffset),
                    rowBytes
                )
            }
        }
    }

    /// Fill a rectangle with a solid color. Thread-safe.
    /// `pixel` should contain exactly `bytesPerPixel` bytes representing the fill color.
    public func fillRect(x: Int, y: Int, width w: Int, height h: Int, pixel: Data) {
        guard w > 0, h > 0,
              pixel.count >= bytesPerPixel else { return }

        lock.lock()
        defer { lock.unlock() }
        writeGenerationStorage &+= 1
        storage.beginAccess(readOnly: false)
        defer { storage.endAccess(readOnly: false) }

        pixel.withUnsafeBytes { pixelBuffer in
            guard let pixelBase = pixelBuffer.baseAddress else { return }
            let startX = max(0, x)
            let endX = min(self.width, x + w)
            let startY = max(0, y)
            let endY = min(self.height, y + h)
            guard startX < endX, startY < endY else { return }

            let rowBytes = (endX - startX) * bytesPerPixel
            let firstRowOffset = startY * bytesPerRow + startX * bytesPerPixel
            let firstRow = pixelData.advanced(by: firstRowOffset)

            // Seed one pixel, then double the initialized span. A 64-pixel
            // solid ZRLE tile takes six copies instead of 4096 tiny memcpys.
            memcpy(firstRow, pixelBase, bytesPerPixel)
            var initializedBytes = bytesPerPixel
            while initializedBytes < rowBytes {
                let copyBytes = min(initializedBytes, rowBytes - initializedBytes)
                memcpy(firstRow.advanced(by: initializedBytes), firstRow, copyBytes)
                initializedBytes += copyBytes
            }

            // Every later scanline is identical to the first.
            if endY - startY > 1 {
                for row in (startY + 1) ..< endY {
                    let destination = pixelData.advanced(
                        by: row * bytesPerRow + startX * bytesPerPixel)
                    memcpy(destination, firstRow, rowBytes)
                }
            }
        }
    }

    // MARK: - Read operations

    /// Create a CGImage snapshot of the current framebuffer. Thread-safe.
    ///
    /// 显式拷贝，不用 `CGContext.makeImage()`：后者走写时复制，下一次写要逐页缺页，
    /// 而这块内存同时映射给了 GPU，不能让页表被这样换来换去。
    public func createImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        storage.beginAccess(readOnly: true)
        defer { storage.endAccess(readOnly: true) }
        let byteCount = bytesPerRow * height
        guard let copy = malloc(byteCount) else { return nil }
        memcpy(copy, pixelData, byteCount)
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: copy,
            size: byteCount,
            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) })
        else {
            free(copy)
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent)
    }

    /// 呈现层取当前内存。持有返回值期间这块内存不会被释放，resize 只会换新的。
    public func presentationStorage() -> FramebufferPresentationStorage {
        lock.lock()
        defer { lock.unlock() }
        return FramebufferPresentationStorage(
            storage: storage,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel)
    }

    /// Get the raw pixel data for a region (for testing). Thread-safe.
    public func getPixels(x: Int, y: Int, width w: Int, height h: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        storage.beginAccess(readOnly: true)
        defer { storage.endAccess(readOnly: true) }

        let rowBytes = w * bytesPerPixel
        var result = Data(capacity: rowBytes * h)

        for row in 0 ..< h {
            let srcY = y + row
            guard srcY >= 0, srcY < self.height else {
                // Out of bounds row: write zeros
                result.append(contentsOf: [UInt8](repeating: 0, count: rowBytes))
                continue
            }

            let srcOffset = srcY * bytesPerRow + x * bytesPerPixel
            let copyBytes = min(rowBytes, (self.width - x) * bytesPerPixel)

            if copyBytes > 0 {
                let rowData = Data(
                    bytes: pixelData.advanced(by: srcOffset),
                    count: copyBytes
                )
                result.append(rowData)
                if copyBytes < rowBytes {
                    result.append(contentsOf: [UInt8](repeating: 0, count: rowBytes - copyBytes))
                }
            } else {
                result.append(contentsOf: [UInt8](repeating: 0, count: rowBytes))
            }
        }

        return result
    }

    // MARK: - Resize

    /// Resize the framebuffer (e.g., when server sends DesktopSize pseudo-encoding).
    public func resize(width newWidth: Int, height newHeight: Int) {
        precondition(newWidth > 0 && newHeight > 0, "Framebuffer dimensions must be positive")

        lock.lock()
        defer { lock.unlock() }

        guard newWidth != width || newHeight != height else { return }

        writeGenerationStorage &+= 1
        let newStorage = FramebufferStorage(
            width: newWidth, height: newHeight, bytesPerPixel: bytesPerPixel)
        let newBytesPerRow = newStorage.bytesPerRow
        storage.beginAccess(readOnly: true)
        newStorage.beginAccess(readOnly: false)

        // Copy existing pixel data that fits within the new dimensions
        let copyWidth = min(width, newWidth)
        let copyHeight = min(height, newHeight)
        let copyRowBytes = copyWidth * bytesPerPixel

        for row in 0 ..< copyHeight {
            let srcOffset = row * bytesPerRow
            let dstOffset = row * newBytesPerRow
            memcpy(
                newStorage.base.advanced(by: dstOffset),
                pixelData.advanced(by: srcOffset),
                copyRowBytes
            )
        }

        newStorage.endAccess(readOnly: false)
        storage.endAccess(readOnly: true)

        // 旧内存交给引用计数：GPU 还在读时由纹理继续持有。
        storage = newStorage
        pixelData = newStorage.base
        width = newWidth
        height = newHeight
        bytesPerRow = newBytesPerRow
    }
}
