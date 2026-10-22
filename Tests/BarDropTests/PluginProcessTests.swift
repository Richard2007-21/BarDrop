import XCTest
@testable import BarDrop

/// Programmstart für Plugins: Argumente wörtlich, Ausgabe, Rückgabewert, lange Zeilen
final class PluginProcessTests: XCTestCase {
    private func run(_ path: String, _ args: [String]) throws -> (code: Int32, stdout: String) {
        let out = Pipe(), err = Pipe()
        let process = PluginProcess(executable: URL(fileURLWithPath: path), arguments: args,
                                    environment: ["PATH": "/usr/bin:/bin"],
                                    directory: FileManager.default.temporaryDirectory,
                                    standardOutput: out, standardError: err)
        let done = expectation(description: "Ende")
        var code: Int32 = -1
        process.terminationHandler = { finished in
            code = finished.terminationStatus
            done.fulfill()
        }
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        wait(for: [done], timeout: 10)
        XCTAssertFalse(process.isRunning)
        return (code, String(decoding: data, as: UTF8.self))
    }

    /// Umlaute bleiben zusammengesetzt (Process zerlegte sie), nichts wird von einer Shell gedeutet
    func testArgumentsArePassedVerbatim() throws {
        let args = ["$HOME", "*", "a b", "'zitat'", "\"doppelt\"", "äöü 🎉", "--", "-n", "", ""]
        let result = try run("/usr/bin/printf", ["%s|"] + args)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stdout, args.joined(separator: "|") + "|")
        XCTAssertEqual(Array(result.stdout.utf8), Array((args.joined(separator: "|") + "|").utf8))
    }

    func testExitCodeAndSignal() throws {
        XCTAssertEqual(try run("/bin/sh", ["-c", "exit 3"]).code, 3)
        XCTAssertEqual(try run("/bin/sh", ["-c", "kill -9 $$"]).code, 9)
    }

    /// Lange Zeilen kommen in Stücken von höchstens 64 KB, nie mitten in einem Zeichen
    func testLongLinesAreSplitAt64KB() {
        let collector = OutputCollector()
        var lines: [String] = []
        let long = String(repeating: "ä", count: 100_000)   // 200 000 Bytes
        let data = Data((long + "\nkurz\n").utf8)
        // In ungleichen Stücken wie aus einer Pipe
        var offset = 0
        for size in [16_384, 81_920, 50_000, 1_000_000] where offset < data.count {
            let end = min(offset + size, data.count)
            collector.add(data.subdata(in: offset..<end), stderr: false) { lines.append($0) }
            offset = end
        }
        collector.flush { lines.append($0) }
        XCTAssertEqual(lines.last, "kurz")
        let parts = lines.dropLast()
        XCTAssertTrue(parts.allSatisfy { $0.utf8.count <= 64 * 1024 }, "\(parts.map(\.utf8.count))")
        XCTAssertEqual(parts.joined(), long)
    }
}
