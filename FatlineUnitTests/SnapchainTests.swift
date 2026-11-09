import CryptoKit
import XCTest
@testable import Fatline

/// Replays scripted node responses. A nil response simulates a lost connection.
private actor ScriptedNode {
    private var postResponses: [(Data, Int)?]
    private var lookupResponses: [(Data, Int)?]
    private(set) var postedBodies: [Data] = []
    private(set) var lookupCount = 0

    init(posts: [(Data, Int)?] = [], lookups: [(Data, Int)?] = []) {
        postResponses = posts
        lookupResponses = lookups
    }

    func respond(to request: URLRequest) throws -> (Data, Int) {
        let response: (Data, Int)?
        if request.httpMethod == "POST" {
            postedBodies.append(request.httpBody ?? Data())
            response = postResponses.isEmpty ? nil : postResponses.removeFirst()
        } else {
            lookupCount += 1
            response = lookupResponses.isEmpty ? nil : lookupResponses.removeFirst()
        }
        guard let response else { throw PostingError.unavailable }
        return response
    }
}

final class SnapchainTests: XCTestCase {
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func cast() throws -> SignedCast {
        try SignedCast.make(fid: 42, text: "Hello", key: key, date: date)
    }

    private func receipt(_ cast: SignedCast) -> (Data, Int) {
        (Data(#"{"hash":"\#(cast.hash)","data":{"fid":\#(cast.fid)}}"#.utf8), 200)
    }

    private func rejection(_ message: String, status: Int) -> (Data, Int) {
        (Data(#"{"message":"\#(message)"}"#.utf8), status)
    }

    private let notFound: (Data, Int) = (Data(), 404)

    private func submit(_ cast: SignedCast, to node: ScriptedNode, checkingExisting: Bool = false) async throws {
        try await Snapchain().submit(cast, checkingExisting: checkingExisting) { try await node.respond(to: $0) }
    }

    private func assertUnconfirmed(_ cast: SignedCast, node: ScriptedNode, checkingExisting: Bool = false,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await submit(cast, to: node, checkingExisting: checkingExisting)
            XCTFail("Expected the post to be unconfirmed", file: file, line: line)
        } catch PostingError.unconfirmed {
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    // MARK: Account lookup

    private let custody = "0x00000000000000000000000000000000000000aa"

    private func lookUpAccount(_ responses: [(Data, Int)?]) async throws -> Snapchain.Account {
        let node = ScriptedNode(lookups: responses)
        return try await Snapchain().account(custodyAddress: custody) { try await node.respond(to: $0) }
    }

    func testAccountLookupReturnsTheFidAndNextNonce() async throws {
        let identity = #"{"fid":42,"idRegisterEventBody":{"to":"\#(custody)"}}"#
        let account = try await lookUpAccount([
            (Data(identity.utf8), 200),
            (Data(#"{"signers":[],"currentUserNonce":2}"#.utf8), 200)
        ])
        XCTAssertEqual(account.fid, 42)
        XCTAssertEqual(account.nonce, 3)
    }

    func testAccountLookupReportsTheNodesNotFoundAnswerAsNoAccount() async {
        // The response a node returns for a phrase whose address has no Farcaster account.
        let body = #"{"error":"Failed to get id registry event","error_detail":"status: NotFound, message: \"no id-registry event for address\""}"#
        do {
            _ = try await lookUpAccount([(Data(body.utf8), 400)])
            XCTFail("Expected no account")
        } catch PostingError.accountNotFound {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAccountLookupTreatsOtherFailuresAsUnavailable() async {
        for response in [(Data(#"{"error":"Invalid query parameters"}"#.utf8), 400), (Data(), 503)] as [(Data, Int)?] + [nil] {
            do {
                _ = try await lookUpAccount([response])
                XCTFail("Expected unavailable")
            } catch PostingError.unavailable {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAccountLookupWaitsLongEnoughForTheNodesSlowestAnswer() {
        // A node can take 17 to 23 seconds to answer this.
        XCTAssertGreaterThan(Snapchain.accountLookupTimeout, 30)
    }

    // MARK: Signing

    func testHashIdentifiesTheCastEvenThoughSignaturesVary() throws {
        // CryptoKit randomizes signatures, which is why retries reuse the stored bytes.
        let first = try cast()
        XCTAssertEqual(first.hash, try cast().hash)
        XCTAssertTrue(first.hash.hasPrefix("0x"))
        XCTAssertEqual(first.hash.count, 42)
    }

    func testCastLimitIsCountedInUTF8Bytes() throws {
        XCTAssertNoThrow(try SignedCast.make(fid: 1, text: String(repeating: "é", count: 160), key: key, date: date))
        XCTAssertThrowsError(try SignedCast.make(fid: 1, text: String(repeating: "é", count: 160) + "a", key: key, date: date))
        XCTAssertThrowsError(try SignedCast.make(fid: 1, text: " \n ", key: key, date: date))
    }

    func testRemovalNamesTheTargetHash() throws {
        let target = "0x" + String(repeating: "ab", count: 20)
        let removal = try SignedRemoval.make(fid: 42, target: target.uppercased().replacingOccurrences(of: "0X", with: "0x"), key: key, date: date)
        XCTAssertEqual(removal.target, target)
        // Type 2, FID 42, the timestamp, mainnet, and a CastRemoveBody in field 6 holding the target hash.
        let data = "0802102a1880ab8b56200132160a14" + String(repeating: "ab", count: 20)
        XCTAssertTrue(removal.bytes.hex.contains(data))
        XCTAssertEqual(removal.hash.count, 42)
    }

    func testRemovalNeedsAFullHash() {
        XCTAssertThrowsError(try SignedRemoval.make(fid: 42, target: "0xabc", key: key, date: date))
        XCTAssertThrowsError(try SignedRemoval.make(fid: 42, target: String(repeating: "ab", count: 20), key: key, date: date))
    }

    private func removal() throws -> SignedRemoval {
        try SignedRemoval.make(fid: 42, target: "0x" + String(repeating: "cd", count: 20), key: key, date: date)
    }

    private func remove(_ removal: SignedRemoval, on node: ScriptedNode) async throws {
        try await Snapchain().remove(removal) { try await node.respond(to: $0) }
    }

    func testAcceptedRemovalNeedsNoLookup() async throws {
        let removal = try removal()
        let node = ScriptedNode(posts: [(Data(#"{"hash":"\#(removal.hash)","data":{"fid":42}}"#.utf8), 200)])
        try await remove(removal, on: node)
        let lookups = await node.lookupCount
        XCTAssertEqual(lookups, 0)
    }

    func testLostRemovalIsConfirmedByTheCastBeingGone() async throws {
        let removal = try removal()
        let node = ScriptedNode(posts: [nil], lookups: [notFound])
        try await remove(removal, on: node)
        let posts = await node.postedBodies
        XCTAssertEqual(posts, [removal.bytes])
    }

    func testRefusedRemovalShowsTheNodesReason() async throws {
        let removal = try removal()
        let node = ScriptedNode(posts: [rejection("signer not authorized", status: 400)], lookups: [(Data("{}".utf8), 200)])
        do {
            try await remove(removal, on: node)
            XCTFail("Expected a rejection")
        } catch PostingError.rejected(let reason) {
            XCTAssertEqual(reason, "signer not authorized")
        }
    }

    func testUnansweredRemovalOfAVisibleCastIsUnavailable() async throws {
        let removal = try removal()
        let node = ScriptedNode(posts: [nil], lookups: [(Data("{}".utf8), 200)])
        do {
            try await remove(removal, on: node)
            XCTFail("Expected the removal to fail")
        } catch PostingError.unavailable {}
    }

    // MARK: Submitting

    func testAcceptedPostNeedsNoLookup() async throws {
        let cast = try cast()
        let node = ScriptedNode(posts: [receipt(cast)])
        try await submit(cast, to: node)
        let posts = await node.postedBodies.count
        let lookups = await node.lookupCount
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(lookups, 0)
    }

    func testLostResponseIsConfirmedByHashWithoutResending() async throws {
        let cast = try cast()
        let node = ScriptedNode(posts: [nil], lookups: [receipt(cast)])
        try await submit(cast, to: node)
        let posts = await node.postedBodies.count
        XCTAssertEqual(posts, 1)
    }

    func testUnconfirmedPostResendsOnceWithIdenticalBytes() async throws {
        let cast = try cast()
        let node = ScriptedNode()
        await assertUnconfirmed(cast, node: node)
        let posts = await node.postedBodies
        XCTAssertEqual(posts, [cast.bytes, cast.bytes])
    }

    func testRetryFindsAnExistingCastWithoutPosting() async throws {
        let cast = try cast()
        let node = ScriptedNode(lookups: [receipt(cast)])
        try await submit(cast, to: node, checkingExisting: true)
        let posts = await node.postedBodies.count
        XCTAssertEqual(posts, 0)
    }

    func testFirstRejectionShowsTheNodesReason() async throws {
        let cast = try cast()
        let node = ScriptedNode(posts: [rejection("invalid signer", status: 400)], lookups: [notFound])
        do {
            try await submit(cast, to: node)
            XCTFail("Expected a rejection")
        } catch PostingError.rejected(let reason) {
            XCTAssertEqual(reason, "invalid signer")
        }
    }

    func testRejectionDuringRetryStaysUnconfirmedBecauseTheCastMayExist() async throws {
        let cast = try cast()
        let node = ScriptedNode(posts: [rejection("invalid signer", status: 400)], lookups: [notFound, notFound])
        await assertUnconfirmed(cast, node: node, checkingExisting: true)
    }

    func testDuplicateIsConfirmedOnceTheCastIsVisible() async throws {
        let cast = try cast()
        let node = ScriptedNode(posts: [rejection("duplicate message", status: 409)], lookups: [notFound, receipt(cast)])
        try await submit(cast, to: node)
    }

    func testRateLimitIsUnconfirmed() async throws {
        let cast = try cast()
        let node = ScriptedNode(posts: [rejection("slow down", status: 429)], lookups: [notFound])
        await assertUnconfirmed(cast, node: node)
        let posts = await node.postedBodies.count
        XCTAssertEqual(posts, 1)
    }

    func testReceiptForAnotherCastDoesNotCountAsSent() async throws {
        let cast = try cast()
        let other = (Data(#"{"hash":"0xother","data":{"fid":42}}"#.utf8), 200)
        let node = ScriptedNode(posts: [other, other], lookups: [other, other])
        await assertUnconfirmed(cast, node: node)
    }

    // MARK: Username

    func testUsernameIsFoundWhenTheProfilePictureComesFirst() throws {
        let data = Data("""
        {"messages":[
          {"data":{"userDataBody":{"type":"USER_DATA_TYPE_PFP","value":"https://example.com/a.jpg"}}},
          {"data":{"userDataBody":{"type":"USER_DATA_TYPE_USERNAME","value":"ethglobal"}}}
        ]}
        """.utf8)
        XCTAssertEqual(try Snapchain.username(in: data), "ethglobal")
    }

    func testMissingOrEmptyUsernameIsNil() throws {
        let data = Data("""
        {"messages":[
          {"data":{"userDataBody":{"type":"USER_DATA_TYPE_BIO","value":"hi"}}},
          {"data":{"userDataBody":{"type":"USER_DATA_TYPE_USERNAME","value":""}}}
        ]}
        """.utf8)
        XCTAssertNil(try Snapchain.username(in: data))
    }

    // MARK: Posting key status

    private func signers(_ json: String) -> Data { Data(#"{"signers":[\#(json)]}"#.utf8) }

    func testKeyBeforeItsExpiryIsActive() throws {
        let data = signers(#"{"fid":3,"key":"0xABC","expiresAt":1000}"#)
        let status = try Snapchain.signerStatus(in: data, fid: 3, publicKey: "0xabc", now: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(status, .active)
    }

    func testKeyAtItsExpiryIsExpired() throws {
        let data = signers(#"{"fid":3,"key":"0xabc","expiresAt":1000}"#)
        let status = try Snapchain.signerStatus(in: data, fid: 3, publicKey: "0xabc", now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(status, .expired)
    }

    func testKeyWithoutATimeLimitIsActive() throws {
        let data = signers(#"{"fid":3,"key":"0xabc"}"#)
        XCTAssertEqual(try Snapchain.signerStatus(in: data, fid: 3, publicKey: "0xabc"), .active)
    }

    func testKeyMadeToPostOnlyCantDelete() throws {
        let data = signers(#"{"fid":3,"key":"0xabc","expiresAt":2000,"scopes":["MESSAGE_TYPE_CAST_ADD"]}"#)
        let state = try Snapchain.signerState(in: data, fid: 3, publicKey: "0xabc", now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(state, Snapchain.SignerState(status: .active, canDelete: false))
    }

    func testKeyAllowedToDeleteOrWithoutLimitsCanDelete() throws {
        let scoped = signers(#"{"fid":3,"key":"0xabc","scopes":["MESSAGE_TYPE_CAST_ADD","MESSAGE_TYPE_CAST_REMOVE"]}"#)
        XCTAssertTrue(try Snapchain.signerState(in: scoped, fid: 3, publicKey: "0xabc").canDelete)
        let unlimited = signers(#"{"fid":3,"key":"0xabc"}"#)
        XCTAssertTrue(try Snapchain.signerState(in: unlimited, fid: 3, publicKey: "0xabc").canDelete)
    }

    func testUnlistedKeyOrOtherAccountIsMissing() throws {
        let data = signers(#"{"fid":4,"key":"0xabc"}"#)
        XCTAssertEqual(try Snapchain.signerStatus(in: data, fid: 3, publicKey: "0xabc"), .missing)
        XCTAssertEqual(try Snapchain.signerStatus(in: data, fid: 4, publicKey: "0xdef"), .missing)
    }
}
