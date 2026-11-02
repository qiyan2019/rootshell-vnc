import Foundation
import RFBProtocol

/// 能力位 31 不足时，粘贴入口退回的逐字发键。键序与软键盘 `insertText` 相同。
enum VNCTextPaste {
    static func usesPackedScrap(_ capabilities: AppleServerCapabilities?) -> Bool {
        capabilities?.supportsServerCommand(
            AppleServerCapabilities.packedScrapCommand) == true
    }

    static func keyEvents(for text: String) -> [(downFlag: Bool, keysym: UInt32)] {
        var events: [(downFlag: Bool, keysym: UInt32)] = []
        events.reserveCapacity(text.count * 2)
        for character in text {
            let keysym = KeyboardInputHandler.keysymForCharacter(character)
            guard keysym != 0 else { continue }
            events.append((true, keysym))
            events.append((false, keysym))
        }
        return events
    }
}
