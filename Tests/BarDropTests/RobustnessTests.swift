import XCTest
import AppKit
@testable import BarDrop

/// Externe Laufwerke, Downloads hinter Links, Ordner namens „tmp“ im Benutzerordner.
/// Dazu Absicherungen, dass Bilder aus dem Web weiterhin als echte Dateien ankommen.
final class RobustnessTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropRobust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        AppSettings.shared.stackMultiple = true
        AppSettings.shared.stackThreshold = 2
        FakeWeb.reset()
        URLProtocol.registerClass(FakeWeb.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(FakeWeb.self)
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    // MARK: Externe Laufwerke

    @discardableResult
    private func hdiutil(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    /// Legt ein kleines Laufwerk an und schließt es unter /Volumes an, wie einen USB-Stick.
    private func makeVolume() throws -> (image: URL, mount: URL, name: String) {
        let name = "BDTest\(Int.random(in: 10_000...99_999))"
        let image = base.appendingPathComponent("\(name).dmg")
        let (created, out) = hdiutil(["create", "-size", "8m", "-fs", "APFS", "-volname", name, image.path])
        guard created == 0 else { throw XCTSkip("Kein Test-Laufwerk möglich: \(out)") }
        let (attached, out2) = hdiutil(["attach", image.path, "-nobrowse"])
        let mount = URL(fileURLWithPath: "/Volumes/\(name)")
        guard attached == 0, FileManager.default.fileExists(atPath: mount.path) else {
            throw XCTSkip("Test-Laufwerk lässt sich nicht anschließen: \(out2)")
        }
        return (image, mount, name)
    }

    func testEntryOnDisconnectedDriveSurvivesAndReturns() throws {
        let volume = try makeVolume()
        var attached = true
        defer { if attached { hdiutil(["detach", volume.mount.path, "-force"]) } }

        let file = volume.mount.appendingPathComponent("Bericht.pdf")
        try Data("Inhalt".utf8).write(to: file)
        let storeDir = base.appendingPathComponent("Store")
        ShelfStore(baseDirectory: storeDir).add([ShelfFile(url: file, owned: false)])
        XCTAssertNil(ShelfFile.offlineVolumeName(of: file), "Angeschlossen gilt nicht als offline")

        // Laufwerk abziehen, BarDrop neu starten
        hdiutil(["detach", volume.mount.path, "-force"])
        attached = false
        let offline = ShelfStore(baseDirectory: storeDir)
        XCTAssertEqual(offline.entries.count, 1, "Eintrag bleibt, solange das Laufwerk fehlt")
        XCTAssertEqual(offline.entries.first?.files.first?.offlineVolumeName, volume.name)
        offline.pruneMissingFiles()          // passiert beim Öffnen der Ablage
        XCTAssertEqual(offline.entries.count, 1, "Auch beim Öffnen der Ablage nicht entfernt")

        // Wieder anschließen, erneut starten
        let (reattached, _) = hdiutil(["attach", volume.image.path, "-nobrowse"])
        if reattached == 0 { attached = true }
        let back = ShelfStore(baseDirectory: storeDir)
        XCTAssertEqual(back.entries.count, 1)
        XCTAssertEqual(back.entries.first?.files.first?.url.path, file.path)
        XCTAssertNil(back.entries.first?.files.first?.offlineVolumeName)
    }

    func testDeletedFileOnConnectedDriveIsStillRemoved() throws {
        let volume = try makeVolume()
        defer { hdiutil(["detach", volume.mount.path, "-force"]) }
        let file = volume.mount.appendingPathComponent("weg.txt")
        try Data("x".utf8).write(to: file)
        let store = ShelfStore(baseDirectory: base.appendingPathComponent("Store"))
        store.add([ShelfFile(url: file, owned: false)])
        try FileManager.default.removeItem(at: file)
        store.pruneMissingFiles()
        XCTAssertTrue(store.entries.isEmpty, "Gelöschte Dateien verschwinden wie bisher")
    }

    func testOfflineDetectionIgnoresNormalPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertNil(ShelfFile.offlineVolumeName(of: home.appendingPathComponent("Desktop/a.txt")))
        XCTAssertNil(ShelfFile.offlineVolumeName(of: URL(fileURLWithPath: "/Volumes")))
        XCTAssertEqual(ShelfFile.offlineVolumeName(of: URL(fileURLWithPath: "/Volumes/GibtsNicht-\(UUID().uuidString)/x.txt"))?.hasPrefix("GibtsNicht"), true)
    }

    // MARK: Ordner im Benutzerordner

    func testUserFoldersNamedTmpOrCachesAreUserFiles() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(ContentImporter.isUserFile(home.appendingPathComponent("Projekte/tmp/notizen.txt")))
        XCTAssertTrue(ContentImporter.isUserFile(home.appendingPathComponent("Documents/Caches/foto.png")))
        XCTAssertTrue(ContentImporter.isUserFile(home.appendingPathComponent("Desktop/TemporaryItems/a.txt")))
    }

    func testTemporaryLocationsStayForeign() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Browser und Apps: werden weiterhin kopiert, damit sie nicht verschwinden
        XCTAssertFalse(ContentImporter.isUserFile(URL(fileURLWithPath: "/private/tmp/bild.png")))
        XCTAssertFalse(ContentImporter.isUserFile(URL(fileURLWithPath: "/tmp/bild.png")))
        XCTAssertFalse(ContentImporter.isUserFile(URL(fileURLWithPath: "/private/var/folders/ab/cd/T/TemporaryItems/bild.png")))
        XCTAssertFalse(ContentImporter.isUserFile(home.appendingPathComponent("Library/Caches/com.google.Chrome/bild.png")))
        XCTAssertFalse(ContentImporter.isUserFile(home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/tmp/bild.jpg")))
        XCTAssertFalse(ContentImporter.isUserFile(FileManager.default.temporaryDirectory.appendingPathComponent("bild.png")))
    }

    // MARK: Downloads hinter Links

    private func download(_ path: String) -> URL? {
        let importer = ContentImporter(storage: base.appendingPathComponent("Items"), convertImages: true)
        let done = expectation(description: path)
        var result: URL?
        importer.download(URL(string: "https://\(FakeWeb.host)\(path)")!) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 60)
        return result
    }

    private func isImage(_ url: URL) -> Bool { ImporterChecks.isReadableImage(url) }

    func testArchiveLinkStopsRightAway() {
        XCTAssertNil(download("/archiv.zip"))
        XCTAssertLessThan(FakeWeb.bytesSent, 5_000_000, "Von 50 MB dürfen nur die ersten Stücke geladen werden")
    }

    func testUnknownTypeStopsAtLimit() {
        XCTAssertNil(download("/gross.bin"))
        XCTAssertLessThan(FakeWeb.bytesSent, 40_000_000)
    }

    func testImageWithCorrectTypeStillArrives() throws {
        let file = try XCTUnwrap(download("/bild.png"))
        XCTAssertTrue(isImage(file))
    }

    func testImageServedAsOctetStreamStillArrives() throws {
        // Viele Server liefern Bilder ohne passenden Typ: Sie müssen weiter ankommen
        let file = try XCTUnwrap(download("/bild-ohne-typ"))
        XCTAssertTrue(isImage(file))
    }

    func testLargeImageIsNeverStopped() throws {
        let file = try XCTUnwrap(download("/grosses-bild.png"))
        XCTAssertTrue(isImage(file))
        XCTAssertGreaterThan(FakeWeb.bytesSent, 30_000_000, "Bilder werden immer vollständig geladen")
    }

    func testWebPageIsNotAnImage() {
        XCTAssertNil(download("/seite"))
    }

    /// Ganzer Weg wie beim Ablegen aus dem Browser: Adresse auf dem Pasteboard.
    private func importLink(_ path: String) -> [ShelfFile] {
        let importer = ContentImporter(storage: base.appendingPathComponent("Items"), convertImages: true)
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropRobust-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([URL(string: "https://\(FakeWeb.host)\(path)")! as NSURL])
        let done = expectation(description: "Import")
        var files: [ShelfFile] = []
        importer.importContent(of: pb) { files = $0; done.fulfill() }
        wait(for: [done], timeout: 60)
        return files
    }

    func testDroppedImageLinkBecomesImageFile() {
        let files = importLink("/bild-ohne-typ")
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files.first.map { isImage($0.url) } ?? false, "Ein Link auf ein Bild wird zum Bild")
        XCTAssertEqual(files.first?.owned, true)
    }

    func testDroppedArchiveLinkBecomesWeblocQuickly() {
        let start = Date()
        let files = importLink("/archiv.zip")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.url.pathExtension, "webloc")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testStopRules() {
        func response(_ mime: String, length: Int = -1) -> URLResponse {
            URLResponse(url: URL(string: "https://x.invalid/a")!, mimeType: mime, expectedContentLength: length, textEncodingName: nil)
        }
        XCTAssertFalse(ContentImporter.shouldStopDownload(response: nil, received: 0))
        XCTAssertFalse(ContentImporter.shouldStopDownload(response: response("image/png", length: 900_000_000), received: 800_000_000))
        XCTAssertTrue(ContentImporter.shouldStopDownload(response: response("application/zip"), received: 1))
        XCTAssertTrue(ContentImporter.shouldStopDownload(response: response("video/mp4"), received: 1))
        XCTAssertFalse(ContentImporter.shouldStopDownload(response: response("application/octet-stream"), received: 1_000_000))
        XCTAssertTrue(ContentImporter.shouldStopDownload(response: response("application/octet-stream"), received: 31_000_000))
        XCTAssertTrue(ContentImporter.shouldStopDownload(response: response("application/octet-stream", length: 60_000_000), received: 1))
        XCTAssertFalse(ContentImporter.shouldStopDownload(response: response("text/html"), received: 200_000))
    }
}

/// Ein kleines, erfundenes Internet für die Tests. Große Antworten kommen in 1-MB-Stücken,
/// gezählt wird, wie viel davon tatsächlich abgenommen wurde.
final class FakeWeb: URLProtocol {
    static let host = "bardrop-test.invalid"
    private static let lock = NSLock()
    private static var _sent = 0
    static var bytesSent: Int { lock.lock(); defer { lock.unlock() }; return _sent }
    static func reset() { lock.lock(); _sent = 0; lock.unlock() }

    static func png(_ side: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<min(side, 64) { rep.setColor(.systemPink, atX: x, y: x) }
        return rep.representation(using: .png, properties: [:])!
    }

    /// Unkomprimiertes TIFF, damit ein Bild über 30 MB entsteht
    static func bigTIFF() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3_000, pixelsHigh: 3_000, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.tiffRepresentation(using: .none, factor: 0)!
    }

    private var stopped = false
    private let stateLock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (mime, body): (String, Data)
        switch path {
        case "/archiv.zip": (mime, body) = ("application/zip", Data(repeating: 0x50, count: 50_000_000))
        case "/gross.bin": (mime, body) = ("application/octet-stream", Data(repeating: 0x00, count: 50_000_000))
        case "/bild.png": (mime, body) = ("image/png", Self.png(32))
        case "/bild-ohne-typ": (mime, body) = ("application/octet-stream", Self.png(32))
        case "/grosses-bild.png": (mime, body) = ("image/tiff", Self.bigTIFF())
        case "/seite": (mime, body) = ("text/html", Data("<html><body>Hallo</body></html>".utf8))
        default: (mime, body) = ("text/plain", Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async {
            var offset = 0
            while offset < body.count {
                self.stateLock.lock(); let stop = self.stopped; self.stateLock.unlock()
                if stop { return }
                let end = min(offset + 1_000_000, body.count)
                self.client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                Self.lock.lock(); Self._sent += end - offset; Self.lock.unlock()
                offset = end
                usleep(10_000)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.lock(); stopped = true; stateLock.unlock()
    }
}
