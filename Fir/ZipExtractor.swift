import Compression
import Foundation

/// Minimal ZIP reader for add-on packages (.xpi): stored and deflated entries, no ZIP64 or encryption.
/// iOS has no public unzip API, and the manifest must be patched before WebKit reads it.
enum ZipExtractor {
    enum ZipError: Error {
        case malformed, unsupported(String)
    }

    /// Far above any real add-on; every size in the archive is the archive's own claim.
    private static let sizeLimit = 256 << 20

    static func extract(_ archive: URL, to destination: URL) throws {
        guard (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int ?? 0) <= sizeLimit else { throw ZipError.malformed }
        let data = try Data(contentsOf: archive)
        // The end-of-central-directory record sits in the last 64 KiB (its comment is at most that).
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        guard let end = data.range(of: Data(signature), options: .backwards, in: max(0, data.count - 65_557)..<data.count)?.lowerBound,
              end + 22 <= data.count else { throw ZipError.malformed }
        let count = Int(data.uint16(at: end + 10))
        var offset = Int(data.uint32(at: end + 16))
        var total = 0

        for _ in 0..<count {
            guard offset + 46 <= data.count, data.uint32(at: offset) == 0x0201_4b50 else { throw ZipError.malformed }
            let method = data.uint16(at: offset + 10)
            let compressedSize = Int(data.uint32(at: offset + 20))
            let size = Int(data.uint32(at: offset + 24))
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            let localOffset = Int(data.uint32(at: offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw ZipError.malformed }
            let name = String(decoding: data[offset + 46 ..< offset + 46 + nameLength], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            // Reject paths that would land outside the destination.
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw ZipError.malformed }
            let target = destination.appending(path: name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            total += size
            // A stored entry writes its body, so the size counted has to be the size written.
            guard total <= sizeLimit, method != 0 || compressedSize == size, localOffset + 30 <= data.count else { throw ZipError.malformed }
            let start = localOffset + 30 + Int(data.uint16(at: localOffset + 26)) + Int(data.uint16(at: localOffset + 28))
            guard start + compressedSize <= data.count else { throw ZipError.malformed }
            let body = data[start ..< start + compressedSize]
            let contents: Data
            switch method {
            case 0: contents = Data(body)
            case 8: contents = try inflate(Data(body), size: size)
            default: throw ZipError.unsupported("compression method \(method)")
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target)
        }
    }

    /// COMPRESSION_ZLIB is raw DEFLATE, which is what ZIP stores.
    private static func inflate(_ input: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard !input.isEmpty else { throw ZipError.malformed }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          inp.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.malformed }
        return output
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }
}
