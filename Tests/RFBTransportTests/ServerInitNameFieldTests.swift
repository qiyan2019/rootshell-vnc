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
}
