import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import BarDrop

/// Prüft, dass alles, was in die Ablage kommt, als echte, lesbare Datei dort landet
/// und auch dann noch existiert, wenn die Quelle sie gelöscht hat.
final class ImportTests: XCTestCase {
    private var root: URL!
    private var importer: ContentImporter!
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        importer = ContentImporter(storage: root.appendingPathComponent("Items"), convertImages: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("BarDropTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Hilfen

    private func pngData(width: Int = 8, height: Int = 6) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<height { rep.setColor(.systemRed, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    private func tiffData() -> Data {
        NSBitmapImageRep(data: pngData())!.tiffRepresentation!
    }

    private func importSync(timeout: TimeInterval = 10) -> [ShelfFile] {
        let done = expectation(description: "Import")
        var result: [ShelfFile] = []
        importer.importContent(of: pasteboard) { files in
            result = files
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        return result
    }

    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertNoThrow(try data.write(to: url))
    }

    private func isImage(_ url: URL) -> Bool { ImporterChecks.isReadableImage(url) }

    // MARK: Dateien

    func testUserFileIsReferencedNotCopied() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("BarDropTestFiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Notiz.txt")
        write(Data("Hallo".utf8), to: file)

        pasteboard.writeObjects([file as NSURL])
        let files = importSync()

        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].owned, "Dateien des Nutzers werden nur referenziert")
        XCTAssertEqual(files[0].url.standardizedFileURL, file.standardizedFileURL)
    }

    func testAlwaysCopyCopiesUserFilesUnchanged() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("BarDropTestFiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Foto.tiff")
        write(tiffData(), to: file)

        importer.alwaysCopy = true
        pasteboard.writeObjects([file as NSURL])
        let files = importSync()
        try? FileManager.default.removeItem(at: folder)

        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].owned, "Mit „Immer eine Kopie“ wird auch die eigene Datei kopiert")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].url.path), "Kopie bleibt nach Löschen des Originals")
        XCTAssertEqual(files[0].url.pathExtension, "tiff", "Eigene Dateien werden nicht umgewandelt")
    }

    func testTemporaryFileIsCopiedAndSurvivesDeletion() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("drag-\(UUID().uuidString).png")
        write(pngData(), to: temp)

        pasteboard.writeObjects([temp as NSURL])
        let files = importSync()
        try? FileManager.default.removeItem(at: temp)   // Quelle räumt auf, wie Browser es tun

        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].owned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].url.path), "Kopie muss bleiben")
        XCTAssertTrue(isImage(files[0].url))
    }

    func testFileFromAppContainerIsCopied() {
        // So legen Safari und andere Apps beim Ziehen Bilder ab
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/BarDropTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let file = container.appendingPathComponent("Data/tmp/Bild.png")
        write(pngData(), to: file)

        pasteboard.writeObjects([file as NSURL])
        let files = importSync()
        try? FileManager.default.removeItem(at: container)

        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].owned, "Dateien aus fremden App-Containern müssen kopiert werden")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].url.path))
        XCTAssertTrue(isImage(files[0].url))
    }

    func testForeignMetadataIsDroppedButQuarantineKept() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("safari-\(UUID().uuidString).png")
        write(pngData(), to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        // Wie bei Browser-Dateien: fremde Metadaten plus Quarantäne-Markierung
        FileSanitizer.writeAttribute("com.example.foreign", value: Data("x".utf8), to: temp)
        FileSanitizer.writeAttribute("com.apple.quarantine", value: Data("0083;00000000;Safari;".utf8), to: temp)
        XCTAssertTrue(FileSanitizer.attributeNames(of: temp).contains("com.example.foreign"))

        pasteboard.writeObjects([temp as NSURL])
        let files = importSync()

        XCTAssertEqual(files.count, 1)
        let names = FileSanitizer.attributeNames(of: files[0].url)
        XCTAssertFalse(names.contains("com.example.foreign"), "Fremde Metadaten dürfen nicht mitkommen: \(names)")
        XCTAssertTrue(names.contains("com.apple.quarantine"), "Quarantäne bleibt zum Schutz erhalten")
        let perms = (try? FileManager.default.attributesOfItem(atPath: files[0].url.path)[.posixPermissions]) as? Int
        XCTAssertEqual(perms, 0o644)
        XCTAssertTrue(isImage(files[0].url))
    }

    func testIsUserFileRules() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(ContentImporter.isUserFile(home.appendingPathComponent("Desktop/a.png")))
        XCTAssertTrue(ContentImporter.isUserFile(home.appendingPathComponent("Documents/x/b.pdf")))
        XCTAssertFalse(ContentImporter.isUserFile(home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/tmp/c.jpg")))
        XCTAssertFalse(ContentImporter.isUserFile(home.appendingPathComponent("Library/Caches/d.png")))
        XCTAssertFalse(ContentImporter.isUserFile(URL(fileURLWithPath: "/private/var/folders/ab/T/e.png")))
        XCTAssertFalse(ContentImporter.isUserFile(FileManager.default.temporaryDirectory.appendingPathComponent("f.png")))
        // iCloud Drive und Cloud-Anbieter liegen in ~/Library, gehören aber dem Nutzer
        XCTAssertTrue(ContentImporter.isUserFile(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/g.pdf")))
        XCTAssertTrue(ContentImporter.isUserFile(home.appendingPathComponent("Library/CloudStorage/Dropbox/h.pdf")))
    }

    func testObjectImageWithoutRawDataIsSaved() {
        // Ein PDF-Bildobjekt ohne PNG/JPEG-Daten (z. B. aus Vorschau)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 10, height: 10)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(box)
        ctx.endPDFPage()
        ctx.closePDF()
        pasteboard.setData(data as Data, forType: .pdf)

        let files = importSync()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(isImage(files[0].url), "Bildobjekt wird als Bild gespeichert")
    }

    // MARK: Bilddaten

    func testPNGDataBecomesImageFile() {
        pasteboard.setData(pngData(), forType: NSPasteboard.PasteboardType("public.png"))
        let files = importSync()

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].url.pathExtension, "png")
        XCTAssertTrue(isImage(files[0].url))
    }

    func testTIFFDataBecomesCompatibleImage() {
        pasteboard.setData(tiffData(), forType: .tiff)
        let files = importSync()

        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(["png", "jpg"].contains(files[0].url.pathExtension), "TIFF wird in PNG/JPEG umgewandelt")
        XCTAssertTrue(isImage(files[0].url))
    }

    func testWrongAndMissingExtensionsAreFixed() {
        let wrong = FileManager.default.temporaryDirectory.appendingPathComponent("foto-\(UUID().uuidString).jpg")
        let none = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
        write(pngData(), to: wrong)
        write(pngData(), to: none)
        defer {
            try? FileManager.default.removeItem(at: wrong)
            try? FileManager.default.removeItem(at: none)
        }

        pasteboard.writeObjects([wrong as NSURL, none as NSURL])
        let files = importSync()

        XCTAssertEqual(files.count, 2)
        for file in files {
            XCTAssertEqual(file.url.pathExtension, "png", "Endung passt zum echten Format: \(file.url.lastPathComponent)")
            XCTAssertTrue(isImage(file.url))
        }
    }

    func testHTMLImageSourceIsFound() {
        let html = #"<meta charset="utf-8"><img alt="x" src="https://example.com/a/b.webp?w=800&amp;h=600">"#
        let url = PasteboardSnapshot.imageSource(in: html, relativeTo: nil)
        XCTAssertEqual(url?.absoluteString, "https://example.com/a/b.webp?w=800&h=600")

        let relative = PasteboardSnapshot.imageSource(in: #"<img src="/img/c.png">"#,
                                                      relativeTo: URL(string: "https://example.com/page"))
        XCTAssertEqual(relative?.absoluteString, "https://example.com/img/c.png")
    }

    // MARK: Herunterladen (Netzwerk)

    private func requireNetwork(_ url: URL) throws {
        let done = expectation(description: "Netz")
        var ok = false
        URLSession.shared.dataTask(with: url) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        if !ok { throw XCTSkip("Kein Netzwerk für \(url)") }
    }

    func testImageURLWithoutExtensionIsDownloaded() throws {
        let url = URL(string: "https://avatars.githubusercontent.com/u/9919?s=40")!
        try requireNetwork(url)

        let done = expectation(description: "Download")
        var result: URL?
        importer.download(url) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)

        let file = try XCTUnwrap(result, "Bild hinter einer Adresse ohne Endung muss als Datei ankommen")
        XCTAssertTrue(["png", "jpg", "gif"].contains(file.pathExtension), "Endung aus dem MIME-Typ: \(file.lastPathComponent)")
        XCTAssertTrue(isImage(file))
    }

    func testDraggedWebImageWithURLOnlyBecomesFile() throws {
        let url = URL(string: "https://avatars.githubusercontent.com/u/9919?s=40")!
        try requireNetwork(url)

        pasteboard.writeObjects([url as NSURL])
        let files = importSync(timeout: 30)

        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(isImage(files[0].url), "Ein Link auf ein Bild wird zum Bild, nicht zum Lesezeichen")
    }

    func testPageLinkBecomesWebloc() throws {
        let url = URL(string: "https://example.com/")!
        try requireNetwork(url)

        pasteboard.writeObjects([url as NSURL])
        let files = importSync(timeout: 30)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].url.pathExtension, "webloc")
    }

    // MARK: Herausziehen

    func testImportedFileCanBeDraggedOutAsFile() {
        pasteboard.setData(pngData(), forType: NSPasteboard.PasteboardType("public.png"))
        let file = importSync()[0].url

        // Genau so schreibt BarDrop beim Herausziehen auf das Drag-Pasteboard
        let out = NSPasteboard(name: NSPasteboard.Name("BarDropOut-\(UUID().uuidString)"))
        defer { out.releaseGlobally() }
        out.clearContents()
        out.writeObjects([file as NSURL])

        let read = out.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(read?.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: read![0].path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: read![0].path))
    }
}

/// Ablage: Speichern, Neustart, Stapel.
final class StoreTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropStore-\(UUID().uuidString)")
        AppSettings.shared.stackMultiple = true
        AppSettings.shared.stackThreshold = 2
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func ingest(_ store: ShelfStore, _ configure: (NSPasteboard) -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropStoreTest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        configure(pb)
        let done = expectation(description: "Ingest")
        store.ingest(from: pb) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func testOwnedFilesSurviveRestart() {
        let store = ShelfStore(baseDirectory: base)
        ingest(store) { $0.setString("Ein kleiner Text", forType: .string) }
        XCTAssertEqual(store.entries.count, 1)
        let url = store.entries[0].files[0].url

        // Neustart: Liste wird geladen, verwaiste Dateien werden aufgeräumt
        let reloaded = ShelfStore(baseDirectory: base)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Gespeicherte Datei darf beim Start nicht gelöscht werden")
    }

    func testStackThreshold() {
        let folder = base.appendingPathComponent("src")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (1...3).map { i -> URL in
            let u = folder.appendingPathComponent("datei\(i).txt")
            try? Data("\(i)".utf8).write(to: u)
            return u
        }

        AppSettings.shared.stackThreshold = 3
        let store = ShelfStore(baseDirectory: base.appendingPathComponent("a"))
        ingest(store) { $0.writeObjects(Array(urls.prefix(2)) as [NSURL]) }
        XCTAssertEqual(store.entries.count, 2, "Unter der Schwelle: einzelne Einträge")

        let store2 = ShelfStore(baseDirectory: base.appendingPathComponent("b"))
        ingest(store2) { $0.writeObjects(urls as [NSURL]) }
        XCTAssertEqual(store2.entries.count, 1, "Ab der Schwelle: ein Stapel")
        XCTAssertEqual(store2.entries[0].files.count, 3)
    }

    func testDropOntoTileBuildsStack() {
        let store = ShelfStore(baseDirectory: base)
        ingest(store) { $0.setString("eins", forType: .string) }
        let target = store.entries[0].id
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropStoreTest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("zwei", forType: .string)
        let done = expectation(description: "Ingest")
        store.ingest(from: pb, into: target) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(store.entries[0].isStack)
    }
}
