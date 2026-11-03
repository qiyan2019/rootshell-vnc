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
    case field
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

    /// 先唤醒，等密码行被识别出来再投递一次。认不出来就不投。
    private func unlockIfNeeded(_ session: VNCSession) async throws {
        guard try consoleIsLocked() else { return }
        await waitForFirstFrame(session)
        await wakeScreen(session)
        try await waitForPasswordField(session)
        let watch = LockWatch()
        let polling = Task.detached {
            while !Task.isCancelled {
                if let sample = RemoteLock.sample() {
                    watch.store(locked: sample.locked, querySeconds: sample.seconds)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer {
            polling.cancel()
            for line in watch.drain() { note(line) }
        }
        let delivery = try await deliverOnce(session, watch: watch)
        note("S0-DELIVERY \(delivery)")
        if delivery == "skipped" { return }
        try await waitUnlocked(watch)
    }

    /// 首帧之后再唤醒，和 `wakeScreenAfterFirstFrame` 一样。
    private func waitForFirstFrame(_ session: VNCSession) async {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, session.currentImage == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        note("S0-FRAME image=\(session.currentImage != nil)")
    }

    /// Shift 按下再松开，锁屏或登录窗再 `nudgePointer`。不产生字符。
    private func wakeScreen(_ session: VNCSession) async {
        let shift = KeyboardInputHandler.keysymShiftL
        session.sendKeyEvent(downFlag: true, key: shift)
        try? await Task.sleep(for: .milliseconds(30))
        session.sendKeyEvent(downFlag: false, key: shift)
        let surface = session.remoteLoginSurface
        let nudge = surface.isLockScreen || surface.isLoginWindow
        if nudge { session.nudgePointer() }
        note("S0-WAKE shift nudge=\(nudge) image=\(session.currentImage != nil)")
    }

    /// 最多 20 秒。4 秒还没有密码行就再唤醒一次，因为休眠时第一次输入会被吃掉。
    private func waitForPasswordField(_ session: VNCSession) async throws {
        let deadline = Date().addingTimeInterval(20)
        let repeatAt = Date().addingTimeInterval(4)
        var nudgedAgain = false
        var nextLog = Date()
        while Date() < deadline {
            if passwordFieldReady(session) {
                note(surfaceLine(session))
                return
            }
            if Date() >= nextLog {
                note(surfaceLine(session) + " image=\(session.currentImage != nil)")
                nextLog = Date().addingTimeInterval(2)
            }
            if !nudgedAgain, Date() >= repeatAt {
                nudgedAgain = true
                await wakeScreen(session)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        note(surfaceLine(session) + " image=\(session.currentImage != nil)")
        note("S0-BLOCK field")
        throw CalibrationError.field
    }

    /// 指挥的两条是 vision，或「登录窗/锁屏并且认出密码行」。
    /// 密码行坐标不公开，和 vision 同一次写上，公告单独成立不算。
    private func passwordFieldReady(_ session: VNCSession) -> Bool {
        session.remoteLoginVisionDetected
    }

    /// 投递前 2 秒内再查一次。锁屏已经翻成 false 时 `shouldContinue` 返回 false。
    private func deliverOnce(_ session: VNCSession, watch: LockWatch) async throws -> String {
        guard let sample = RemoteLock.sample() else {
            note("S0-FAIL lock-query")
            throw CalibrationError.lockQuery
        }
        watch.store(locked: sample.locked, querySeconds: sample.seconds)
        note(String(
            format: "S0-LOCK-SEND locked=%@ query_s=%.3f",
            sample.locked ? "true" : "false", sample.seconds))
        guard sample.locked else { return "skipped" }
        let delivery = await session.sendLoginPassword(shouldContinue: { @MainActor in
            watch.shouldContinue()
        })
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

    /// 投递之后最多再等 10 秒。查询在后台走，主线程继续收帧。
    private func waitUnlocked(_ watch: LockWatch) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if watch.freshUnlocked() {
                note("S0-UNLOCKED")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        note("S0-BLOCK unlock")
        throw CalibrationError.unlock
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

/// 投递期间的锁屏采样。查询在后台，`shouldContinue` 只读最近 2 秒内的结果。
private final class LockWatch: @unchecked Sendable {
    private let gate = NSLock()
    private var locked = true
    private var at = Date.distantPast
    private var lines: [String] = []

    func store(locked: Bool, querySeconds: Double) {
        gate.lock()
        self.locked = locked
        at = Date()
        lines.append(String(
            format: "S0-IOREG wall=%.3f locked=%@ query_s=%.3f",
            at.timeIntervalSince1970, locked ? "true" : "false", querySeconds))
        gate.unlock()
    }

    func shouldContinue() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return locked && Date().timeIntervalSince(at) < 2
    }

    func freshUnlocked() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return !locked && Date().timeIntervalSince(at) < 2
    }

    func drain() -> [String] {
        gate.lock()
        defer { gate.unlock() }
        let copy = lines
        lines.removeAll()
        return copy
    }
}

/// macmini 的 `CGSSessionScreenIsLocked`。慢于 2 秒或真假并存则丢掉。
private enum RemoteLock {
    static func sample() -> (locked: Bool, seconds: Double)? {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "macmini",
            "ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers xml1 -o - - "
                + "| grep -A1 CGSSessionScreenIsLocked",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let seconds = Date().timeIntervalSince(started)
        guard process.terminationStatus == 0, seconds < 2 else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let trues = text.components(separatedBy: "<true/>").count - 1
        let falses = text.components(separatedBy: "<false/>").count - 1
        if trues > 0, falses == 0 { return (true, seconds) }
        if falses > 0, trues == 0 { return (false, seconds) }
        return nil
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
