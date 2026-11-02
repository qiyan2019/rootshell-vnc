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
}
