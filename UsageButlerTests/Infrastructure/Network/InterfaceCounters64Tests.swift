import Darwin
import Foundation
import XCTest
@testable import UsageButlerInfrastructure

final class InterfaceCounters64Tests: XCTestCase {
    /// A synthetic UInt64 parser test cannot catch the kernel truncating a
    /// routing-socket reply for non-platform binaries. Compare the actual
    /// reader with the system tool before and after, allowing live traffic.
    func testLiveCountersStayBetweenSystemReadings() throws {
        let before = try systemCounters()
        let actual = GetifaddrsInterfaceCountersReader().read()
        let after = try systemCounters()
        var checked = 0
        for row in actual {
            guard let lower = before[row.name], let upper = after[row.name],
                  upper.upload >= lower.upload, upper.download >= lower.download else { continue }
            XCTAssertGreaterThanOrEqual(row.uploadBytes, lower.upload, row.name)
            XCTAssertLessThanOrEqual(row.uploadBytes, upper.upload, row.name)
            XCTAssertGreaterThanOrEqual(row.downloadBytes, lower.download, row.name)
            XCTAssertLessThanOrEqual(row.downloadBytes, upper.download, row.name)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    private func systemCounters() throws -> [String: (upload: UInt64, download: UInt64)] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn"]
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let header = try XCTUnwrap(lines.first).split(whereSeparator: \.isWhitespace)
        let inIndex = try XCTUnwrap(header.firstIndex(of: "Ibytes"))
        let outIndex = try XCTUnwrap(header.firstIndex(of: "Obytes"))
        var result: [String: (upload: UInt64, download: UInt64)] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            // Loopback/tunnels leave Address blank. Numeric columns still
            // align from the right; splitting whitespace loses that blank.
            let input = fields.count - (header.count - inIndex)
            let output = fields.count - (header.count - outIndex)
            guard input > 2, output < fields.count, fields[2].hasPrefix("<Link#"),
                  let down = UInt64(fields[input]), let up = UInt64(fields[output]) else { continue }
            result[String(fields[0]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))] = (up, down)
        }
        return result
    }

    func testParserPreservesCountsBeyond32Bits() {
        var record = ifmibdata()
        withUnsafeMutableBytes(of: &record.ifmd_name) { $0.copyBytes(from: Array("lo0\0".utf8)) }
        record.ifmd_data.ifi_obytes = 9_007_199_254_740_993
        record.ifmd_data.ifi_ibytes = 8_000_000_000
        let data = withUnsafeBytes(of: &record) { Data($0) }
        let result = GetifaddrsInterfaceCountersReader.decode(data)
        XCTAssertEqual(result.first?.uploadBytes, 9_007_199_254_740_993)
        XCTAssertEqual(result.first?.downloadBytes, 8_000_000_000)
    }
    func testParserRejectsPartialRecordEvenAfterValidRecord() {
        var record = ifmibdata()
        withUnsafeMutableBytes(of: &record.ifmd_name) { $0.copyBytes(from: Array("lo0\0".utf8)) }
        var data = withUnsafeBytes(of: &record) { Data($0) }
        data.append(0)
        XCTAssertTrue(GetifaddrsInterfaceCountersReader.decode(data).isEmpty)
        XCTAssertTrue(GetifaddrsInterfaceCountersReader.decode(Data()).isEmpty)
    }
    func testDetachedOrUnterminatedNameDoesNotCreateAZeroInterface() {
        var detached = ifmibdata()
        XCTAssertTrue(GetifaddrsInterfaceCountersReader.decode(withUnsafeBytes(of: &detached) { Data($0) }).isEmpty)
        withUnsafeMutableBytes(of: &detached.ifmd_name) { $0.initializeMemory(as: UInt8.self, repeating: 65) }
        XCTAssertTrue(GetifaddrsInterfaceCountersReader.decode(withUnsafeBytes(of: &detached) { Data($0) }).isEmpty)
    }
}
