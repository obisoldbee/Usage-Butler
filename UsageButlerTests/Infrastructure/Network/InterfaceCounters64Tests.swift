import Darwin
import Foundation
import XCTest
@testable import UsageButlerInfrastructure

final class InterfaceCounters64Tests: XCTestCase {
    func testParserPreservesCountsBeyond32Bits() {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = UInt16(if_nametoindex("lo0"))
        header.ifm_data.ifi_obytes = 9_007_199_254_740_993
        header.ifm_data.ifi_ibytes = 8_000_000_000
        let data = withUnsafeBytes(of: &header) { Data($0) }
        let result = GetifaddrsInterfaceCountersReader.decode(data)
        XCTAssertEqual(result.first?.uploadBytes, 9_007_199_254_740_993)
        XCTAssertEqual(result.first?.downloadBytes, 8_000_000_000)
    }
    func testParserRejectsTruncatedAndZeroLengthMessages() {
        XCTAssertTrue(GetifaddrsInterfaceCountersReader.decode(Data([0, 0, 0, 0])).isEmpty)
        XCTAssertTrue(GetifaddrsInterfaceCountersReader.decode(Data([255, 255, 0, UInt8(RTM_IFINFO2)])).isEmpty)
    }
}
