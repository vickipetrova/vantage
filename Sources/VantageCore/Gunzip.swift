import Compression
import Foundation

/// Decompresses the gzip file Apple returns, in-process and without dependencies.
///
/// Apple's Compression framework documents its `zlib` algorithm as "the raw `DEFLATE` format", so
/// it can't be handed a gzip container directly: the header has to come off first and the trailer
/// has to be checked afterwards. That's this file.
///
/// The alternative — piping the response through `/usr/bin/gunzip` — is fewer lines and puts a day
/// of someone's sales figures through a subprocess's stdout, where it can end up in a crash log or
/// be read by anything watching the process tree. Not worth the lines saved.
public enum Gunzip {
    public enum Failure: Error, Equatable {
        case notGzip
        case truncated
        case unsupportedFlags
        case inflateFailed
        /// The data decompressed, but its checksum or length doesn't match the trailer — so it is
        /// not the file Apple sent. Better to report nothing than to parse a corrupted report.
        case checksumMismatch
    }

    /// Every gzip member starts `1f 8b`. Used to tell a report from a JSON error body without
    /// trusting a `Content-Type` header.
    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    public static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18 else { throw Failure.truncated }  // header + trailer, empty payload
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else { throw Failure.notGzip }
        guard bytes[2] == 8 else { throw Failure.unsupportedFlags }  // CM=8 is DEFLATE; nothing else exists

        // RFC 1952 §2.3: fixed 10-byte header, then optional fields announced by the flag byte.
        let flags = bytes[3]
        var cursor = 10

        if flags & 0b0000_0100 != 0 {  // FEXTRA: two-byte length, then that many bytes.
            guard cursor + 2 <= bytes.count else { throw Failure.truncated }
            let extra = Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8
            cursor += 2 + extra
        }
        if flags & 0b0000_1000 != 0 { cursor = try skipCString(bytes, from: cursor) }  // FNAME
        if flags & 0b0001_0000 != 0 { cursor = try skipCString(bytes, from: cursor) }  // FCOMMENT
        if flags & 0b0000_0010 != 0 { cursor += 2 }                                    // FHCRC

        // The last 8 bytes are CRC32 then ISIZE, little-endian. Everything between is the DEFLATE
        // stream.
        let trailerStart = bytes.count - 8
        guard cursor < trailerStart else { throw Failure.truncated }
        let deflated = Data(bytes[cursor..<trailerStart])

        let inflated = try inflate(deflated, hint: expectedSize(bytes))
        guard crc32(inflated) == readUInt32(bytes, at: trailerStart),
              UInt32(truncatingIfNeeded: inflated.count) == readUInt32(bytes, at: trailerStart + 4)
        else { throw Failure.checksumMismatch }
        return inflated
    }

    // MARK: - Header helpers

    private static func skipCString(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard index < bytes.count else { throw Failure.truncated }
        return index + 1  // step past the terminating zero
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    /// ISIZE is the uncompressed size modulo 2^32 — a good buffer hint, and a useless one for
    /// anything over 4 GB. A daily sales report is never close, but the clamp keeps a corrupt
    /// trailer from asking for an absurd allocation.
    private static func expectedSize(_ bytes: [UInt8]) -> Int {
        let size = Int(readUInt32(bytes, at: bytes.count - 4))
        return max(64 * 1024, min(size, 64 * 1024 * 1024))
    }

    // MARK: - Inflate

    private static func inflate(_ data: Data, hint: Int) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!, dst_size: 0,
            src_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else { throw Failure.inflateFailed }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data(capacity: hint)
        var thrown: Error?

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                thrown = Failure.truncated
                return
            }
            stream.src_ptr = base
            stream.src_size = data.count

            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                switch compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)) {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    output.append(buffer, count: bufferSize - stream.dst_size)
                    if stream.dst_size != 0 { return }  // drained: OK means "needs more input"
                default:
                    thrown = Failure.inflateFailed
                    return
                }
            } while true
        }

        if let thrown { throw thrown }
        return output
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// Standard CRC-32 (the one gzip uses). Written out rather than reaching for libz, which would
    /// mean a system-library target for twenty lines of arithmetic.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
