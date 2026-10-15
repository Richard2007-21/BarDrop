import XCTest
@testable import BarDrop

/// Einführung: was beim Abschluss mit „Beim Anmelden öffnen“ geschieht.
final class OnboardingTests: XCTestCase {
    private func change(completed: Bool, wanted: Bool, rerun: Bool, enabled: Bool) -> OnboardingModel.LoginItemChange? {
        OnboardingModel.loginItemChange(completed: completed, wanted: wanted, isRerun: rerun, enabled: enabled)
    }

    func testFirstLaunchRegistersWhenWantedLikeBefore() {
        XCTAssertEqual(change(completed: true, wanted: true, rerun: false, enabled: false), .register)
        XCTAssertNil(change(completed: true, wanted: false, rerun: false, enabled: false))
        XCTAssertNil(change(completed: true, wanted: false, rerun: false, enabled: true),
                     "Beim ersten Start wird nie abgemeldet")
    }

    func testRerunUnregistersWhenSwitchedOff() {
        XCTAssertEqual(change(completed: true, wanted: false, rerun: true, enabled: true), .unregister)
        XCTAssertNil(change(completed: true, wanted: true, rerun: true, enabled: true), "Schon angemeldet")
        XCTAssertEqual(change(completed: true, wanted: true, rerun: true, enabled: false), .register)
        XCTAssertNil(change(completed: true, wanted: false, rerun: true, enabled: false), "Schon abgemeldet")
    }

    func testSkippingOrClosingChangesNothing() {
        for wanted in [true, false] {
            for rerun in [true, false] {
                for enabled in [true, false] {
                    XCTAssertNil(change(completed: false, wanted: wanted, rerun: rerun, enabled: enabled))
                }
            }
        }
    }
}
