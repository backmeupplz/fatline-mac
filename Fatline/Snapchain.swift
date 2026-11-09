import CryptoKit
import Foundation

struct SignedCast: Codable, Equatable {
    let fid: UInt64
    let text: String
    let hash: String
    let bytes: Data
    /// Optional because a saved pending cast may not have one.
    var timestamp: UInt32? = nil

    static func make(fid: UInt64, text: String, key: Curve25519.Signing.PrivateKey, date: Date = .now) throws -> Self {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 320 else {
            throw PostingError.invalidCast
        }

        var body = Protobuf()
        body.bytes(2, Data()) // Empty packed mentions and offsets match the Farcaster SDK.
        body.bytes(4, Data(text.utf8))
        body.bytes(5, Data())

        let message = try SnapchainMessage.sign(type: 1, field: 5, body: body.data, fid: fid, key: key, date: date)
        return Self(fid: fid, text: text, hash: message.hash, bytes: message.bytes, timestamp: try SnapchainMessage.timestamp(date))
    }
}

/// Deletes one of this account's casts. The network only accepts it from a key allowed to delete.
struct SignedRemoval: Equatable {
    let fid: UInt64
    /// The deleted cast's hash.
    let target: String
    let hash: String
    let bytes: Data

    static func make(fid: UInt64, target: String, key: Curve25519.Signing.PrivateKey, date: Date = .now) throws -> Self {
        guard let targetHash = Data(hex: target.lowercased()), targetHash.count == 20 else { throw PostingError.invalidCast }
        var body = Protobuf()
        body.bytes(1, targetHash)
        let message = try SnapchainMessage.sign(type: 2, field: 6, body: body.data, fid: fid, key: key, date: date)
        return Self(fid: fid, target: target.lowercased(), hash: message.hash, bytes: message.bytes)
    }
}

struct SnapchainMessage {
    let hash: String
    let bytes: Data

    static func timestamp(_ date: Date = .now) throws -> UInt32 {
        let seconds = floor(date.timeIntervalSince1970) - 1_609_459_200
        guard seconds > 0, seconds <= Double(UInt32.max) else { throw PostingError.invalidClock }
        return UInt32(seconds)
    }

    static func sign(type: UInt64, field: UInt64, body: Data, fid: UInt64,
                     key: Curve25519.Signing.PrivateKey, date: Date = .now) throws -> Self {
        var messageData = Protobuf()
        messageData.integer(1, type)
        messageData.integer(2, fid)
        messageData.integer(3, UInt64(try timestamp(date)))
        messageData.integer(4, 1) // Mainnet
        messageData.bytes(field, body)

        var hasher = blake3_hasher()
        blake3_hasher_init(&hasher)
        messageData.data.withUnsafeBytes { blake3_hasher_update(&hasher, $0.baseAddress, $0.count) }
        var hash = [UInt8](repeating: 0, count: 20)
        blake3_hasher_finalize(&hasher, &hash, hash.count)
        let digest = Data(hash)

        var message = Protobuf()
        message.bytes(1, messageData.data)
        message.bytes(2, digest)
        message.integer(3, 1) // BLAKE3
        message.bytes(4, try key.signature(for: digest))
        message.integer(5, 1) // Ed25519
        message.bytes(6, key.publicKey.rawRepresentation)
        message.bytes(7, messageData.data)
        return Self(hash: digest.hex, bytes: message.data)
    }
}

struct Protobuf {
    private(set) var data = Data()

    mutating func integer(_ field: UInt64, _ value: UInt64) {
        varint(field << 3)
        varint(value)
    }

    mutating func bytes(_ field: UInt64, _ value: Data) {
        varint(field << 3 | 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    private mutating func varint(_ value: UInt64) {
        var remaining = value
        while remaining >= 128 {
            data.append(UInt8(remaining & 127) | 128)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}

extension Data {
    var hex: String { "0x" + map { String(format: "%02x", $0) }.joined() }

    /// Reads 0x-prefixed hex, the form hashes and keys take in the network's JSON.
    init?(hex: String) {
        guard hex.hasPrefix("0x"), hex.utf8.count.isMultiple(of: 2) else { return nil }
        let digits = Array(hex.dropFirst(2).utf8)
        self.init()
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            append(byte)
        }
    }
}

enum PostingError: LocalizedError {
    case invalidCast, missingKey, awaitingSigner, unconfirmed, unavailable
    case invalidPhrase, accountNotFound, invalidClock, expiredAuthorization, inactiveKey, postOnlyKey
    case rejected(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPhrase: "Check the spelling and order of the recovery words."
        case .accountNotFound: "This recovery phrase is valid, but it isn’t linked to a Farcaster account. Check that it’s your Farcaster recovery phrase, not one from another wallet."
        case .invalidClock: "Check your Mac’s date and time."
        case .expiredAuthorization: "The authorization expired. Enter your phrase again."
        case .inactiveKey: "This Mac’s posting key is no longer active. Sign out and enter your recovery phrase to post again."
        case .postOnlyKey: "This Mac’s posting key can only post. Sign out and enter your recovery phrase again to get one that can delete casts."
        case .invalidCast: "Write a cast of up to 320 UTF-8 bytes."
        case .missingKey: "The posting key is unavailable."
        case .awaitingSigner: "Snapchain is still syncing the posting key. Try again."
        case .unconfirmed: "Retry to check the same cast."
        case .unavailable: "Couldn’t reach the service. Try again."
        case .rejected(let reason): reason
        case .keychain: "Fatline couldn’t access the Keychain."
        }
    }
}

struct Snapchain: Sendable {
    var base: URL { Connection.current.nodeBase }

    struct Account {
        let fid: UInt64
        let nonce: UInt32
    }

    /// The node answers an address it doesn't know with a 400 after about 20 seconds, so this
    /// lookup needs a longer timeout than other reads or that answer never arrives.
    static let accountLookupTimeout: TimeInterval = 45

    func account(
        custodyAddress: String,
        send: @Sendable (URLRequest) async throws -> (Data, Int) = HTTP.send
    ) async throws -> Account {
        struct Identity: Decodable {
            struct Registration: Decodable { let to: String }
            let fid: UInt64
            let idRegisterEventBody: Registration
        }
        struct Signers: Decodable { let currentUserNonce: UInt32 }
        let (data, status) = try await send(HTTP.getRequest(
            base, "onChainIdRegistryEventByAddress", ["address": custodyAddress], timeout: Self.accountLookupTimeout
        ))
        if status == 404 || (status == 400 && String(decoding: data, as: UTF8.self).contains("NotFound")) {
            throw PostingError.accountNotFound
        }
        guard status == 200 else { throw PostingError.unavailable }
        let identity = try JSONDecoder().decode(Identity.self, from: data)
        guard identity.fid > 0, identity.idRegisterEventBody.to.lowercased() == custodyAddress else {
            throw PostingError.accountNotFound
        }
        let (keys, keyStatus) = try await send(HTTP.getRequest(
            base, "signersByFid", ["fid": String(identity.fid), "pageSize": "1"], timeout: 10
        ))
        guard keyStatus == 200 else { throw PostingError.unavailable }
        let current = try JSONDecoder().decode(Signers.self, from: keys).currentUserNonce
        guard current < UInt32.max else { throw PostingError.unavailable }
        return Account(fid: identity.fid, nonce: current + 1)
    }

    func register(_ registration: SignerRegistration, publicKey: String) async throws {
        if try await hasSigner(fid: registration.fid, publicKey: publicKey) { return }
        guard try SnapchainMessage.timestamp() <= registration.deadline else {
            throw PostingError.expiredAuthorization
        }
        let submission = try? await post(registration.bytes)
        if let (data, status) = submission, (400..<500).contains(status), status != 429,
           let reason = try? JSONDecoder().decode(Rejection.self, from: data).message,
           !reason.localizedCaseInsensitiveContains("duplicate"),
           !reason.localizedCaseInsensitiveContains("nonce") {
            // Shown right under the recovery phrase, so a server's own words don't belong there.
            throw PostingError.rejected("The server rejected this request.")
        }
        for attempt in 0..<8 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            if (try? await hasSigner(fid: registration.fid, publicKey: publicKey)) == true { return }
        }
        throw PostingError.awaitingSigner
    }

    enum SignerStatus: Equatable {
        case active, expired, missing
    }

    struct SignerState: Equatable {
        let status: SignerStatus
        /// Keys made by Fatline before it could delete can only post.
        let canDelete: Bool
    }

    func hasSigner(fid: UInt64, publicKey: String) async throws -> Bool {
        try await signerState(fid: fid, publicKey: publicKey).status == .active
    }

    func signerState(fid: UInt64, publicKey: String) async throws -> SignerState {
        let (data, status) = try await HTTP.get(base, "signersByFid", ["fid": String(fid), "pageSize": "1000"])
        guard status == 200 else { throw PostingError.unavailable }
        return try Self.signerState(in: data, fid: fid, publicKey: publicKey)
    }

    static func signerStatus(in data: Data, fid: UInt64, publicKey: String, now: Date = .now) throws -> SignerStatus {
        try signerState(in: data, fid: fid, publicKey: publicKey, now: now).status
    }

    /// Keys with a time limit report `expiresAt` in Unix seconds, and it moves forward each time the key
    /// signs something. Older on-chain keys have no limit. A key limited to some kinds of message lists
    /// them in `scopes`, and a key without the list can make any kind.
    static func signerState(in data: Data, fid: UInt64, publicKey: String, now: Date = .now) throws -> SignerState {
        struct Signer: Decodable { let fid: UInt64; let key: String; let expiresAt: UInt64?; let scopes: [String]? }
        struct Response: Decodable { let signers: [Signer] }
        let signer = try JSONDecoder().decode(Response.self, from: data).signers.first {
            $0.fid == fid && $0.key.lowercased() == publicKey
        }
        guard let signer else { return SignerState(status: .missing, canDelete: false) }
        let canDelete = signer.scopes?.contains("MESSAGE_TYPE_CAST_REMOVE") ?? true
        guard let expiresAt = signer.expiresAt else { return SignerState(status: .active, canDelete: canDelete) }
        let status: SignerStatus = Double(expiresAt) > now.timeIntervalSince1970 ? .active : .expired
        return SignerState(status: status, canDelete: canDelete)
    }

    func username(fid: UInt64) async throws -> String {
        let (data, status) = try await HTTP.get(base, "userDataByFid", [
            "fid": String(fid), "user_data_type": "USER_DATA_TYPE_USERNAME"
        ])
        guard status == 200 else { return String(fid) }
        return try Self.username(in: data) ?? String(fid)
    }

    /// The node can return every profile record, with the username in any position.
    static func username(in data: Data) throws -> String? {
        struct Message: Decodable {
            struct Payload: Decodable {
                struct UserData: Decodable { let type: String; let value: String }
                let userDataBody: UserData?
            }
            let data: Payload
        }
        struct Response: Decodable { let messages: [Message] }
        return try JSONDecoder().decode(Response.self, from: data).messages
            .compactMap(\.data.userDataBody)
            .first { $0.type == "USER_DATA_TYPE_USERNAME" && !$0.value.isEmpty }?.value
    }

    func submit(
        _ cast: SignedCast,
        checkingExisting: Bool = false,
        send: @Sendable (URLRequest) async throws -> (Data, Int) = HTTP.send
    ) async throws {
        let lookup = HTTP.getRequest(base, "castById", ["fid": String(cast.fid), "hash": cast.hash], timeout: 3)
        func confirmed() async -> Bool {
            guard let (data, status) = try? await send(lookup), status == 200 else { return false }
            return matches(data, hash: cast.hash, fid: cast.fid)
        }

        try Task.checkCancellation()
        if checkingExisting, await confirmed() { return }

        let submission = postRequest(cast.bytes, timeout: 6)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let response = try? await send(submission)
            if let (data, status) = response, status == 200, matches(data, hash: cast.hash, fid: cast.fid) { return }
            try Task.checkCancellation()
            if await confirmed() { return }

            if let (data, status) = response {
                let reason = (try? JSONDecoder().decode(Rejection.self, from: data).message) ?? ""
                if status == 409 || reason.localizedCaseInsensitiveContains("duplicate") ||
                    reason.localizedCaseInsensitiveContains("already exists") {
                    try await Task.sleep(for: .milliseconds(600))
                    if await confirmed() { return }
                    throw PostingError.unconfirmed
                }
                if status == 429 { throw PostingError.unconfirmed }
                if (400..<500).contains(status), status != 408, status != 425 {
                    if !checkingExisting, attempt == 0, !reason.isEmpty {
                        throw PostingError.rejected(String(reason.prefix(180)))
                    }
                    throw PostingError.unconfirmed
                }
            }
            if attempt == 0 { try await Task.sleep(for: .milliseconds(600)) }
        }
        throw PostingError.unconfirmed
    }

    /// Sends a deletion once. If the answer is lost or unclear, the cast being gone settles it.
    func remove(
        _ removal: SignedRemoval,
        send: @Sendable (URLRequest) async throws -> (Data, Int) = HTTP.send
    ) async throws {
        try Task.checkCancellation()
        let response = try? await send(postRequest(removal.bytes, timeout: 10))
        if let (data, status) = response, status == 200, matches(data, hash: removal.hash, fid: removal.fid) { return }
        let lookup = HTTP.getRequest(base, "castById", ["fid": String(removal.fid), "hash": removal.target], timeout: 5)
        if let (_, status) = try? await send(lookup), status == 404 { return }
        if let (data, status) = response, (400..<500).contains(status), status != 408, status != 429,
           let reason = try? JSONDecoder().decode(Rejection.self, from: data).message, !reason.isEmpty {
            throw PostingError.rejected(String(reason.prefix(180)))
        }
        throw PostingError.unavailable
    }

    private func post(_ bytes: Data) async throws -> (Data, Int) {
        try await HTTP.send(postRequest(bytes, timeout: 20))
    }

    private func postRequest(_ bytes: Data, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: base.appending(path: "submitMessage"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        Connection.current.authorize(&request)
        request.httpBody = bytes
        return request
    }

    private struct Rejection: Decodable { let message: String }

    private func matches(_ data: Data, hash: String, fid: UInt64) -> Bool {
        struct Receipt: Decodable {
            struct Payload: Decodable { let fid: UInt64 }
            let hash: String
            let data: Payload
        }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
        return receipt.hash.lowercased() == hash && receipt.data.fid == fid
    }
}

enum HTTP {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // A request's own timeout only limits silence, so this stops a server that answers very slowly.
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Far above any real page. The server is chosen by the person, so its answers aren't trusted.
    private static let maxBodyBytes = 16 * 1024 * 1024

    static func get(_ base: URL, _ path: String, _ query: [String: String]) async throws -> (Data, Int) {
        try await send(getRequest(base, path, query, timeout: 10))
    }

    static func getRequest(_ base: URL, _ path: String, _ query: [String: String], timeout: TimeInterval) -> URLRequest {
        var url = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        Connection.current.authorize(&request)
        return request
    }

    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, status) = try await load(request)
            return Connection.current.nodeAnswer(data, status: status, for: request.url)
        } catch {
            throw PostingError.unavailable
        }
    }

    static func load(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await loadResponse(request)
        return (data, response.statusCode)
    }

    /// Like `send`, but keeps the underlying error and headers so the feed can report what went wrong.
    static func loadResponse(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBodyBytes {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return (data, response)
    }
}
