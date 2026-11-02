import Foundation

/// 只看时每种手势该怎么处理。对齐 Android：单指和双指滑动平移视口，捏合仍缩放，点击和长按丢弃。
enum RemoteViewOnlyGesture: Equatable, Sendable {
    case singleFingerMove
    case twoFingerMove
    case tap
    case longPress
    case pinch
}

enum RemoteViewOnlyGestureEffect: Equatable, Sendable {
    case panViewport
    case zoom
    case drop
    case deliverToRemote
}

enum RemoteViewOnlyGestures {
    static func effect(
        of gesture: RemoteViewOnlyGesture,
        viewOnly: Bool
    ) -> RemoteViewOnlyGestureEffect {
        guard viewOnly else { return .deliverToRemote }
        switch gesture {
        case .singleFingerMove, .twoFingerMove:
            return .panViewport
        case .pinch:
            return .zoom
        case .tap, .longPress:
            return .drop
        }
    }
}

/// 已经发给远端、还没抬起的键和鼠标键。切到只看之前用它生成释放事件。
struct ViewOnlyHeldInput: Equatable, Sendable {
    private(set) var keysymsDown: [UInt32] = []
    private(set) var pointerButtons: UInt8 = 0
    private(set) var pointerX: UInt16 = 0
    private(set) var pointerY: UInt16 = 0

    /// 滚轮脉冲不算按住。只记左/中/右键。
    static let pointerButtonBits: UInt8 = 0x07

    mutating func noteKey(down: Bool, keysym: UInt32) {
        if down {
            if !keysymsDown.contains(keysym) {
                keysymsDown.append(keysym)
            }
        } else {
            keysymsDown.removeAll { $0 == keysym }
        }
    }

    mutating func notePointer(buttonMask: UInt8, x: UInt16, y: UInt16) {
        pointerX = x
        pointerY = y
        pointerButtons = buttonMask & Self.pointerButtonBits
    }

    /// 先抬后按下的键，再松开鼠标键。没有按住的东西时为空。
    func releaseEvents() -> [SessionInputEvent] {
        var events: [SessionInputEvent] = []
        for keysym in keysymsDown.reversed() {
            events.append(.key(downFlag: false, keysym: keysym))
        }
        if pointerButtons != 0 {
            events.append(.pointer(buttonMask: 0, x: pointerX, y: pointerY))
        }
        return events
    }
}
