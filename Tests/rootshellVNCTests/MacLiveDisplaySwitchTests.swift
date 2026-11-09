import Foundation
import XCTest
@testable import rootshellVNC

/// 真 Mac 切屏探针，只看不控。不设 `AGITO_DISPLAY_PASSWORD_FILE` 时跳过。
/// 密码由本进程读文件，不进参数、不进日志。
@MainActor
final class MacLiveDisplaySwitchTests: XCTestCase {
    func testDisplaySwitchKeepsFramesFlowing() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["AGITO_DISPLAY_PASSWORD_FILE"], !file.isEmpty else {
            throw XCTSkip("未设置 AGITO_DISPLAY_PASSWORD_FILE")
        }
        let password = try String(contentsOfFile: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let session = VNCSession(configuration: VNCConfiguration(
            enableHighPerformanceMode: false,
            videoQualityMode: .standard,
            displaySizingMode: .remoteDisplay,
            enableRemoteAudio: false,
            promptForLoginPasswordAtLoginWindow: false,
            reconnectionPolicy: VNCReconnectionPolicy(isEnabled: false, maximumAttempts: 0)))
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(
            host: env["AGITO_DISPLAY_HOST"] ?? "127.0.0.1",
            port: 5900,
            password: password,
            username: env["AGITO_DISPLAY_USER"] ?? "melody"))
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, session.remoteDisplays.count < 2 || session.currentImage == nil {
            try await Task.sleep(for: .milliseconds(200))
        }
        let displays = session.remoteDisplays
        print("LIVE displays=\(displays.map { "\($0.id):\(Int($0.size.width))x\(Int($0.size.height))" })")
        XCTAssertGreaterThanOrEqual(displays.count, 2)
        guard displays.count >= 2 else { return }
        await observe(session, label: "initial", seconds: 4)
        let steps: [(String, UInt32?)] = [
            ("second", displays[1].id), ("first", displays[0].id),
            ("all", nil), ("second-again", displays[1].id),
        ]
        for (label, id) in steps {
            let accepted = await session.selectRemoteDisplay(id: id)
            print("LIVE select \(label) accepted=\(accepted)")
            await observe(session, label: label, seconds: 8)
        }
    }

    private func observe(_ session: VNCSession, label: String, seconds: Int) async {
        let startFrames = session.framebufferFramesPresented
        var last = session.currentImage.flatMap(FrameSignature.init(image:))
        var changes = 0
        for _ in 0..<(seconds * 4) {
            try? await Task.sleep(for: .milliseconds(250))
            let now = session.currentImage.flatMap(FrameSignature.init(image:))
            if now != last { changes += 1; last = now }
        }
        print("LIVE \(label) state=\(session.connectionState.isConnected) "
            + "fb=\(session.framebufferWidth)x\(session.framebufferHeight) "
            + "presented=\(session.framebufferFramesPresented - startFrames) sigChanges=\(changes) "
            + "displays=\(session.remoteDisplays.count)")
    }
}
