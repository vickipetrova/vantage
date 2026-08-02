import XCTest
@testable import VantageCore

/// The gzip reader is hand-written, so it's tested against files produced by the real `gzip` —
/// including the flag combinations Apple's servers might or might not set. A decoder that works on
/// its own output and nothing else would be worse than useless here.
final class GunzipTests: XCTestCase {
    /// Compresses with the system gzip, so the fixtures are real gzip containers rather than
    /// something this test suite invented.
    private func systemGzip(_ text: String, arguments: [String] = []) throws -> Data {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("report.tsv")
        try text.write(to: source, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = arguments + ["-k", source.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        return try Data(contentsOf: directory.appendingPathComponent("report.tsv.gz"))
    }

    private func roundTrip(_ text: String, arguments: [String] = []) throws -> String {
        let compressed = try systemGzip(text, arguments: arguments)
        XCTAssertTrue(Gunzip.isGzip(compressed))
        return String(data: try Gunzip.decompress(compressed), encoding: .utf8) ?? ""
    }

    func testRoundTripsASmallReport() throws {
        let tsv = "Provider\tTitle\tUnits\nAPPLE\tApp One\t100\n"
        XCTAssertEqual(try roundTrip(tsv), tsv)
    }

    /// gzip's `-N` stores the original filename, setting FNAME — the header stops being a fixed ten
    /// bytes, which is the part hand-written readers get wrong.
    func testRoundTripsWithAFilenameInTheHeader() throws {
        let tsv = "Provider\tTitle\tUnits\nAPPLE\tApp Two\t7\n"
        XCTAssertEqual(try roundTrip(tsv, arguments: ["-N"]), tsv)
    }

    /// Big enough to need several passes through the 64 KB output buffer, and repetitive enough
    /// that the compressed form is far smaller than the ISIZE hint.
    func testRoundTripsAReportLargerThanTheOutputBuffer() throws {
        let row = "APPLE\tUS\tSKU\tDev\tApp One\t1.0\t1F\t3\t0.70\tUSD\n"
        let tsv = String(repeating: row, count: 20_000)
        let restored = try roundTrip(tsv)
        XCTAssertEqual(restored.count, tsv.count)
        XCTAssertEqual(restored, tsv)
    }

    func testRoundTripsAnEmptyPayload() throws {
        XCTAssertEqual(try roundTrip(""), "")
    }

    func testRoundTripsMultibyteText() throws {
        // App titles are not ASCII, and a byte-length bug shows up as a checksum failure here.
        let tsv = "Title\tUnits\n日本語アプリ\t12\nCafé Ordering\t3\n"
        XCTAssertEqual(try roundTrip(tsv), tsv)
    }

    // MARK: - Rejection

    func testRejectsNonGzipData() {
        // What an error response actually looks like: JSON, not a report.
        let json = Data(#"{"errors":[{"status":"404"}]}"#.utf8)
        XCTAssertFalse(Gunzip.isGzip(json))
        XCTAssertThrowsError(try Gunzip.decompress(json)) { error in
            XCTAssertEqual(error as? Gunzip.Failure, .notGzip)
        }
    }

    func testRejectsLongNonGzipData() {
        let data = Data(repeating: 0x41, count: 100)
        XCTAssertThrowsError(try Gunzip.decompress(data)) { error in
            XCTAssertEqual(error as? Gunzip.Failure, .notGzip)
        }
    }

    func testRejectsATruncatedReport() throws {
        let compressed = try systemGzip("Title\tUnits\nApp One\t100\n")
        let cut = compressed.prefix(compressed.count - 4)
        XCTAssertThrowsError(try Gunzip.decompress(Data(cut)))
    }

    /// A report that arrives corrupted must be refused, not parsed. Numbers from a damaged file
    /// would look perfectly plausible.
    func testRejectsACorruptedPayload() throws {
        var compressed = [UInt8](try systemGzip("Title\tUnits\nApp One\t100\n"))
        compressed[compressed.count - 6] ^= 0xFF  // inside the deflate stream, before the trailer
        XCTAssertThrowsError(try Gunzip.decompress(Data(compressed)))
    }

    func testIsGzipNeedsTwoBytes() {
        XCTAssertFalse(Gunzip.isGzip(Data()))
        XCTAssertFalse(Gunzip.isGzip(Data([0x1f])))
        XCTAssertTrue(Gunzip.isGzip(Data([0x1f, 0x8b, 0x08])))
    }

    // MARK: - CRC32

    func testCRC32MatchesTheKnownVector() {
        // The standard check value: CRC-32 of "123456789".
        XCTAssertEqual(Gunzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}
