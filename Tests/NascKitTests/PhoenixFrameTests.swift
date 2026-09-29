import XCTest

@testable import NascKit

final class PhoenixFrameTests: XCTestCase {
    // Phoenix v2 frames as the server sends them when a channel process stops or crashes.
    func testAClosedOrCrashedChannelEndsIt() throws {
        XCTAssertTrue(try InFrame.parse(#"["1",null,"session:s","phx_close",{}]"#).endsChannel)
        XCTAssertTrue(try InFrame.parse(#"["1","1","session:s","phx_error",{}]"#).endsChannel)
    }

    func testOrdinaryPushesDoNot() throws {
        XCTAssertFalse(try InFrame.parse(#"[null,null,"session:s","event",{"kind":"tool_call"}]"#).endsChannel)
        XCTAssertFalse(try InFrame.parse(#"[null,null,"lobby","sessions_changed",{}]"#).endsChannel)
    }
}
