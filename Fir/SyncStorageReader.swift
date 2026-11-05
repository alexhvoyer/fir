import Foundation
import CryptoKit
import CommonCrypto
import MozillaAppServices

/// Firefox Sync 1.5 client for collections application-services does not expose, such as Zen's
/// "spaces": reads them, and uploads single records. Spec: https://mozilla-services.readthedocs.io/en/latest/storage/apis-1.5.html
struct SyncStorageReader {
    private struct Token: Decodable {
        let id: String
        let key: String
        let api_endpoint: String
    }

    private struct EncryptedPayload: Decodable {
        let ciphertext: String
        let IV: String
        let hmac: String
    }

    private struct BSO: Decodable {
        let id: String
        let payload: String
        var modified: Double? = nil
    }

    private struct KeyBundle {
        let encryption: Data
        let hmac: Data
    }

    enum ReaderError: Error {
        case badStatus(String, Int)
        case badKey
        case hmacMismatch
        case decryptFailed
        case rejected(String)
        /// Changed on the server since it was read.
        case conflict
    }

    let auth: SyncAuthInfo

    /// Encrypts each record's cleartext (it must hold its "id") and adds or replaces it in `collection`.
    func upload(_ cleartexts: [[String: Any]], to collection: String) async throws {
        let token = try await fetchToken()
        let base = URL(string: token.api_endpoint)!
        let bundle = try await keyBundle(for: collection, base: base, token: token)
        let bsos: [[String: String]] = try cleartexts.map { record in
            guard let id = record["id"] as? String else { throw ReaderError.rejected("record without id") }
            return ["id": id, "payload": try encrypt(record, with: bundle)]
        }
        let url = base.appending(path: "storage/\(collection)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: bsos)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(hawkHeader(method: "POST", url: url, token: token), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, collection)
        // The server answers 200 even when it turns records down; the list says which it kept.
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let kept = Set(result?["success"] as? [String] ?? [])
        let missing = bsos.compactMap { $0["id"] }.filter { !kept.contains($0) }
        guard missing.isEmpty else { throw ReaderError.rejected(missing.joined(separator: ", ")) }
    }

    /// One record's cleartext and when the server last changed it, for a write that mustn't clobber a newer one.
    func record(_ id: String, in collection: String) async throws -> (cleartext: [String: Any], modified: Double) {
        let token = try await fetchToken()
        let base = URL(string: token.api_endpoint)!
        let bundle = try await keyBundle(for: collection, base: base, token: token)
        let bso: BSO = try await get(base.appending(path: "storage/\(collection)/\(id)"), token: token)
        return (try decrypt(bso.payload, with: bundle), bso.modified ?? 0)
    }

    /// Replaces a record only if nobody changed it after `modified`; throws `conflict` otherwise.
    func replace(_ cleartext: [String: Any], in collection: String, ifUnmodifiedSince modified: Double) async throws {
        guard let id = cleartext["id"] as? String else { throw ReaderError.rejected("record without id") }
        let token = try await fetchToken()
        let base = URL(string: token.api_endpoint)!
        let bundle = try await keyBundle(for: collection, base: base, token: token)
        let url = base.appending(path: "storage/\(collection)/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "payload": try encrypt(cleartext, with: bundle)])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(format: "%.2f", modified), forHTTPHeaderField: "X-If-Unmodified-Since")
        request.setValue(hawkHeader(method: "PUT", url: url, token: token), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 412 { throw ReaderError.conflict }
        try check(response, collection)
    }

    private func keyBundle(for collection: String, base: URL, token: Token) async throws -> KeyBundle {
        guard let syncKey = Data(base64URL: auth.syncKey), syncKey.count == 64 else { throw ReaderError.badKey }
        let root = KeyBundle(encryption: syncKey.prefix(32), hmac: syncKey.suffix(32))
        let keysBSO: BSO = try await get(base.appending(path: "storage/crypto/keys"), token: token)
        let keys = try decrypt(keysBSO.payload, with: root)
        let pair = ((keys["collections"] as? [String: [String]])?[collection]) ?? (keys["default"] as? [String])
        guard let pair, pair.count == 2,
              let enc = Data(base64Encoded: pair[0]), let mac = Data(base64Encoded: pair[1])
        else { throw ReaderError.badKey }
        return KeyBundle(encryption: enc, hmac: mac)
    }

    /// Decrypted cleartext of every record in `collection`; empty when the collection does not exist.
    func records(in collection: String) async throws -> [[String: Any]] {
        let token = try await fetchToken()
        let base = URL(string: token.api_endpoint)!
        let bundle = try await keyBundle(for: collection, base: base, token: token)
        var url = base.appending(path: "storage/\(collection)")
        url.append(queryItems: [URLQueryItem(name: "full", value: "1")])
        let bsos: [BSO]
        do {
            bsos = try await get(url, token: token)
        } catch ReaderError.badStatus(_, 404) {
            return []
        }
        return try bsos.map { try decrypt($0.payload, with: bundle) }
    }

    private func fetchToken() async throws -> Token {
        var request = URLRequest(url: URL(string: auth.tokenserverUrl)!)
        request.setValue("Bearer \(auth.fxaAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.kid, forHTTPHeaderField: "X-KeyID")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, "token")
        return try JSONDecoder().decode(Token.self, from: data)
    }

    private func get<T: Decodable>(_ url: URL, token: Token) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(hawkHeader(method: "GET", url: url, token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, url.lastPathComponent)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func check(_ response: URLResponse, _ what: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ReaderError.badStatus(what, status) }
    }

    /// Hawk header without a payload hash, which the storage server doesn't require; the token's key
    /// string is the raw HMAC key.
    private func hawkHeader(method: String, url: URL, token: Token) -> String {
        let ts = String(Int(Date.now.timeIntervalSince1970))
        let nonce = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let query = url.query(percentEncoded: true).map { "?\($0)" } ?? ""
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let normalized = [
            "hawk.1.header", ts, nonce, method, url.path(percentEncoded: true) + query,
            url.host()!.lowercased(), String(port), "", "",
        ].joined(separator: "\n") + "\n"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(normalized.utf8), using: SymmetricKey(data: Data(token.key.utf8))
        )
        return #"Hawk id="\#(token.id)", ts="\#(ts)", nonce="\#(nonce)", mac="\#(Data(mac).base64EncodedString())""#
    }

    /// AES-256-CBC with a fresh IV, then an HMAC over the base64 ciphertext: Sync's record format.
    private func encrypt(_ cleartext: [String: Any], with bundle: KeyBundle) throws -> String {
        let plain = try JSONSerialization.data(withJSONObject: cleartext)
        let iv = Data((0..<kCCBlockSizeAES128).map { _ in UInt8.random(in: 0...255) })
        var output = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            plain.withUnsafeBytes { input in
                iv.withUnsafeBytes { ivBytes in
                    bundle.encryption.withUnsafeBytes { key in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, input.count, out.baseAddress, out.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ReaderError.decryptFailed }
        let ciphertext = output.prefix(written).base64EncodedString()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(ciphertext.utf8), using: SymmetricKey(data: bundle.hmac))
        let wrapped = ["ciphertext": ciphertext, "IV": iv.base64EncodedString(), "hmac": Data(mac).hex]
        return String(decoding: try JSONSerialization.data(withJSONObject: wrapped), as: UTF8.self)
    }

    /// Verifies the HMAC over the base64 ciphertext, then AES-256-CBC decrypts it.
    private func decrypt(_ payload: String, with bundle: KeyBundle) throws -> [String: Any] {
        let wrapped = try JSONDecoder().decode(EncryptedPayload.self, from: Data(payload.utf8))
        let expected = HMAC<SHA256>.authenticationCode(
            for: Data(wrapped.ciphertext.utf8), using: SymmetricKey(data: bundle.hmac)
        )
        guard Data(expected).hex == wrapped.hmac.lowercased() else { throw ReaderError.hmacMismatch }
        guard let ciphertext = Data(base64Encoded: wrapped.ciphertext),
              let iv = Data(base64Encoded: wrapped.IV)
        else { throw ReaderError.decryptFailed }

        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                iv.withUnsafeBytes { ivBytes in
                    bundle.encryption.withUnsafeBytes { key in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, input.count, out.baseAddress, out.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess,
              let json = try JSONSerialization.jsonObject(with: output.prefix(written)) as? [String: Any]
        else { throw ReaderError.decryptFailed }
        return json
    }
}

private extension Data {
    init?(base64URL string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
