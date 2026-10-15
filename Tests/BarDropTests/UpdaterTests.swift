import XCTest
@testable import BarDrop

/// Stille Updates erst, wenn ein Release mindestens 48 Stunden alt ist.
final class UpdaterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshReleaseIsNotInstalledSilently() {
        XCTAssertFalse(Updater.isOldEnoughForSilentInstall(published: now, now: now))
        XCTAssertFalse(Updater.isOldEnoughForSilentInstall(published: now.addingTimeInterval(-47 * 3600), now: now))
        XCTAssertFalse(Updater.isOldEnoughForSilentInstall(published: now.addingTimeInterval(-(48 * 3600 - 1)), now: now))
    }

    func testReleaseOlderThan48HoursIsInstalledSilently() {
        XCTAssertTrue(Updater.isOldEnoughForSilentInstall(published: now.addingTimeInterval(-48 * 3600), now: now))
        XCTAssertTrue(Updater.isOldEnoughForSilentInstall(published: now.addingTimeInterval(-30 * 24 * 3600), now: now))
    }

    func testMissingOrFutureDateIsNeverSilent() {
        XCTAssertFalse(Updater.isOldEnoughForSilentInstall(published: nil, now: now))
        XCTAssertFalse(Updater.isOldEnoughForSilentInstall(published: now.addingTimeInterval(3600), now: now))
    }

    func testPublishedDateFromGitHub() {
        let date = Updater.publishedDate("2026-10-15T18:09:48Z")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-10-15T18:09:48Z"))
        XCTAssertNotNil(date)
        XCTAssertNil(Updater.publishedDate(nil))
        XCTAssertNil(Updater.publishedDate("gestern"))
        XCTAssertNil(Updater.publishedDate(42))
    }
}
