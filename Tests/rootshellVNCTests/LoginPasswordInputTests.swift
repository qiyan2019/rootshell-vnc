import XCTest
@testable import rootshellVNC

final class LoginPasswordInputTests: XCTestCase {
    func testSequenceClearsModifiersAndPacesKeyTaps() {
        let events = VNCSession.loginPasswordInputEvents(password: "Aé")

        XCTAssertEqual(Array(events.prefix(9)), [
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymCapsLock),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymShiftL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymSuperL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymAltL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymControlL),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymControlR),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymSuperR),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymAltR),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymShiftR),
        ])
        XCTAssertEqual(Array(events.dropFirst(9)), [
            .key(downFlag: true, keysym: 0x41),
            .key(downFlag: false, keysym: 0x41),
            .pause(nanoseconds: 5_000_000),
            .key(downFlag: true, keysym: 0xE9),
            .key(downFlag: false, keysym: 0xE9),
            .pause(nanoseconds: 5_000_000),
            .key(downFlag: true, keysym: KeyboardInputHandler.keysymReturn),
            .key(downFlag: false, keysym: KeyboardInputHandler.keysymReturn),
            .pause(nanoseconds: 5_000_000),
        ])
    }

    func testPasswordLineCenterFlipsVisionYAndStaysNilWithoutCoords() {
        // 无坐标不再退化成帧中心：盲击会把默认持焦的安全字段点失焦。
        XCTAssertNil(VNCSession.loginPasswordClickPoint(
            passwordLineCenter: nil,
            framebufferWidth: 200,
            framebufferHeight: 100))
        let line = VNCSession.loginPasswordClickPoint(
            passwordLineCenter: CGPoint(x: 0.25, y: 0.2),
            framebufferWidth: 200,
            framebufferHeight: 100)
        XCTAssertEqual(line?.x, 50)
        XCTAssertEqual(line?.y, 80)
    }

    func testFieldClearEventsContainNoPointerWhenCoordsMissing() {
        let events = VNCSession.loginPasswordFieldClearInputEvents()
        XCTAssertFalse(events.contains { event in
            if case .pointer = event { return true }
            return false
        })
        // 仍保留 Cmd+A + Backspace 清残输入。
        XCTAssertTrue(events.contains { event in
            if case .key(true, 0x61) = event { return true }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .key(true, let k) = event,
               k == KeyboardInputHandler.keysymBackspace { return true }
            return false
        })
    }

    func testPasswordFocusClickClearsFieldBeforeTypingBarrier() {
        XCTAssertEqual(
            VNCSession.loginPasswordFocusInputEvents(x: 800, y: 600),
            [
                .pointer(buttonMask: 0, x: 800, y: 600),
                .pointer(buttonMask: 1, x: 800, y: 600),
                .pointer(buttonMask: 0, x: 800, y: 600),
                .pause(nanoseconds: 150_000_000),
                .key(downFlag: true, keysym: KeyboardInputHandler.keysymSuperL),
                .key(downFlag: true, keysym: 0x61),
                .key(downFlag: false, keysym: 0x61),
                .key(
                    downFlag: false,
                    keysym: KeyboardInputHandler.keysymSuperL),
                .key(
                    downFlag: true,
                    keysym: KeyboardInputHandler.keysymBackspace),
                .key(
                    downFlag: false,
                    keysym: KeyboardInputHandler.keysymBackspace),
                .pause(nanoseconds: 50_000_000),
            ])
    }

    func testStabilityGatePreservesSendAcrossDisplayChanges() {
        var gate = LoginPasswordSendStabilityGate()

        XCTAssertNil(gate.requestSend())
        gate.transportSettled(true)
        let retired = gate.noteEligibleFrame(mediaGeneration: 4)
        XCTAssertNotNil(retired)

        gate.displayTargetChanged()
        XCTAssertFalse(gate.consume(retired!))
        XCTAssertTrue(gate.isPending)

        gate.transportSettled(true)
        let replacement = gate.noteEligibleFrame(mediaGeneration: 5)
        XCTAssertNotNil(replacement)
        XCTAssertTrue(gate.consume(replacement!))
        XCTAssertFalse(gate.isPending)
    }

    func testStabilityGateCanUseAnAlreadyCommittedFrame() {
        var gate = LoginPasswordSendStabilityGate()

        gate.transportSettled(true)
        XCTAssertNil(gate.noteEligibleFrame(mediaGeneration: 7))
        let token = gate.requestSend()

        XCTAssertNotNil(token)
        XCTAssertTrue(gate.consume(token!))
    }

    func testStabilityGateRejectsRetiredMediaGeneration() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()
        gate.transportSettled(true)
        let retired = gate.noteEligibleFrame(mediaGeneration: 10)!
        let current = gate.noteEligibleFrame(mediaGeneration: 11)!

        XCTAssertFalse(gate.consume(retired))
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.consume(current))
    }

    func testStabilityGateRequiresFrameAfterTransportSettles() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()

        XCTAssertNil(gate.noteEligibleFrame(mediaGeneration: 20))
        gate.transportSettled(true)
        XCTAssertTrue(gate.isPending)
        XCTAssertNil(gate.stableCandidate)

        let finalFrame = gate.noteEligibleFrame(mediaGeneration: 21)
        XCTAssertNotNil(finalFrame)
        XCTAssertTrue(gate.consume(finalFrame!))
    }

    func testStabilityGateAdoptsFrameThatPrecededSettlement() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()

        // The static Login Window's only final-size frame commits before the
        // settled signal reaches the main actor; no further frame will come.
        XCTAssertNil(gate.noteEligibleFrame(mediaGeneration: 3))
        gate.transportSettled(true)
        XCTAssertNil(gate.stableCandidate)

        let adopted = gate.adoptRetainedFrame(liveMediaGeneration: 3)
        XCTAssertNotNil(adopted)
        XCTAssertTrue(gate.consume(adopted!))
        XCTAssertFalse(gate.isPending)
    }

    func testStabilityGateRefusesAdoptingRetiredGeneration() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()

        XCTAssertNil(gate.noteEligibleFrame(mediaGeneration: 3))
        gate.transportSettled(true)

        // A newer capture graph is live; the retained frame is stale.
        XCTAssertNil(gate.adoptRetainedFrame(liveMediaGeneration: 4))
        XCTAssertTrue(gate.isPending)
        XCTAssertNil(gate.stableCandidate)
    }

    func testStabilityGateDropsRetainedFrameOnDisplayTargetChange() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()

        XCTAssertNil(gate.noteEligibleFrame(mediaGeneration: 3))
        gate.displayTargetChanged()
        gate.transportSettled(true)

        XCTAssertNil(gate.adoptRetainedFrame(liveMediaGeneration: 3))
    }

    func testStabilityGateAdoptionYieldsToExistingCandidate() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()
        gate.transportSettled(true)

        let fresh = gate.noteEligibleFrame(mediaGeneration: 6)
        XCTAssertNotNil(fresh)
        XCTAssertNil(gate.adoptRetainedFrame(liveMediaGeneration: 6))
        XCTAssertTrue(gate.consume(fresh!))
    }

    func testForceConsumePendingDeliversExactlyOnce() {
        var gate = LoginPasswordSendStabilityGate()
        XCTAssertFalse(gate.forceConsumePending())

        _ = gate.requestSend()
        XCTAssertTrue(gate.forceConsumePending())
        XCTAssertFalse(gate.forceConsumePending())
        XCTAssertFalse(gate.isPending)
    }

    func testMediaGenerationChangeRetiresTokenAndRetainedFrame() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()
        gate.transportSettled(true)
        let token = gate.noteEligibleFrame(mediaGeneration: 5)!

        // Server capture restart: no settle edge, but everything staged from
        // the old generation is dead.
        gate.mediaGenerationChanged()

        XCTAssertFalse(gate.consume(token))
        XCTAssertTrue(gate.isPending)
        XCTAssertNil(gate.stableCandidate)
        XCTAssertNil(gate.adoptRetainedFrame(liveMediaGeneration: 5))

        // Only a frame from the replacement generation validates the send.
        let replacement = gate.noteEligibleFrame(mediaGeneration: 6)
        XCTAssertNotNil(replacement)
        XCTAssertTrue(gate.consume(replacement!))
    }

    func testResetCanPreservePendingSendAcrossReconnect() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()
        gate.transportSettled(true)
        _ = gate.noteEligibleFrame(mediaGeneration: 2)

        // An automatic reconnect tears down the transport but must not
        // discard the user's approval.
        gate.reset(preservePendingSend: true)
        XCTAssertTrue(gate.isPending)
        XCTAssertFalse(gate.isTransportSettled)
        XCTAssertNil(gate.stableCandidate)
        XCTAssertNil(gate.latestEligibleFrameGeneration)

        // The replacement connection stabilizes and delivers the queued send.
        gate.transportSettled(true)
        let token = gate.noteEligibleFrame(mediaGeneration: 1)
        XCTAssertNotNil(token)
        XCTAssertTrue(gate.consume(token!))
    }

    func testResetWithoutPreservationDropsPendingSend() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()

        gate.reset()
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.forceConsumePending())
    }

    func testSinkEventSequencerIsMonotonic() {
        let sequencer = SinkEventSequencer()
        let first = sequencer.next()
        let second = sequencer.next()
        XCTAssertGreaterThan(second, first)
    }

    func testTransportReconfigurationInvalidatesScheduledFrame() {
        var gate = LoginPasswordSendStabilityGate()
        _ = gate.requestSend()
        gate.transportSettled(true)
        let beforeQueuedResize = gate.noteEligibleFrame(mediaGeneration: 30)!

        gate.transportSettled(false)

        XCTAssertFalse(gate.consume(beforeQueuedResize))
        XCTAssertTrue(gate.isPending)
        XCTAssertNil(gate.stableCandidate)
    }

    /// 停下时不能留下按住的键或鼠标键，否则 Mac 上修饰键一直按着。
    func testDeliveryCanOnlyStopWhenNothingIsHeld() {
        let events = VNCSession.loginPasswordFocusInputEvents(x: 4, y: 4)
            + VNCSession.loginPasswordInputEvents(password: "aB")
        let canStop = VNCSession.loginPasswordCanStop(before: events)
        XCTAssertEqual(canStop.count, events.count)
        var heldKeys = Set<UInt32>()
        var buttonDown = false
        for (index, event) in events.enumerated() {
            XCTAssertEqual(canStop[index], heldKeys.isEmpty && !buttonDown, "事件 \(index)")
            switch event {
            case .key(let down, let keysym):
                if down { heldKeys.insert(keysym) } else { heldKeys.remove(keysym) }
            case .pointer(let mask, _, _):
                buttonDown = mask != 0
            case .pause:
                XCTAssertTrue(canStop[index], "暂停时不能有键按着：事件 \(index)")
            default:
                XCTFail("意外的事件")
            }
        }
        XCTAssertTrue(heldKeys.isEmpty)
        XCTAssertFalse(buttonDown)
        // Cmd+A 中间（Super 按下之后、抬起之前）不能停。
        let superDown = events.firstIndex { event in
            if case .key(true, KeyboardInputHandler.keysymSuperL) = event { return true }
            return false
        }
        XCTAssertNotNil(superDown)
        if let superDown { XCTAssertFalse(canStop[superDown + 1]) }
    }
}
