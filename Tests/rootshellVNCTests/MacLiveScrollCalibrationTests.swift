import CoreGraphics
import Foundation
import RFBProtocol
import XCTest
@testable import rootshellVNC

/// macmini 滚动标定。不设 `AGITO_SCROLL_PASSWORD_FILE` 时跳过。
/// 只连 `100.100.10.11:5900`，密码由本进程读文件，不进参数、不进日志。
@MainActor
final class MacLiveScrollCalibrationTests: XCTestCase {
    func testMacLiveScrollCalibration() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let passwordFile = env["AGITO_SCROLL_PASSWORD_FILE"], !passwordFile.isEmpty else {
            throw XCTSkip("未设置 AGITO_SCROLL_PASSWORD_FILE")
        }
        let timeline = env["AGITO_SCROLL_TIMELINE"] ?? NSTemporaryDirectory() + "agito-scroll-timeline.jsonl"
        let runner = MacLiveScrollCalibration(passwordFile: passwordFile, timelinePath: timeline)
        try await runner.run()
    }
}

private enum CalibrationError: Error {
    case identity
    case auth
    case unlock
    case lockQuery
    case notReady
    case probe
    case ssh
    case passwordFile
}

@MainActor
private final class MacLiveScrollCalibration {
    private let passwordFile: String
    private let timelinePath: String
    private let host = "100.100.10.11"
    private let port: UInt16 = 5900
    private let username = "ning"
    /// C1 每个方向的 changed 次数。N=1 时第 10 次才凑满 1 个 coarse 单位。
    private let changedCount = 10
    /// C3 惯性 changed 的固定 pointDelta。
    private let momentumDelta: Int32 = -8
    private let momentumCount = 20
    private var anchorX: UInt16 = 0
    private var anchorY: UInt16 = 0
    private var sent: SentLog?
    private var handler: TouchInputHandler?

    init(passwordFile: String, timelinePath: String) {
        self.passwordFile = passwordFile
        self.timelinePath = timelinePath
    }

    func run() async throws {
        precondition(host == "100.100.10.11")
        let session = try await connect()
        defer { session.disconnect() }
        try await unlockIfNeeded(session)
        try startProbe()
        try await Task.sleep(for: .seconds(2))
        try reportScale(session)
        try await runSamples(session)
        fflush(stderr)
    }

    private func connect() async throws -> VNCSession {
        let password = try readPassword()
        let session = makeSession()
        var established = false
        defer {
            if !established { session.disconnect() }
        }
        try await open(session, password: password)
        try await waitUntilReady(session)
        try verifyIdentity(session)
        anchorX = UInt16(session.framebufferWidth / 2)
        anchorY = UInt16(session.framebufferHeight / 2)
        installHandler(session)
        established = true
        return session
    }

    private func open(_ session: VNCSession, password: String) async throws {
        guard session.configuration.displaySizingMode == .remoteDisplay,
              session.configuration.enableProtocolTrace == false else {
            note("S0-FAIL sizing")
            throw CalibrationError.notReady
        }
        do {
            try await session.connect(credentials: VNCCredentials(
                host: host, port: port, password: password, username: username))
        } catch {
            if Self.isAuth(error) {
                note("S0-BLOCK auth")
                throw CalibrationError.auth
            }
            note("S0-FAIL connect")
            throw CalibrationError.notReady
        }
    }

    private func installHandler(_ session: VNCSession) {
        let log = SentLog(path: timelinePath)
        sent = log
        handler = TouchInputHandler(
            sendPointerEvent: { _, _, _ in },
            sendScrollEvent: { event in
                session.sendScrollEvent(event)
                log.scroll(event)
            },
            sendGestureEvent: { event in
                session.sendGestureEvent(event)
                log.gesture(event)
            })
    }

    private func makeSession() -> VNCSession {
        let configuration = VNCConfiguration(
            enableHighPerformanceMode: false,
            videoQualityMode: .standard,
            enableRemoteAudio: false,
            promptForLoginPasswordAtLoginWindow: true,
            enableProtocolTrace: false,
            reconnectionPolicy: VNCReconnectionPolicy(isEnabled: false, maximumAttempts: 0))
        return VNCSession(configuration: configuration)
    }

    private func readPassword() throws -> String {
        guard FileManager.default.isReadableFile(atPath: passwordFile) else {
            note("S0-FAIL password-file")
            throw CalibrationError.passwordFile
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: passwordFile))
        let password = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        guard !password.isEmpty else {
            note("S0-FAIL password-file")
            throw CalibrationError.passwordFile
        }
        return password
    }

    private func waitUntilReady(_ session: VNCSession) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if case .failed = session.connectionState {
                note("S0-FAIL connect")
                throw CalibrationError.notReady
            }
            if session.connectionState.isConnected,
               session.framebufferWidth > 0,
               session.framebufferHeight > 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        note("S0-FAIL connect")
        throw CalibrationError.notReady
    }

    private func verifyIdentity(_ session: VNCSession) throws {
        let bytes = Array(session.serverName.utf8)
        let prefix = bytes.prefix(2).map { String(format: "%02x", $0) }.joined()
        let width = session.framebufferWidth
        let height = session.framebufferHeight
        note("S0-IDENTITY len=\(bytes.count) prefix=\(prefix) fb=\(width)x\(height)")
        guard bytes.count == 7, prefix == "6d61", width == 3840, height == 2160 else {
            note("S0-BLOCK identity")
            throw CalibrationError.identity
        }
    }

    /// 照 `runLoginSend`。锁屏位是信号证据，不等 vision。这一轮只投递一次。
    private func unlockIfNeeded(_ session: VNCSession) async throws {
        guard try consoleIsLocked() else { return }
        await waitForFirstFrame(session)
        await waitForEvidence(session)
        let evidence = loginEvidence(session)
        note("S0-EVIDENCE \(evidence.rawValue)")
        note(surfaceLine(session))
        mark("evidence")
        if evidence != .none {
            wakeRemote(session)
            mark("wake")
            try await Task.sleep(for: .milliseconds(1200))
            mark("settle")
        }
        try await deliverAfterQuiet(session, evidence: evidence)
    }

    private func deliverAfterQuiet(
        _ session: VNCSession, evidence: LoginEvidence
    ) async throws {
        guard await waitForLoginQuiet(session, evidence: evidence) else {
            mark("quiet-abort")
            try await stopUnlessConsoleOpen(session)
            return
        }
        mark("quiet")
        let signature = session.currentImage.flatMap(FrameSignature.init(image:))
        mark("signature")
        note("S0-SIGNATURE has=\(signature != nil)")
        let delivery = await session.sendLoginPassword(shouldContinue: { @MainActor in
            self.deliveryShouldContinue(session, evidence: evidence, signature: signature)
        })
        note("S0-DELIVERY \(Self.deliveryName(delivery))")
        mark("delivery")
        guard delivery != .notSent else {
            note("S0-RECHECK skipped")
            note("S0-BLOCK unlock")
            throw CalibrationError.unlock
        }
        let result = await recheckLogin(session, evidence: evidence, signature: signature)
        note("S0-RECHECK \(result)")
        note(surfaceLine(session))
        mark("recheck")
        guard result == "cleared" else {
            _ = try? consoleIsLocked()
            note("S0-BLOCK unlock")
            throw CalibrationError.unlock
        }
        try await confirmConsoleUnlocked()
    }

    /// 信号消失表示已经解开，密码不能再打进桌面。安静超时则不投递。
    private func stopUnlessConsoleOpen(_ session: VNCSession) async throws {
        if try !consoleIsLocked() {
            note("S0-DELIVERY skipped")
            note("S0-UNLOCKED")
            return
        }
        note(surfaceLine(session))
        note("S0-BLOCK unlock")
        throw CalibrationError.unlock
    }

    /// 会话标志先清，ioreg 可能晚一点。最多再等 5 秒，不再投递。
    private func confirmConsoleUnlocked() async throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            if try !consoleIsLocked() {
                note("S0-UNLOCKED")
                return
            }
            if Date() >= deadline {
                note("S0-BLOCK unlock")
                throw CalibrationError.unlock
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    /// 公告可能比首帧晚到。ioreg 已经是锁屏时，先等信号，避免把这一轮标成没有证据。
    private func waitForEvidence(_ session: VNCSession) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, loginEvidence(session) == .none {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitForFirstFrame(_ session: VNCSession) async {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, session.currentImage == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        note("S0-FRAME image=\(session.currentImage != nil)")
    }

    /// 左 Shift 按下再松开，不动光标。抬起和 1.2 秒等待重叠，和 `wakeRemote` 一样。
    private func wakeRemote(_ session: VNCSession) {
        let shift = KeyboardInputHandler.keysymShiftL
        session.sendKeyEvent(downFlag: true, key: shift)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            session.sendKeyEvent(downFlag: false, key: shift)
        }
        note("S0-WAKE shift")
    }

    /// 5 秒内要有连续 0.7 秒画面不大变。信号证据中途消失就中止。
    private func waitForLoginQuiet(
        _ session: VNCSession, evidence: LoginEvidence
    ) async -> Bool {
        let start = Date()
        var quietSince = start
        var signature = session.currentImage.flatMap(FrameSignature.init(image:))
        while Date().timeIntervalSince(start) < 5 {
            if evidence == .signal, !signalActive(session) {
                note("S0-QUIET signal-gone")
                return false
            }
            let latest = session.currentImage.flatMap(FrameSignature.init(image:))
            if let signature, let latest, latest.isMajorChange(from: signature) {
                quietSince = Date()
            }
            signature = latest
            if Date().timeIntervalSince(quietSince) >= 0.7 { return true }
            try? await Task.sleep(for: .milliseconds(60))
        }
        note("S0-QUIET timeout")
        return false
    }

    /// 信号：锁屏位还在才继续。视觉：相对发送签名不是大变。没有证据就一直继续。
    private func deliveryShouldContinue(
        _ session: VNCSession,
        evidence: LoginEvidence,
        signature: FrameSignature?
    ) -> Bool {
        switch evidence {
        case .signal:
            return signalActive(session)
        case .visual:
            guard let signature,
                  let latest = session.currentImage.flatMap(FrameSignature.init(image:))
            else { return true }
            return !latest.isMajorChange(from: signature)
        case .none:
            return true
        }
    }

    /// 信号复检：锁屏位变假就是解开。10 秒还在登录界面记 maybeWrong。
    private func recheckLogin(
        _ session: VNCSession,
        evidence: LoginEvidence,
        signature: FrameSignature?
    ) async -> String {
        guard evidence != .none, session.connectionState.isConnected else { return "skipped" }
        let start = Date()
        var changedSince: Date?
        while Date().timeIntervalSince(start) < 10 {
            guard session.connectionState.isConnected else { return "disconnected" }
            if let verdict = await recheckSample(
                session, evidence: evidence, signature: signature, changedSince: &changedSince
            ) { return verdict }
            try? await Task.sleep(for: .milliseconds(60))
        }
        guard session.connectionState.isConnected else { return "disconnected" }
        if evidence == .visual, await visualCleared(session) { return "cleared" }
        return "maybeWrong"
    }

    private func recheckSample(
        _ session: VNCSession,
        evidence: LoginEvidence,
        signature: FrameSignature?,
        changedSince: inout Date?
    ) async -> String? {
        switch evidence {
        case .signal:
            return signalActive(session) ? nil : "cleared"
        case .visual:
            return await visualRecheck(session, signature: signature, changedSince: &changedSince)
        case .none:
            return "skipped"
        }
    }

    /// 大变持续满 1 秒再 OCR 一次。识别失败按「不是登录界面」。
    private func visualRecheck(
        _ session: VNCSession,
        signature: FrameSignature?,
        changedSince: inout Date?
    ) async -> String? {
        guard let signature,
              let latest = session.currentImage.flatMap(FrameSignature.init(image:)),
              latest.isMajorChange(from: signature) else { return nil }
        if changedSince == nil { changedSince = Date() }
        guard let since = changedSince, Date().timeIntervalSince(since) >= 1 else { return nil }
        return await visualCleared(session) ? "cleared" : "maybeWrong"
    }

    private func visualCleared(_ session: VNCSession) async -> Bool {
        guard let image = session.currentImage else { return true }
        return await !VNCLoginScreenRecognizer.isLoginScreen(image)
    }

    private func loginEvidence(_ session: VNCSession) -> LoginEvidence {
        if signalActive(session) { return .signal }
        if session.remoteLoginVisionDetected { return .visual }
        return .none
    }

    private func signalActive(_ session: VNCSession) -> Bool {
        let surface = session.remoteLoginSurface
        return surface.isLockScreen || surface.isLoginWindow
    }

    private func mark(_ name: String) {
        note(String(format: "S0-STAGE %@ wall=%.3f", name, Date().timeIntervalSince1970))
    }

    private static func deliveryName(_ delivery: VNCLoginPasswordDelivery) -> String {
        switch delivery {
        case .delivered: return "delivered"
        case .stopped: return "stopped"
        case .notSent: return "notSent"
        }
    }

    private func surfaceLine(_ session: VNCSession) -> String {
        let surface = session.remoteLoginSurface
        return "S0-SURFACE lock=\(surface.isLockScreen) login=\(surface.isLoginWindow) "
            + "vision=\(session.remoteLoginVisionDetected)"
    }

    private func consoleIsLocked() throws -> Bool {
        let started = Date()
        let locked = try lockFlags()
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed < 2 else {
            note("S0-FAIL lock-query-slow")
            throw CalibrationError.lockQuery
        }
        note(String(
            format: "S0-LOCK true=%d false=%d query_s=%.3f",
            locked.trues, locked.falses, elapsed))
        if locked.trues > 0, locked.falses == 0 { return true }
        if locked.falses > 0, locked.trues == 0 { return false }
        note("S0-FAIL lock-ambiguous")
        throw CalibrationError.lockQuery
    }

    /// 解锁之后才把探针放到屏幕上，避免它盖住密码框。
    private func startProbe() throws {
        let script = ProcessInfo.processInfo.environment["AGITO_SCROLL_PROBE_SCRIPT"]
            ?? "/Users/melody/Source/llm/Agito-worktrees/vnc-scroll-S0/Agito/native/test-vnc/mac-scroll.sh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, "probe-start"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            note("S0-FAIL probe-start")
            throw CalibrationError.probe
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            note("S0-FAIL probe-start")
            throw CalibrationError.probe
        }
        note("S0-PROBE started")
    }

    private func lockFlags() throws -> (trues: Int, falses: Int) {
        let output = try ssh(
            "ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers xml1 -o - - | grep -A1 CGSSessionScreenIsLocked")
        let trues = output.components(separatedBy: "<true/>").count - 1
        let falses = output.components(separatedBy: "<false/>").count - 1
        return (trues, falses)
    }

    private func reportScale(_ session: VNCSession) throws {
        let line = try ssh("head -n 1 /tmp/agito-scroll-probe.jsonl")
            .trimmingCharacters(in: .newlines)
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == "start",
              let screen = object["screen"] as? [String: Any],
              let screenW = Self.number(screen["w"]),
              let screenH = Self.number(screen["h"]),
              screenW > 0, screenH > 0 else {
            note("S0-FAIL probe-start")
            throw CalibrationError.probe
        }
        let width = Double(session.framebufferWidth)
        let height = Double(session.framebufferHeight)
        note(
            "S0-C4 Pw=\(width / screenW) Ph=\(height / screenH) "
                + "screen_w=\(screenW) screen_h=\(screenH) "
                + "scale=\(Self.number(screen["scale"]).map(String.init(describing:)) ?? "nil") "
                + "natural=\(object["natural"] ?? "nil") "
                + "fb=\(session.framebufferWidth)x\(session.framebufferHeight)")
    }

    private func runSamples(_ session: VNCSession) async throws {
        try await runPrecise(session)
        try await runWheels(session)
        try await runMomentum(session)
    }

    private func runPrecise(_ session: VNCSession) async throws {
        let samples: [(Int32, Int32)] = [
            (1, 1), (1, -1), (10, 1), (10, -1), (100, 1), (100, -1),
        ]
        for (magnitude, sign) in samples {
            let name = sign > 0 ? "pos" : "neg"
            let id = "C1-N\(magnitude)-\(name)"
            try await beginGroup(id, session)
            var wheel = ScrollWheelUnitAccumulator()
            gesture(.began)
            scroll(dy: 0, phase: .began, momentum: .none, wheel: &wheel)
            for _ in 0..<changedCount {
                scroll(dy: sign * magnitude, phase: .changed, momentum: .none, wheel: &wheel)
                try await Task.sleep(for: .milliseconds(120))
            }
            scroll(dy: 0, phase: .ended, momentum: .none, wheel: &wheel)
            gesture(.ended)
            sent?.end(id)
        }
    }

    private func runWheels(_ session: VNCSession) async throws {
        let groups: [(String, UInt8, Int)] = [
            ("C2-up-1", 0x08, 1),
            ("C2-up-10", 0x08, 10),
            ("C2-down-1", 0x10, 1),
            ("C2-down-10", 0x10, 10),
        ]
        for (id, mask, count) in groups {
            try await gap()
            sent?.begin(id)
            point(session, mask: 0)
            for _ in 0..<count {
                point(session, mask: mask)
                point(session, mask: 0)
                try await Task.sleep(for: .milliseconds(40))
            }
            sent?.end(id)
        }
    }

    private func runMomentum(_ session: VNCSession) async throws {
        try await beginGroup("C3", session)
        var wheel = ScrollWheelUnitAccumulator()
        gesture(.began)
        scroll(dy: 0, phase: .began, momentum: .none, wheel: &wheel)
        scroll(dy: -30, phase: .changed, momentum: .none, wheel: &wheel)
        scroll(dy: 0, phase: .ended, momentum: .none, wheel: &wheel)
        gesture(.ended)
        try await Task.sleep(for: .milliseconds(100))
        scroll(dy: 0, phase: .none, momentum: .began, wheel: &wheel)
        for _ in 0..<momentumCount {
            scroll(dy: momentumDelta, phase: .none, momentum: .changed, wheel: &wheel)
            try await Task.sleep(for: .milliseconds(50))
        }
        scroll(dy: 0, phase: .none, momentum: .ended, wheel: &wheel)
        try await Task.sleep(for: .seconds(2.5))
        sent?.end("C3")
    }

    private func beginGroup(_ id: String, _ session: VNCSession) async throws {
        try await gap()
        sent?.begin(id)
        point(session, mask: 0)
    }

    private func point(_ session: VNCSession, mask: UInt8) {
        session.sendPointerEvent(buttonMask: mask, x: anchorX, y: anchorY)
        sent?.pointer(mask: mask, x: anchorX, y: anchorY)
    }

    private func gesture(_ kind: AppleGestureEvent.Kind) {
        handler?.handleGesture(kind: kind, x: anchorX, y: anchorY)
    }

    private func scroll(
        dy: Int32,
        phase: AppleScrollEvent.Phase,
        momentum: AppleScrollEvent.MomentumPhase,
        wheel: inout ScrollWheelUnitAccumulator
    ) {
        let coarse = wheel.consume(pointDeltaX: 0, pointDeltaY: dy)
        handler?.handleScroll(
            x: anchorX,
            y: anchorY,
            pointDeltaX: 0,
            pointDeltaY: dy,
            coarseDeltaX: coarse.x,
            coarseDeltaY: coarse.y,
            scrollPhase: phase,
            momentumPhase: momentum)
    }

    private func gap() async throws {
        try await Task.sleep(for: .milliseconds(1500))
    }

    private func ssh(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "macmini", command,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            note("S0-FAIL ssh")
            throw CalibrationError.ssh
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            note("S0-FAIL ssh")
            throw CalibrationError.ssh
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func note(_ line: String) {
        fputs(line + "\n", stderr)
        fflush(stderr)
    }

    private static func isAuth(_ error: Error) -> Bool {
        guard let error = error as? VNCError else { return false }
        if case .authenticationFailed = error { return true }
        return false
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

private enum LoginEvidence: String {
    case signal
    case visual
    case none
}

/// 12×8 量化亮度，和 App `ScreenSharingFrameSignature` 同一条规则。只在内存里比较。
private struct FrameSignature: Equatable {
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

@MainActor
private final class SentLog {
    private let handle: FileHandle
    private var group = ""

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path) ?? FileHandle.standardError
    }

    func begin(_ id: String) {
        group = id
        write(["op": "begin", "id": id, "wall": Self.wall()])
    }

    func end(_ id: String) {
        write(["op": "end", "id": id, "wall": Self.wall()])
    }

    func scroll(_ event: AppleScrollEvent) {
        write([
            "op": "sent",
            "id": group,
            "kind": "scroll",
            "wall": Self.wall(),
            "phase": event.scrollPhase.rawValue,
            "momentum": event.momentumPhase.rawValue,
            "pointDeltaX": event.pointDeltaX,
            "pointDeltaY": event.pointDeltaY,
            "deltaX": event.deltaX,
            "deltaY": event.deltaY,
            "x": event.x,
            "y": event.y,
        ])
    }

    func gesture(_ event: AppleGestureEvent) {
        write([
            "op": "sent",
            "id": group,
            "kind": "gesture",
            "wall": Self.wall(),
            "gesture": event.kind.rawValue,
            "x": event.x,
            "y": event.y,
        ])
    }

    func pointer(mask: UInt8, x: UInt16, y: UInt16) {
        write([
            "op": "sent",
            "id": group,
            "kind": "pointer",
            "wall": Self.wall(),
            "buttonMask": mask,
            "x": x,
            "y": y,
        ])
    }

    private func write(_ fields: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: fields) else { return }
        data.append(0x0A)
        handle.write(data)
        try? handle.synchronize()
    }

    private static func wall() -> Double {
        Date().timeIntervalSince1970
    }
}
