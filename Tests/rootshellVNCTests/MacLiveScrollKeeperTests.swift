import CoreGraphics
import Foundation
import XCTest

/// 守连接和第二个观看者。不设对应环境变量时跳过，不投递密码。
@MainActor
final class MacLiveScrollKeeperTests: XCTestCase {
    func testMacLiveScrollKeeper() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AGITO_SCROLL_KEEPER"] == "1" else {
            throw XCTSkip("未设置 AGITO_SCROLL_KEEPER")
        }
        let runner = try makeRunner(env)
        try await runner.keep()
    }

    func testMacLiveScrollWatcher() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AGITO_SCROLL_WATCHER"] == "1" else {
            throw XCTSkip("未设置 AGITO_SCROLL_WATCHER")
        }
        let runner = try makeRunner(env)
        try await runner.watch()
    }

    private func makeRunner(_ env: [String: String]) throws -> MacLiveScrollCalibration {
        guard let passwordFile = env["AGITO_SCROLL_PASSWORD_FILE"], !passwordFile.isEmpty else {
            throw XCTSkip("未设置 AGITO_SCROLL_PASSWORD_FILE")
        }
        let timeline = NSTemporaryDirectory() + "agito-keeper-unused.jsonl"
        return MacLiveScrollCalibration(passwordFile: passwordFile, timelinePath: timeline)
    }
}

/// 12×8 量化亮度，和 App `ScreenSharingFrameSignature` 同一条规则。只在内存里比较。
struct FrameSignature: Equatable {
    static let columns = 12
    static let rows = 8
    let cells: [UInt8]

    init?(image: CGImage) {
        var pixels = [UInt8](repeating: 0, count: Self.columns * Self.rows * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: Self.columns,
                height: Self.rows,
                bitsPerComponent: 8,
                bytesPerRow: Self.columns * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.columns, height: Self.rows))
            return true
        }
        guard drawn else { return nil }
        cells = stride(from: 0, to: pixels.count, by: 4).map { offset in
            let blue = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let red = Int(pixels[offset + 2])
            return UInt8(((red * 77 + green * 150 + blue * 29) >> 8) >> 4)
        }
    }

    func isMajorChange(from other: FrameSignature) -> Bool {
        let count = min(cells.count, other.cells.count)
        guard count > 0 else { return false }
        let changed = (0..<count).filter { abs(Int(cells[$0]) - Int(other.cells[$0])) > 2 }.count
        return Double(changed) / Double(count) > 0.25
    }
}
