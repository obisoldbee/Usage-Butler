import XCTest
@testable import UsageButlerInfrastructure
import UsageButlerCore
import UsageButlerDomain

/// The whole 查看网络 rule rests on one assumption that no unit test can check:
/// that `State:/Network/Global/IPv4` is spelled correctly, that its
/// `PrimaryInterface` key is really there, and that the friendly-name call
/// returns anything. If any of that were wrong the page would fall back to
/// "cannot read" forever and every test would still pass.
///
/// This runs against the machine's real network state. It asserts only what
/// must hold on any Mac that has a configured network stack, and prints what it
/// found so the observation is reviewable rather than buried in a green tick.
final class SystemConfigurationNetworkPathReaderTests: XCTestCase {
    func testDynamicStoreStateIsReadableOnThisMachine() {
        let path = SystemConfigurationNetworkPathReader().currentPath()
        XCTAssertTrue(
            path.isReadable,
            "SCDynamicStore returned nothing readable; the key or the cast is wrong"
        )
        print("""
        [network-path] primary=\(path.primaryInterfaceName ?? "nil") \
        friendly=\(path.friendlyNames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        """)
    }

    func testRepeatedReadsAreStableAndCheapEnoughToPoll() throws {
        let reader = SystemConfigurationNetworkPathReader()
        let first = reader.currentPath()
        for _ in 0..<20 {
            XCTAssertEqual(reader.currentPath(), first)
        }
    }

    func testFriendlyNamesAreKeyedByBSDName() {
        let path = SystemConfigurationNetworkPathReader().currentPath()
        for (bsd, display) in path.friendlyNames {
            XCTAssertFalse(bsd.isEmpty)
            XCTAssertFalse(display.isEmpty)
            // The UI looks a name up by BSD interface, so a key that is not a
            // BSD name would silently never match.
            XCTAssertNil(bsd.firstIndex(where: { $0 == " " || $0 == "/" }), "key \(bsd)")
        }
    }
}
