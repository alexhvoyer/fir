import Compression
import Foundation
import Testing

/// Add-on packages come from the network, so every check here is a hostile archive.
@Suite final class ZipExtractorTests {
    let root: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        destination = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func extractsStoredAndDeflatedFiles() throws {
        let text = Data(String(repeating: "manifest ", count: 200).utf8)
        try extract(Zip(entries: [
            .init(name: "manifest.json", body: Data("{}".utf8)),
            .init(name: "icons/", body: Data()),
            .init(name: "js/deep/app.js", body: text, deflate: true),
        ]).data)
        #expect(try Data(contentsOf: destination.appending(path: "manifest.json")) == Data("{}".utf8))
        #expect(try Data(contentsOf: destination.appending(path: "js/deep/app.js")) == text)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "icons").path))
    }

    @Test(arguments: ["../evil.js", "/evil.js", "a/../../evil.js", "a/b/../../../evil.js", "../dir/", "a/.."])
    func rejectsPathsOutsideTheDestination(_ name: String) throws {
        #expect(throws: ZipExtractor.ZipError.self) {
            try extract(Zip(entries: [.init(name: name, body: Data("x".utf8))]).data)
        }
        #expect(try onlyDestinationInRoot())
    }

    @Test func rejectsStoredEntryLargerThanItsBody() {
        var zip = Zip(entries: [.init(name: "a.js", body: Data("abc".utf8))])
        zip.entries[0].claimedSize = 1 << 20
        #expect(throws: ZipExtractor.ZipError.self) { try extract(zip.data) }
    }

    @Test func rejectsClaimedSizesAboveTheLimit() {
        var zip = Zip(entries: [.init(name: "a.js", body: Data("abc".utf8), deflate: true)])
        zip.entries[0].claimedSize = 300 << 20
        #expect(throws: ZipExtractor.ZipError.self) { try extract(zip.data) }
    }

    @Test func rejectsManySmallEntriesAddingUpPastTheLimit() {
        var zip = Zip(entries: (0..<3).map { .init(name: "\($0).js", body: Data("abc".utf8), deflate: true) })
        for index in zip.entries.indices { zip.entries[index].claimedSize = 100 << 20 }
        #expect(throws: ZipExtractor.ZipError.self) { try extract(zip.data) }
    }

    @Test func rejectsBodyRunningPastTheEnd() {
        var zip = Zip(entries: [.init(name: "a.js", body: Data("abc".utf8))])
        zip.entries[0].claimedCompressedSize = 1 << 20
        zip.entries[0].claimedSize = 1 << 20
        #expect(throws: ZipExtractor.ZipError.self) { try extract(zip.data) }
    }

    @Test func rejectsLocalHeaderOutsideTheArchive() {
        var zip = Zip(entries: [.init(name: "a.js", body: Data("abc".utf8))])
        zip.entries[0].claimedLocalOffset = 0xFFFF_FF00
        #expect(throws: ZipExtractor.ZipError.self) { try extract(zip.data) }
    }

    @Test func rejectsCentralDirectoryOutsideTheArchive() {
        var zip = Zip(entries: [.init(name: "a.js", body: Data("abc".utf8))])
        zip.claimedDirectoryOffset = 0xFFFF_FF00
        #expect(throws: ZipExtractor.ZipError.self) { try extract(zip.data) }
    }

    @Test func rejectsMoreEntriesThanTheDirectoryHolds() {
        var zip = Zip(entries: [.init(name: "a.js", body: Data("abc".utf8))])
        zip.claimedCount = 500
        #expect(throws: ZipExtractor.ZipError.self) { try extract(zip.data) }
    }

    @Test func rejectsGarbageDeflateStream() {
        var zip = Zip(entries: [.init(name: "a.js", body: Data(repeating: 0xFF, count: 64))])
        zip.entries[0].method = 8
        zip.entries[0].claimedSize = 4096
        #expect(throws: ZipExtractor.ZipError.self) { try extract(zip.data) }
    }

    @Test func rejectsUnknownCompression() {
        var zip = Zip(entries: [.init(name: "a.js", body: Data("abc".utf8))])
        zip.entries[0].method = 14
        #expect(throws: ZipExtractor.ZipError.self) { try extract(zip.data) }
    }

    @Test func rejectsFilesThatAreNotArchives() {
        #expect(throws: ZipExtractor.ZipError.self) { try extract(Data()) }
        #expect(throws: ZipExtractor.ZipError.self) { try extract(Data("not a zip".utf8)) }
    }

    @Test func survivesEveryTruncation() throws {
        let data = Zip(entries: [
            .init(name: "manifest.json", body: Data("{}".utf8)),
            .init(name: "app.js", body: Data(String(repeating: "x", count: 300).utf8), deflate: true),
        ]).data
        for length in 0..<data.count {
            _ = try? extract(data.prefix(length))
            #expect(try onlyDestinationInRoot())
        }
    }

    /// A trap on a bad index would crash the app; a fixed seed keeps failures reproducible.
    @Test func survivesRandomCorruption() throws {
        let data = Zip(entries: [
            .init(name: "manifest.json", body: Data("{}".utf8)),
            .init(name: "js/app.js", body: Data(String(repeating: "abc", count: 100).utf8), deflate: true),
        ]).data
        var random = SeededRandom(seed: 42)
        for _ in 0..<2000 {
            var bytes = [UInt8](data)
            for _ in 0..<Int.random(in: 1...6, using: &random) {
                bytes[Int.random(in: 0..<bytes.count, using: &random)] = .random(in: 0...255, using: &random)
            }
            _ = try? extract(Data(bytes))
            #expect(try onlyDestinationInRoot())
        }
    }

    // MARK: - Helpers

    private func extract(_ data: Data) throws {
        let archive = root.appending(path: "package.xpi")
        try data.write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        try ZipExtractor.extract(archive, to: destination)
    }

    private func onlyDestinationInRoot() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "package.xpi" } == ["out"]
    }
}

/// Writes a ZIP whose header fields can lie about the data that follows.
struct Zip {
    struct Entry {
        var name: String
        var body: Data
        var method: UInt16
        var claimedSize: Int?
        var claimedCompressedSize: Int?
        var claimedLocalOffset: Int?
        let uncompressedSize: Int

        init(name: String, body: Data, deflate: Bool = false) {
            self.name = name
            uncompressedSize = body.count
            method = deflate ? 8 : 0
            self.body = deflate ? Self.deflate(body) : body
        }

        private static func deflate(_ input: Data) -> Data {
            var output = Data(count: input.count + 64)
            let written = output.withUnsafeMutableBytes { out in
                input.withUnsafeBytes { inp in
                    compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                                              inp.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            return output.prefix(written)
        }
    }

    var entries: [Entry]
    var claimedDirectoryOffset: Int?
    var claimedCount: Int?

    var data: Data {
        var out = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let offset = out.count
            let compressed = entry.claimedCompressedSize ?? entry.body.count
            let size = entry.claimedSize ?? entry.uncompressedSize
            out.le32(0x0403_4b50); out.le16(20); out.le16(0); out.le16(entry.method)
            out.le32(0); out.le32(0); out.le32(compressed); out.le32(size)
            out.le16(name.count); out.le16(0)
            out.append(name); out.append(entry.body)

            directory.le32(0x0201_4b50); directory.le16(20); directory.le16(20); directory.le16(0)
            directory.le16(entry.method); directory.le32(0); directory.le32(0)
            directory.le32(compressed); directory.le32(size)
            directory.le16(name.count); directory.le16(0); directory.le16(0); directory.le16(0); directory.le16(0)
            directory.le32(0); directory.le32(entry.claimedLocalOffset ?? offset)
            directory.append(name)
        }
        let directoryOffset = out.count
        out.append(directory)
        out.le32(0x0605_4b50); out.le16(0); out.le16(0)
        out.le16(claimedCount ?? entries.count); out.le16(claimedCount ?? entries.count)
        out.le32(directory.count); out.le32(claimedDirectoryOffset ?? directoryOffset); out.le16(0)
        return out
    }
}

private extension Data {
    mutating func le16(_ value: Int) { append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
    mutating func le16(_ value: UInt16) { le16(Int(value)) }
    mutating func le32(_ value: Int) { le16(value & 0xFFFF); le16(value >> 16 & 0xFFFF) }
}

/// SplitMix64, so the corruption test hits the same bytes on every run.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
