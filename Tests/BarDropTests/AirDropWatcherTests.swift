import XCTest
@testable import BarDrop

final class AirDropWatcherTests: XCTestCase {
    /// Absender aus der Quarantäne: AirDrop ja, Browser nein
    func testQuarantineAgent() throws {
        XCTAssertEqual(AirDropWatcher.agent(fromQuarantine: "0083;65f1a2b3;sharingd;"), "sharingd")
        XCTAssertEqual(AirDropWatcher.agent(fromQuarantine: "0081;65f1a2b3;Safari;4C1B-UUID"), "Safari")
        XCTAssertNil(AirDropWatcher.agent(fromQuarantine: "0083;65f1a2b3"))
        XCTAssertTrue(AirDropWatcher.isAirDrop(agent: "sharingd"))
        XCTAssertFalse(AirDropWatcher.isAirDrop(agent: "Safari"))

        // Aus einer echten Datei gelesen
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("airdrop-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(AirDropWatcher.quarantineAgent(file))
        let value = "0083;65f1a2b3;sharingd;"
        XCTAssertEqual(setxattr(file.path, "com.apple.quarantine", value, value.utf8.count, 0, 0), 0)
        XCTAssertEqual(AirDropWatcher.quarantineAgent(file), "sharingd")
    }
}
