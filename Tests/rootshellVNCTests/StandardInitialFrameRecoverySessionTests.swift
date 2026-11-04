import CoreGraphics
import Foundation
import RFBProtocol
import RFBTransport
import XCTest
@testable import rootshellVNC

/// 首帧底图恢复的会话级用例：真实 `VNCSession` + 传输层，服务端由脚本扮演。
/// 复现实测的卡死形态：type 2 量化表之后，服务端只推一半画面的变化区域，整屏底图一直不来。
@MainActor
final class StandardInitialFrameRecoverySessionTests: XCTestCase {
    private static let width = RecoveryFrameSize.width
    private static let height = RecoveryFrameSize.height

    override func tearDown() {
        VNCLogRelay.install(sink: nil)
        super.tearDown()
    }

    func testRenewsReferenceFrameThenShowsPartialFrameThenFinishesWhenCovered() async throws {
        let logs = RelayedLogs()
        VNCLogRelay.install(minimumLevel: .info) { _, _, message in
            logs.append(message)
        }
        let connection = RecoveryScriptedConnection()
        let session = try await connect(connection)
        defer { session.disconnect() }

        await connection.enqueueServerBytes(Self.framebufferUpdate([Self.dctQuantizationRect()]))
        // 订阅激活时那一条整帧请求（握手阶段也可能发过），之后的才算补发。
        try await Task.sleep(for: .milliseconds(500))
        let baseline = await connection.fullFrameRequestCount()
        XCTAssertGreaterThanOrEqual(baseline, 1)

        // 只推左半屏，持续变化。
        let feeder = Task {
            while !Task.isCancelled {
                await connection.enqueueServerBytes(
                    Self.framebufferUpdate([Self.rawRect(x: 0, width: 8)]))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { feeder.cancel() }

        try await waitUntil(seconds: 6, "整屏底图不来时应补发整帧请求") {
            await connection.fullFrameRequestCount() > baseline
        }
        XCTAssertNil(session.currentImage, "盖满之前、放行时限之前不应呈现")

        try await waitUntil(seconds: 15, "等满时限后应先显示已收到的部分") {
            session.currentImage != nil
        }
        XCTAssertTrue(logs.contains("InitialFrame partial uncovered=50.0%"))

        feeder.cancel()
        await connection.enqueueServerBytes(
            Self.framebufferUpdate([Self.rawRect(x: 8, width: 8)]))
        try await waitUntil(seconds: 3, "盖满后应记一条收尾日志") {
            logs.contains("InitialFrame covered via=coverage")
        }
        XCTAssertTrue(logs.contains("InitialFrame waiting size=16x8"))
        XCTAssertTrue(logs.contains("InitialFrame renew n=1 uncovered=50.0%"))
    }

    func testCompleteBaseFrameDoesNotRenew() async throws {
        let logs = RelayedLogs()
        VNCLogRelay.install(minimumLevel: .info) { _, _, message in
            logs.append(message)
        }
        let connection = RecoveryScriptedConnection()
        let session = try await connect(connection)
        defer { session.disconnect() }

        await connection.enqueueServerBytes(Self.framebufferUpdate([Self.dctQuantizationRect()]))
        try await Task.sleep(for: .milliseconds(500))
        let baseline = await connection.fullFrameRequestCount()
        await connection.enqueueServerBytes(Self.framebufferUpdate([
            Self.rawRect(x: 0, width: 8), Self.rawRect(x: 8, width: 8),
        ]))
        try await waitUntil(seconds: 3, "整屏底图到了应立即呈现") {
            session.currentImage != nil
        }
        // 跨过第一次补发的时间点，确认没有多发。
        try await Task.sleep(for: .seconds(3))
        let requests = await connection.fullFrameRequestCount()
        XCTAssertEqual(requests, baseline)
        XCTAssertTrue(logs.contains("InitialFrame covered via=coverage"))
        XCTAssertFalse(logs.contains("InitialFrame renew"))
    }

    // MARK: - 工具

    private func connect(_ connection: RecoveryScriptedConnection) async throws -> VNCSession {
        var script = Data("RFB 003.889\n".utf8)
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(Self.serverInit(name: "recovery"))
        await connection.enqueueServerBytes(script)

        var configuration = VNCConfiguration(
            enableHighPerformanceMode: false,
            videoQualityMode: .standard,
            displaySizingMode: .remoteDisplay,
            enableRemoteAudio: false,
            promptForLoginPasswordAtLoginWindow: false,
            reconnectionPolicy: VNCReconnectionPolicy(isEnabled: false))
        configuration.transportProvider = { _, _ in connection }
        let session = VNCSession(configuration: configuration)
        try await session.connect(credentials: VNCCredentials(
            host: "recovery.test", port: 5900, password: ""))
        try await waitUntil(seconds: 3, "应完成握手") { session.connectionState.isConnected }
        return session
    }

    private func waitUntil(
        seconds: Double,
        _ message: String,
        _ condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, message)
        if !satisfied { throw WaitTimeout(message: message) }
    }

    private struct WaitTimeout: Error {
        let message: String
    }

    private static func serverInit(name: String) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8(width >> 8), UInt8(width & 0xff)])
        data.append(contentsOf: [UInt8(height >> 8), UInt8(height & 0xff)])
        data.append(PixelFormat.bgra8888.wireBytes())
        let nameBytes = Data(name.utf8)
        data.append(contentsOf: bigEndian(UInt32(nameBytes.count)))
        data.append(nameBytes)
        return data
    }

    /// 0×0 的 type 2 记录：4 字节长度 + 类型 + 64 项亮度表 + 64 项色度表。
    private static func dctQuantizationRect() -> Data {
        var data = rectHeader(x: 0, width: 0, height: 0, encoding: 1011)
        data.append(contentsOf: bigEndian(UInt32(129)))
        data.append(2)
        data.append(Data(repeating: 1, count: 128))
        return data
    }

    private static func rawRect(x: UInt16, width: UInt16) -> Data {
        var data = rectHeader(x: x, width: width, height: height, encoding: 0)
        data.append(Data(repeating: 0x7f, count: Int(width) * Int(height) * 4))
        return data
    }

    private static func rectHeader(x: UInt16, width: UInt16, height: UInt16, encoding: Int32) -> Data {
        var data = Data()
        for value in [x, 0, width, height] {
            data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
        }
        data.append(contentsOf: bigEndian(UInt32(bitPattern: encoding)))
        return data
    }

    private static func framebufferUpdate(_ rects: [Data]) -> Data {
        var data = Data([0, 0, UInt8(rects.count >> 8), UInt8(rects.count & 0xff)])
        for rect in rects { data.append(rect) }
        return data
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
}

/// 中继日志收集器。中继在任意线程回调。
private final class RelayedLogs: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func contains(_ prefix: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return messages.contains { $0.hasPrefix(prefix) }
    }
}

/// 脚本化服务端：按需追加服务端字节，记录客户端发出的字节。
private actor RecoveryScriptedConnection: RFBConnection {
    private var serverBytes = Data()
    private var readOffset = 0
    private var closed = false
    private var sent = Data()
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    /// 整屏非增量 FramebufferUpdateRequest（type 3）。
    private static let fullFrameRequest = ClientMessage.framebufferUpdateRequest(
        incremental: false,
        x: 0, y: 0,
        width: RecoveryFrameSize.width,
        height: RecoveryFrameSize.height).serialize()

    func enqueueServerBytes(_ data: Data) {
        serverBytes.append(data)
        let waiters = readWaiters
        readWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func fullFrameRequestCount() -> Int {
        var count = 0
        var searchStart = sent.startIndex
        while let range = sent.range(of: Self.fullFrameRequest, in: searchStart..<sent.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    func connect() async throws {
        if closed { throw VNCProtocolError.connectionClosed }
    }

    func read(exactly count: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            if serverBytes.count - readOffset >= count {
                return consume(count)
            }
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }

    func read(upTo maxCount: Int) async throws -> Data {
        while true {
            if closed { throw VNCProtocolError.connectionClosed }
            let available = serverBytes.count - readOffset
            if available > 0 { return consume(min(available, maxCount)) }
            await withCheckedContinuation { readWaiters.append($0) }
        }
    }

    func send(_ data: Data) async throws {
        if closed { throw VNCProtocolError.connectionClosed }
        sent.append(data)
    }

    func close() async {
        closed = true
        let waiters = readWaiters
        readWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func setDisconnectHandler(
        _ handler: (@Sendable (VNCProtocolError) -> Void)?
    ) async {}

    private func consume(_ count: Int) -> Data {
        let start = serverBytes.startIndex + readOffset
        let result = serverBytes.subdata(in: start..<(start + count))
        readOffset += count
        return result
    }
}

private enum RecoveryFrameSize {
    static let width: UInt16 = 16
    static let height: UInt16 = 8
}
