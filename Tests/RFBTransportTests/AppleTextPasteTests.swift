import XCTest
import RFBProtocol
@testable import RFBTransport

final class AppleTextPasteTests: XCTestCase {
    func testPackedPayloadBytesThenCommandV() throws {
        let payload = try AppleTextPaste.payload(text: "中", savedScrap: nil)
        let packed = try AppleClipboardProtocol.packedTextMessage("中")
        let keys = AppleTextPaste.commandVKeys()

        XCTAssertEqual(payload, packed + keys)
        XCTAssertEqual(payload.prefix(packed.count), packed)
        XCTAssertEqual(
            AppleClipboardProtocol.packedScrapMessageType,
            AppleServerCapabilities.packedScrapCommand)
    }

    func testRestoreAppendsOriginalBytesVerbatim() throws {
        // 故意不是「中」的打包结果，用来证明回发的是入参原字节，不是重新压缩。
        let original = Data([
            0x1F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
            0x09, 0x08, 0x07, 0x06,
        ])
        let payload = try AppleTextPaste.payload(text: "中", savedScrap: original)
        let packed = try AppleClipboardProtocol.packedTextMessage("中")
        let keys = AppleTextPaste.commandVKeys()

        XCTAssertEqual(payload, packed + keys + original)
        XCTAssertEqual(Data(payload.suffix(original.count)), original)
        XCTAssertEqual(
            Data(payload.dropFirst(packed.count).prefix(keys.count)),
            keys)
    }

    func testCommandVIsSuperThenV() {
        let keys = AppleTextPaste.commandVKeys()
        XCTAssertEqual(keys, Data([
            4, 1, 0, 0, 0, 0, 0xFF, 0xEB,
            4, 1, 0, 0, 0, 0, 0x00, 0x76,
            4, 0, 0, 0, 0, 0, 0x00, 0x76,
            4, 0, 0, 0, 0, 0, 0xFF, 0xEB,
        ]))
    }

    func testQueueRequestsSnapshotOnceThenRestoresOriginal() throws {
        var state = AppleTextPasteState()
        XCTAssertEqual(try state.submit("hi"), [.requestSnapshot])
        XCTAssertEqual(try state.submit("yo"), [])

        let original = Data([0xAB, 0xCD, 0xEF, 0x01])
        let steps = state.receive(original)
        guard case .send(let data) = steps.first else {
            return XCTFail("快照到达后应发出粘贴")
        }
        let packed = try AppleClipboardProtocol.packedTextMessage("hiyo")
        XCTAssertTrue(data.starts(with: packed))
        XCTAssertEqual(Data(data.suffix(original.count)), original)
        XCTAssertEqual(steps.count, 1)

        let again = try state.submit("z")
        guard case .send(let next) = again.first else {
            return XCTFail("已有 scrap 时应直接粘贴")
        }
        XCTAssertEqual(Data(next.suffix(original.count)), original)
        XCTAssertFalse(again.contains(.requestSnapshot))
    }

    func testReplacingPayloadOmitsTheSavedScrap() throws {
        let saved = Data([0xAB, 0xCD, 0xEF, 0x01])
        let replacing = try AppleTextPaste.payload(text: "hi", savedScrap: nil)
        let restoring = try AppleTextPaste.payload(text: "hi", savedScrap: saved)
        let packed = try AppleClipboardProtocol.packedTextMessage("hi")
        let keys = AppleTextPaste.commandVKeys()
        XCTAssertEqual(replacing, packed + keys)
        XCTAssertEqual(restoring, packed + keys + saved)
        XCTAssertFalse(replacing.elementsEqual(restoring))
    }

    func testDevicePasteSendsQueuedTextFirstAndDropsTheSnapshot() throws {
        var state = AppleTextPasteState()
        XCTAssertEqual(try state.submit("hi"), [.requestSnapshot])
        XCTAssertEqual(try state.submit("yo"), [])

        let steps = try state.pasteReplacing("clip")
        guard case .send(let data) = steps.first else {
            return XCTFail("排队文字应和粘贴键并成一次发送")
        }
        let packed = try AppleClipboardProtocol.packedTextMessage("hiyoclip")
        XCTAssertEqual(steps, [.send(packed + AppleTextPaste.commandVKeys())])
        XCTAssertEqual(data, packed + AppleTextPaste.commandVKeys())

        let late = Data([0xAB, 0xCD, 0xEF, 0x01])
        XCTAssertEqual(state.receive(late), [])
        XCTAssertNil(state.savedScrap)
        XCTAssertEqual(try state.submit("z"), [.requestSnapshot])
    }

    func testDevicePasteDropsCachedScrap() throws {
        var state = AppleTextPasteState()
        XCTAssertEqual(try state.submit("hi"), [.requestSnapshot])
        let original = Data([0x11, 0x22, 0x33, 0x44])
        _ = state.receive(original)
        XCTAssertEqual(state.savedScrap, original)

        let steps = try state.pasteReplacing("clip")
        let packed = try AppleClipboardProtocol.packedTextMessage("clip")
        XCTAssertEqual(steps, [.send(packed + AppleTextPaste.commandVKeys())])
        XCTAssertNil(state.savedScrap)
        XCTAssertEqual(try state.submit("z"), [.requestSnapshot])
    }

    func testDevicePasteWhileARequestIsOutstandingDropsThePreviousScrap() throws {
        var state = AppleTextPasteState()
        XCTAssertEqual(try state.submit("hi"), [.requestSnapshot])
        let original = Data([0x11, 0x22])
        _ = state.receive(original)
        XCTAssertEqual(try state.submit("yo", useCachedScrap: false), [.requestSnapshot])

        let steps = try state.pasteReplacing("clip")
        let packed = try AppleClipboardProtocol.packedTextMessage("yoclip")
        XCTAssertEqual(steps, [.send(packed + AppleTextPaste.commandVKeys())])
        XCTAssertEqual(state.receive(Data([0x55, 0x66])), [])
        XCTAssertNil(state.savedScrap)
        XCTAssertEqual(try state.submit("z"), [.requestSnapshot])
    }

    func testSyncOffRequestsAgainEvenWhenScrapIsSaved() throws {
        var state = AppleTextPasteState()
        XCTAssertEqual(try state.submit("hi", useCachedScrap: false), [.requestSnapshot])
        let original = Data([0xAB, 0xCD])
        _ = state.receive(original)

        let again = try state.submit("yo", useCachedScrap: false)
        XCTAssertEqual(again, [.requestSnapshot])
        XCTAssertEqual(state.savedScrap, original)
    }

    func testQueueOverflowPastesWithoutRestore() throws {
        var state = AppleTextPasteState()
        for index in 0..<AppleTextPasteState.maxPending {
            let steps = try state.submit("\(index),")
            if index == 0 {
                XCTAssertEqual(steps, [.requestSnapshot])
            } else {
                XCTAssertEqual(steps, [])
            }
        }
        let steps = try state.submit("tail")
        guard case .send(let data) = steps.last else {
            return XCTFail("超过 32 段应直接粘贴")
        }
        let text = (0..<AppleTextPasteState.maxPending)
            .map { "\($0)," }
            .joined() + "tail"
        let packed = try AppleClipboardProtocol.packedTextMessage(text)
        let keys = AppleTextPaste.commandVKeys()
        XCTAssertEqual(data, packed + keys)
        XCTAssertFalse(steps.contains(.requestSnapshot))

        let late = Data([0x11, 0x22])
        XCTAssertEqual(state.receive(late), [])
        XCTAssertEqual(state.savedScrap, late)
    }

    func testPackedTextRoundTripsEmoji() throws {
        let message = try AppleClipboardProtocol.packedTextMessage("🙂")
        let start = message.startIndex
        let uncompressed = try XCTUnwrap(
            AppleClipboardProtocol.uint32BE(message, at: start + 8))
        let compressedLength = try XCTUnwrap(
            AppleClipboardProtocol.uint32BE(message, at: start + 12))
        let compressed = Data(message.dropFirst(
            AppleClipboardProtocol.packedScrapHeaderSize))
        XCTAssertEqual(compressed.count, Int(compressedLength))
        let text = try AppleClipboardProtocol.unpackText(
            compressed: compressed,
            uncompressedSize: Int(uncompressed))
        XCTAssertEqual(text, "🙂")
    }

    func testFlushSkippingRestoreDropsTheLateSnapshot() throws {
        var state = AppleTextPasteState()
        XCTAssertEqual(
            try state.submit("hi", useCachedScrap: false),
            [.requestSnapshot])
        XCTAssertTrue(state.hasPendingText)

        let steps = try state.flushSkippingRestore()
        let packed = try AppleClipboardProtocol.packedTextMessage("hi")
        XCTAssertEqual(steps, [.send(packed + AppleTextPaste.commandVKeys())])
        XCTAssertFalse(state.hasPendingText)

        let late = try AppleClipboardProtocol.packedTextMessage("old")
        XCTAssertEqual(state.receive(late), [])
        XCTAssertNil(state.savedScrap)
        XCTAssertEqual(
            try state.submit("z", useCachedScrap: false),
            [.requestSnapshot])
    }

    func testCapabilityBit31MatchesPackedScrapCommand() {
        var bitmap = Data(repeating: 0, count: 16)
        bitmap[3] = 0x01
        var field = Data([0, 0, 0, 0, 0, 0])
        field.append(bitmap)
        let capabilities = AppleServerCapabilities(serverInitNameField: field)
        XCTAssertEqual(
            capabilities?.supportsServerCommand(AppleServerCapabilities.packedScrapCommand),
            true)
        XCTAssertFalse(TransportSession.shouldUseApplePackedClipboard(capabilities: nil))

        var empty = Data([0, 0, 0, 0, 0, 0])
        empty.append(Data(repeating: 0, count: 16))
        let without = AppleServerCapabilities(serverInitNameField: empty)
        XCTAssertFalse(TransportSession.shouldUseApplePackedClipboard(capabilities: without))
        XCTAssertTrue(TransportSession.shouldUseApplePackedClipboard(capabilities: capabilities))
    }

    func testCommittedPasteHitsTheWireBeforeTheFollowingKey() async throws {
        let harness = try await connectApplePackedScrap()
        let baseline = await harness.connection.sentBytes().count
        let saved = try AppleClipboardProtocol.packedTextMessage("old")
        let paste = Task { try await harness.session.pasteCommittedText("hi") }
        let request = AppleClipboardProtocol.requestMessage(requestID: 1)
        let sawRequest = await waitUntil {
            let sent = await harness.connection.sentBytes()
            return sent.dropFirst(baseline).range(of: request) != nil
        }
        XCTAssertTrue(sawRequest)

        await harness.connection.enqueueServerBytes(saved)
        let pasted = try await paste.value
        XCTAssertTrue(pasted)
        let key = ClientMessage.keyEvent(downFlag: true, key: 0xFF0D).serialize()
        try await harness.session.sendKeyEvent(downFlag: true, key: 0xFF0D)

        let body = Data((await harness.connection.sentBytes()).dropFirst(baseline))
        let payload = try AppleTextPaste.payload(text: "hi", savedScrap: saved)
        let requestAt = try XCTUnwrap(body.range(of: request))
        let payloadAt = try XCTUnwrap(body.range(of: payload))
        let keyAt = try XCTUnwrap(body.range(of: key))
        XCTAssertEqual(requestAt.upperBound, payloadAt.lowerBound)
        XCTAssertEqual(payloadAt.upperBound, keyAt.lowerBound)
        await harness.session.disconnect()
    }

    func testPasteSnapshotTimeoutSkipsRestoreAndIgnoresTheLateReply() async throws {
        let harness = try await connectApplePackedScrap()
        let baseline = await harness.connection.sentBytes().count
        let pasted = try await harness.session.pasteCommittedText("hi")
        XCTAssertTrue(pasted)
        let key = ClientMessage.keyEvent(downFlag: true, key: 0xFF0D).serialize()
        try await harness.session.sendKeyEvent(downFlag: true, key: 0xFF0D)

        let body = Data((await harness.connection.sentBytes()).dropFirst(baseline))
        let request = AppleClipboardProtocol.requestMessage(requestID: 1)
        let payload = try AppleTextPaste.payload(text: "hi", savedScrap: nil)
        let requestAt = try XCTUnwrap(body.range(of: request))
        let payloadAt = try XCTUnwrap(body.range(of: payload))
        let keyAt = try XCTUnwrap(body.range(of: key))
        XCTAssertEqual(requestAt.upperBound, payloadAt.lowerBound)
        XCTAssertEqual(payloadAt.upperBound, keyAt.lowerBound)

        let frozen = await harness.connection.sentBytes()
        let late = try AppleClipboardProtocol.packedTextMessage("old")
        let clipboard = Task { () -> Bool in
            for await event in harness.session.events {
                if case .clipboardText = event { return true }
            }
            return false
        }
        await harness.connection.enqueueServerBytes(late)
        let sawClipboard = await withTimeout(seconds: 2) { await clipboard.value }
        let afterLateReply = await harness.connection.sentBytes()
        XCTAssertEqual(sawClipboard, true)
        XCTAssertEqual(afterLateReply, frozen)
        await harness.session.disconnect()
    }

    func testDisconnectWhileWaitingForPasteDoesNotHang() async throws {
        let harness = try await connectApplePackedScrap()
        let baseline = await harness.connection.sentBytes().count
        let paste = Task { () -> Bool in
            do {
                return try await harness.session.pasteCommittedText("hi")
            } catch {
                return false
            }
        }
        let request = AppleClipboardProtocol.requestMessage(requestID: 1)
        let sawRequest = await waitUntil {
            let sent = await harness.connection.sentBytes()
            return sent.dropFirst(baseline).range(of: request) != nil
        }
        XCTAssertTrue(sawRequest)
        await harness.session.disconnect()
        let finished = await withTimeout(seconds: 2) { await paste.value }
        XCTAssertNotNil(finished)
    }

    private func connectApplePackedScrap() async throws -> (
        session: TransportSession,
        connection: ScriptedRFBConnection
    ) {
        let connection = ScriptedRFBConnection()
        var script = ProtocolVersion.apple.wireBytes()
        script.append(contentsOf: [1, SecurityType.none.rawValue])
        script.append(contentsOf: [0, 0, 0, 0])
        script.append(applePackedScrapServerInit())
        await connection.enqueueServerBytes(script)
        let session = TransportSession(
            host: "paste.test",
            port: 5900,
            password: "",
            preferredEncodings: [.raw],
            connection: connection)
        try await session.connect()
        return (session, connection)
    }

    private func applePackedScrapServerInit() -> Data {
        var bitmap = Data(repeating: 0, count: 16)
        bitmap[3] = 0x01
        var field = Data([
            0x00, 0x00,
            0x00, 0x00, 0x00, 0x54,
        ])
        field.append(bitmap)
        field.append(Data("paste".utf8))

        var data = Data()
        data.append(contentsOf: [0x04, 0x00]) // 1024
        data.append(contentsOf: [0x03, 0x00]) // 768
        data.append(PixelFormat.bgra8888.wireBytes())
        let length = UInt32(field.count)
        data.append(contentsOf: [
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        data.append(field)
        return data
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func withTimeout<Result: Sendable>(
        seconds: Int,
        _ operation: @escaping @Sendable () async -> Result
    ) async -> Result? {
        await withTaskGroup(of: Result?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
