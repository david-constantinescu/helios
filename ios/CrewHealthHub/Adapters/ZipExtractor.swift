import Foundation
import Compression

/// Minimal streaming ZIP reader for Apple Health exports (`export.zip`).
/// Uses the central directory (exports may use data descriptors, so local headers can carry zero sizes),
/// supports Zip64 (an `export.xml` can exceed 4 GB) and inflates in 1 MB chunks, never loading the file into memory.
enum ZipExtractor {
    struct Entry: Hashable {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let size: UInt64
        let localHeaderOffset: UInt64
    }

    enum ZipError: Error, LocalizedError {
        case notZip, unsupported(String), corrupt(String), notFound
        var errorDescription: String? {
            switch self {
            case .notZip: return "That file isn't a zip archive."
            case .unsupported(let s): return "Unsupported zip feature: \(s)."
            case .corrupt(let s): return "The archive looks damaged (\(s))."
            case .notFound: return "No export.xml inside — is this an Apple Health export?"
            }
        }
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[d.startIndex + o + $1]) << (8 * UInt32($1)) } }
    private static func u64(_ d: Data, _ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[d.startIndex + o + $1]) << (8 * UInt64($1)) } }

    private static func read(_ h: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try h.seek(toOffset: offset)
        return try h.read(upToCount: count) ?? Data()
    }

    static func entries(of url: URL) throws -> [Entry] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = try h.seekToEnd()
        guard size >= 22 else { throw ZipError.notZip }
        // End of central directory: within the last 64 KB + 22 bytes.
        let tailLen = UInt64(min(Int(size), 65_557))
        let tail = try read(h, at: size - tailLen, count: Int(tailLen))
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 { if u32(tail, i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw ZipError.notZip }
        var cdSize = UInt64(u32(tail, eocd + 12)), cdOffset = UInt64(u32(tail, eocd + 16)), count = UInt64(u16(tail, eocd + 10))
        // Zip64: locator sits 20 bytes before the EOCD.
        if eocd >= 20, u32(tail, eocd - 20) == 0x07064b50 {
            let z64Offset = u64(tail, eocd - 20 + 8)
            let z = try read(h, at: z64Offset, count: 56)
            guard z.count == 56, u32(z, 0) == 0x06064b50 else { throw ZipError.corrupt("zip64 record") }
            count = u64(z, 32); cdSize = u64(z, 40); cdOffset = u64(z, 48)
        }
        guard cdOffset + cdSize <= size else { throw ZipError.corrupt("central directory") }
        let cd = try read(h, at: cdOffset, count: Int(cdSize))
        var out: [Entry] = []
        var p = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x02014b50, out.count < Int(min(count, 1_000_000)) {
            let method = u16(cd, p + 10)
            var comp = UInt64(u32(cd, p + 20)), uncomp = UInt64(u32(cd, p + 24))
            let nameLen = Int(u16(cd, p + 28)), extraLen = Int(u16(cd, p + 30)), commentLen = Int(u16(cd, p + 32))
            var local = UInt64(u32(cd, p + 42))
            guard p + 46 + nameLen + extraLen <= cd.count else { throw ZipError.corrupt("entry") }
            let name = String(decoding: cd[(cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen)], as: UTF8.self)
            // Zip64 extra field: values appear only for the fields that overflowed, in this order.
            var e = p + 46 + nameLen
            let eEnd = e + extraLen
            while e + 4 <= eEnd {
                let tag = u16(cd, e), len = Int(u16(cd, e + 2))
                if tag == 0x0001 {
                    var q = e + 4
                    if uncomp == 0xFFFF_FFFF, q + 8 <= e + 4 + len { uncomp = u64(cd, q); q += 8 }
                    if comp == 0xFFFF_FFFF, q + 8 <= e + 4 + len { comp = u64(cd, q); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= e + 4 + len { local = u64(cd, q); q += 8 }
                }
                e += 4 + len
            }
            out.append(Entry(name: name, method: method, compressedSize: comp, size: uncomp, localHeaderOffset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    /// Streams one entry to `destination`. `progress` receives 0…1.
    static func extract(_ entry: Entry, from url: URL, to destination: URL, progress: ((Double) -> Void)? = nil,
                        isCancelled: () -> Bool = { false }) throws {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let lh = try read(h, at: entry.localHeaderOffset, count: 30)
        guard lh.count == 30, u32(lh, 0) == 0x04034b50 else { throw ZipError.corrupt("local header") }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(u16(lh, 26)) + UInt64(u16(lh, 28))
        try h.seek(toOffset: dataStart)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        let chunk = 1 << 20
        var remaining = entry.compressedSize

        if entry.method == 0 {
            while remaining > 0 {
                if isCancelled() { throw CancellationError() }
                let d = try h.read(upToCount: Int(min(UInt64(chunk), remaining))) ?? Data()
                guard !d.isEmpty else { throw ZipError.corrupt("truncated") }
                try out.write(contentsOf: d); remaining -= UInt64(d.count)
                progress?(1 - Double(remaining) / Double(max(entry.compressedSize, 1)))
            }
            return
        }
        guard entry.method == 8 else { throw ZipError.unsupported("compression method \(entry.method)") }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        // COMPRESSION_ZLIB in Apple's Compression framework is raw DEFLATE (RFC 1951) — what zip uses.
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.unsupported("inflate")
        }
        defer { compression_stream_destroy(stream) }
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var finished = false
        while !finished {
            if isCancelled() { throw CancellationError() }
            let input = remaining > 0 ? (try h.read(upToCount: Int(min(UInt64(chunk), remaining))) ?? Data()) : Data()
            if remaining > 0 && input.isEmpty { throw ZipError.corrupt("truncated") }
            remaining -= UInt64(input.count)
            let flags = Int32(remaining == 0 ? COMPRESSION_STREAM_FINALIZE.rawValue : 0)
            try input.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = buf.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
                stream.pointee.src_size = input.count
                var produced = 0
                repeat {
                    stream.pointee.dst_ptr = dst
                    stream.pointee.dst_size = chunk
                    let status = compression_stream_process(stream, flags)
                    produced = chunk - stream.pointee.dst_size
                    if produced > 0 { try out.write(contentsOf: Data(bytesNoCopy: dst, count: produced, deallocator: .none)) }
                    switch status {
                    case COMPRESSION_STATUS_END: finished = true
                    case COMPRESSION_STATUS_OK: break
                    default: throw ZipError.corrupt("inflate")
                    }
                    if finished { break }
                    // The decoder returns output in blocks and may report OK with a partly filled buffer
                    // while more is pending, so when finalizing keep draining until it stops producing.
                } while stream.pointee.src_size > 0 || stream.pointee.dst_size == 0 || (flags != 0 && produced > 0)
            }
            if remaining == 0 && !finished && input.isEmpty { throw ZipError.corrupt("unexpected end") }
            progress?(1 - Double(remaining) / Double(max(entry.compressedSize, 1)))
        }
    }

    /// Finds `export.xml` (not `export_cda.xml`) inside an Apple Health export and extracts it to a temp file.
    static func extractHealthExport(from zip: URL, progress: ((Double) -> Void)? = nil, isCancelled: () -> Bool = { false }) throws -> URL {
        let all = try entries(of: zip)
        guard let e = all.first(where: { $0.name == "export.xml" || $0.name.hasSuffix("/export.xml") }) else { throw ZipError.notFound }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("health-export-\(UUID().uuidString).xml")
        try extract(e, from: zip, to: dest, progress: progress, isCancelled: isCancelled)
        return dest
    }
}
