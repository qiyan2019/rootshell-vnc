import XCTest
@testable import RFBTransport

final class ServerInitNameFieldTests: XCTestCase {
    func testPrefixHexKeepsOnlyTheFirstSixBytes() {
        let field = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x54, 0x4d, 0x61])
        XCTAssertEqual(TransportSession.serverInitPrefixHex(field), "000000000054")
        XCTAssertEqual(
            TransportSession.serverInitPrefixHex(Data([0x0a, 0x0b])),
            "0a0b")
    }

    /// 没有能力前缀时名字段开头就是桌面名，只留 2 字节，够判断前缀不存在。
    func testPrefixHexDoesNotKeepDesktopNameBytes() {
        let name = Data("Ning's Mac mini".utf8)
        XCTAssertEqual(TransportSession.serverInitPrefixHex(name), "4e69")
        XCTAssertEqual(TransportSession.serverInitPrefixHex(Data([0x00, 0x41, 0x42])), "0041")
    }
}
