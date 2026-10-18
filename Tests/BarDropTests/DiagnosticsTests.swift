import XCTest
@testable import BarDrop

/// Diagnoseprotokoll: Fehler werden verständlich beschrieben, ohne Namen und Pfade.
final class DiagnosticsTests: XCTestCase {
    func testDescribeNamesCodeAndHidesNames() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 13)
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSLocalizedDescriptionKey: "Die Datei „Geheim.pdf“ konnte nicht nach /Users/fritz/Desktop/Geheim.pdf bewegt werden.",
            NSUnderlyingErrorKey: underlying
        ])
        let text = Diagnostics.describe(error)
        XCTAssertTrue(text.contains("NSCocoaErrorDomain#513 (fileWriteNoPermission)"), text)
        XCTAssertTrue(text.contains("NSPOSIXErrorDomain#13"), text)
        XCTAssertFalse(text.contains("Geheim"), text)
        XCTAssertFalse(text.contains("fritz"), text)
    }

    func testQuickLookCodesHaveNames() {
        XCTAssertEqual(Diagnostics.knownName(domain: "QLThumbnailErrorDomain", code: 2), "noCachedThumbnail")
    }

    func testShortFile() {
        XCTAssertEqual(Diagnostics.shortFile("BarDrop/Thumbnails.swift"), "Thumbnails.swift")
    }
}
