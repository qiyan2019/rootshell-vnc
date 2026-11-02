import Foundation
import RFBProtocol

/// 定稿文字的 Apple 剪贴板粘贴：packed scrap + Cmd+V + 原 scrap 回发。
///
/// 能力位 31 的判断在调用方。这里只组字节，并在还没有服务端 scrap 时排队等一次
/// type-11。回发用收到的原始字节，不重新打包。
enum AppleTextPaste {
    /// 左 Command（X11 Super_L）。与 `KeyboardInputHandler.keysymSuperL` 相同。
    static let commandKeysym: UInt32 = 0xFFEB
    /// Latin-1 `v`。
    static let pasteKeysym: UInt32 = 0x76

    static func commandVKeys() -> Data {
        var data = Data()
        data.append(MessageWriter.writeKeyEvent(downFlag: true, key: commandKeysym))
        data.append(MessageWriter.writeKeyEvent(downFlag: true, key: pasteKeysym))
        data.append(MessageWriter.writeKeyEvent(downFlag: false, key: pasteKeysym))
        data.append(MessageWriter.writeKeyEvent(downFlag: false, key: commandKeysym))
        return data
    }

    /// `savedScrap` 非空时整段追加在 Cmd+V 之后，字节与入参一致。
    static func payload(text: String, savedScrap: Data?) throws -> Data {
        var data = try AppleClipboardProtocol.packedTextMessage(text)
        data.append(commandVKeys())
        if let savedScrap {
            data.append(savedScrap)
        }
        return data
    }
}

/// 粘贴排队。有快照就立即发出；没有就发一次 type-11，等到 scrap 再回发原始字节。
/// 队列超过 32 段则直接粘贴、跳过恢复。
struct AppleTextPasteState: Sendable {
    static let maxPending = 32

    enum Step: Equatable, Sendable {
        case requestSnapshot
        case send(Data)
    }

    private(set) var savedScrap: Data?
    private var requestPending = false
    private var queue: [String] = []

    /// `useCachedScrap` 对应「剪贴板同步」开着：才能直接用上一条 type-31。
    /// 同步关着时即使手里有旧快照也重新要一次，避免用过期内容盖掉用户刚复制的剪贴板。
    mutating func submit(_ text: String, useCachedScrap: Bool = true) throws -> [Step] {
        guard !text.isEmpty else { return [] }
        if useCachedScrap, let saved = savedScrap {
            var steps: [Step] = []
            if !queue.isEmpty {
                let merged = queue.joined()
                queue.removeAll()
                requestPending = false
                steps.append(.send(try AppleTextPaste.payload(
                    text: merged, savedScrap: saved)))
            }
            steps.append(.send(try AppleTextPaste.payload(
                text: text, savedScrap: saved)))
            return steps
        }

        queue.append(text)
        var steps: [Step] = []
        if !requestPending {
            requestPending = true
            steps.append(.requestSnapshot)
        }
        if queue.count > Self.maxPending {
            let merged = queue.joined()
            queue.removeAll()
            requestPending = false
            steps.append(.send(try AppleTextPaste.payload(
                text: merged, savedScrap: nil)))
        }
        return steps
    }

    /// 记下服务端 scrap 的原始字节。队列里的定稿文字用这段字节回发。
    mutating func receive(_ scrap: Data) -> [Step] {
        savedScrap = scrap
        requestPending = false
        guard !queue.isEmpty else { return [] }
        let merged = queue.joined()
        queue.removeAll()
        guard let payload = try? AppleTextPaste.payload(
            text: merged, savedScrap: scrap) else {
            return []
        }
        return [.send(payload)]
    }
}
