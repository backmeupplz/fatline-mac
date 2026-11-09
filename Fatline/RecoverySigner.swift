import CryptoKit
import Foundation
import JavaScriptCore

struct SignerRegistration: Codable {
    let fid: UInt64
    let deadline: UInt32
    let bytes: Data
}

@MainActor
final class RecoverySigner {
    private let context: JSContext
    private let account: JSValue
    let address: String

    init(phrase: String) throws {
        guard phrase.utf8.count <= 1024,
              let url = Bundle.main.url(forResource: "authorize", withExtension: "js"),
              let context = JSContext() else { throw PostingError.invalidPhrase }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        guard context.exception == nil,
              let account = context.objectForKeyedSubscript("recoverFarcasterAccount")?.call(withArguments: [phrase]),
              !account.isNull, !account.isUndefined,
              let address = account.objectForKeyedSubscript("address")?.toString(),
              address.count == 42 else {
            throw PostingError.invalidPhrase
        }
        self.context = context
        self.account = account
        self.address = address
    }

    func registration(fid: UInt64, nonce: UInt32, key: Curve25519.Signing.PrivateKey) throws -> SignerRegistration {
        let ttl: UInt32 = 30 * 24 * 60 * 60
        let now = Date.now
        let (deadline, overflow) = try SnapchainMessage.timestamp(now).addingReportingOverflow(3600)
        guard !overflow else { throw PostingError.invalidClock }
        let publicKey = key.publicKey.rawRepresentation
        guard let signed = account.invokeMethod("authorize", withArguments: [
            String(fid), publicKey.hex, deadline, nonce, ttl
        ]), context.exception == nil,
            let custodySignature = signed.objectForKeyedSubscript("custodySignature")?.toString().flatMap(Data.init(hex:)),
            custodySignature.count == 65,
            let metadata = signed.objectForKeyedSubscript("metadata")?.toString().flatMap(Data.init(hex:)),
            !metadata.isEmpty else {
            throw PostingError.rejected("Couldn’t authorize the posting key.")
        }

        var body = Protobuf()
        body.bytes(1, publicKey)
        body.integer(2, 1) // Ed25519
        body.bytes(3, custodySignature)
        body.integer(4, UInt64(deadline))
        body.integer(5, UInt64(nonce))
        body.bytes(6, metadata)
        body.integer(7, 1) // Signed key request metadata
        body.bytes(9, Data([1, 2])) // Packed CAST_ADD and CAST_REMOVE scopes, which the custody signature covers
        body.integer(10, UInt64(ttl))
        let message = try SnapchainMessage.sign(type: 16, field: 19, body: body.data, fid: fid, key: key, date: now)
        return SignerRegistration(fid: fid, deadline: deadline, bytes: message.bytes)
    }
}
