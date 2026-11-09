import XCTest
import os
@testable import Fatline

private final class FakeServer: Sendable {
    private let requestLog = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
    private let answer: @Sendable (URLRequest) throws -> (Int, String)

    init(answer: @escaping @Sendable (URLRequest) throws -> (Int, String)) {
        self.answer = answer
    }

    var requests: [URLRequest] { requestLog.withLock { $0 } }

    var send: FeedReader.Send {
        { [self] request in
            requestLog.withLock { $0.append(request) }
            let (status, body) = try answer(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func forget() { requestLog.withLock { $0.removeAll() } }
}

private extension URLRequest {
    func query(_ name: String) -> String? {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

private func json(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}

private func stamp(_ seconds: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(seconds)).ISO8601Format()
}

private func remote(_ hash: String, fid: UInt64 = 10, time: Int64 = 1_800_000_000, extra: [String: Any] = [:]) -> [String: Any] {
    var cast: [String: Any] = [
        "hash": hash, "text": "cast \(hash)", "timestamp": stamp(time), "parent_hash": NSNull(),
        "author": ["fid": fid, "username": "user\(fid)"]
    ]
    cast.merge(extra) { _, new in new }
    return cast
}

private func page(_ casts: [[String: Any]], cursor: String? = nil) -> String {
    var body: [String: Any] = ["casts": casts]
    if let cursor { body["next"] = ["cursor": cursor] }
    return json(body)
}

private let neynar = Connection.neynar(key: "test-key")

private func decodeCast(_ cast: [String: Any]) throws -> FeedCast? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return FeedReader.feedCast(from: try decoder.decode(RemoteCast.self, from: Data(json(cast).utf8)))
}

final class FeedReaderCastTests: XCTestCase {
    func testTextNeynarAlreadyWroteOutIsLeftAlone() throws {
        let cast = try decodeCast(remote("0xabc", extra: [
            "text": "hi @alice there",
            "mentioned_profiles": [["username": "alice"]],
            "mentioned_profiles_ranges": [["start": 3, "end": 9]]
        ]))
        XCTAssertEqual(cast?.text, "hi @alice there")
    }

    func testEmptyRangesAreFilledAtTheirByteOffsets() throws {
        let cast = try decodeCast(remote("abc", extra: [
            "text": "café  and ",
            "mentioned_profiles": [["username": "bob"], ["username": "amy"]],
            "mentioned_profiles_ranges": [["start": 6, "end": 6], ["start": 11, "end": 11]]
        ]))
        XCTAssertEqual(cast?.text, "café @bob and @amy")
    }

    func testAMentionAtTheStartIsWrittenBeforeTrimming() throws {
        let cast = try decodeCast(remote("abc", extra: [
            "text": " curate ",
            "mentioned_profiles": [["username": "dwr"]],
            "mentioned_profiles_ranges": [["start": 0, "end": 0]]
        ]))
        XCTAssertEqual(cast?.text, "@dwr curate")
    }

    func testAnOffsetPastTheTextIsIgnored() throws {
        let cast = try decodeCast(remote("abc", extra: [
            "text": "short",
            "mentioned_profiles": [["username": "dwr"]],
            "mentioned_profiles_ranges": [["start": 900, "end": 900]]
        ]))
        XCTAssertEqual(cast?.text, "short")
    }

    func testHashesAlwaysHaveThePrefix() throws {
        XCTAssertEqual(try decodeCast(remote("ABC123"))?.hash, "0xabc123")
        XCTAssertEqual(try decodeCast(remote("0xabc123"))?.hash, "0xabc123")
    }

    func testRepliesAndEmptyCastsAreLeftOut() throws {
        XCTAssertNil(try decodeCast(remote("a", extra: ["parent_hash": "0xdef"])))
        XCTAssertNil(try decodeCast(remote("a", extra: ["text": "  "])))
    }

    func testFractionalTimestampsParse() throws {
        XCTAssertEqual(try decodeCast(remote("a", extra: ["timestamp": "2026-11-08T18:50:38.000Z"]))?.time, 1_794_163_838)
    }

    func testOnlyLinksAReaderWouldFollowAreKept() throws {
        let cast = try decodeCast(remote("a", extra: [
            "text": "see example.com/in-text",
            "embeds": [
                ["url": "https://example.com/in-text"],
                ["url": "https://example.com/article"],
                ["url": "https://imagedelivery.net/a/b"],
                ["url": "https://example.com/photo.JPG"],
                ["url": "https://example.com/typed", "metadata": ["content_type": "video/mp4"]],
                ["url": "ftp://example.com/file"]
            ]
        ]))
        XCTAssertEqual(cast?.links, ["https://example.com/article"])
    }

    func testImagesAreKeptAndOtherAttachmentsAreNot() throws {
        let cast = try decodeCast(remote("a", extra: [
            "embeds": [
                ["url": "https://imagedelivery.net/a/b/original", "metadata": ["_status": "PENDING"]],
                ["url": "https://example.com/photo.JPG"],
                ["url": "https://example.com/typed", "metadata": ["content_type": "image/png"]],
                ["url": "https://example.com/vector.svg"],
                ["url": "https://example.com/typed.svg", "metadata": ["content_type": "image/svg+xml"]],
                ["url": "http://example.com/insecure.png"],
                ["url": "https://stream.farcaster.xyz/v1/video/a.m3u8"],
                ["url": "https://example.com/clip.mp4"],
                ["url": "https://example.com/looks.png", "metadata": ["content_type": "video/mp4"]],
                ["url": "https://miniapp.example.com/", "metadata": ["content_type": "text/html"]]
            ]
        ]))
        XCTAssertEqual(cast?.images, [
            "https://imagedelivery.net/a/b/original",
            "https://example.com/photo.JPG",
            "https://example.com/typed"
        ])
    }

    func testACastKeepsOnlySoManyImages() throws {
        let embeds = (0..<9).map { ["url": "https://example.com/\($0).png"] }
        XCTAssertEqual(try decodeCast(remote("a", extra: ["embeds": embeds]))?.images?.count, 4)
    }

    func testACastWithOnlyAPictureIsKeptButOnlyAVideoIsNot() throws {
        let picture = try decodeCast(remote("a", time: 1_700_000_000, extra: ["text": "", "embeds": [["url": "https://imagedelivery.net/a/b"]]]))
        XCTAssertEqual(picture?.imageURLs.count, 1)
        XCTAssertEqual(picture?.isReadable, true)
        XCTAssertNil(try decodeCast(remote("a", extra: ["text": "", "embeds": [["url": "https://stream.farcaster.xyz/a.m3u8"]]])))
    }

    func testTheAuthorsPictureIsKeptOverHTTPSOnly() throws {
        let cast = try decodeCast(remote("a", extra: ["author": ["fid": 10, "username": "ten", "pfp_url": "https://imagedelivery.net/a/b"]]))
        XCTAssertEqual(cast?.avatarURL?.absoluteString, "https://imagedelivery.net/a/b")
        let insecure = try decodeCast(remote("a", extra: ["author": ["fid": 10, "username": "ten", "pfp_url": "http://example.com/a.png"]]))
        XCTAssertNil(insecure?.avatarURL)
        XCTAssertNil(try decodeCast(remote("a"))?.avatarURL)
    }

    func testPicturesOnThisMacsOwnNetworkAreNotFetched() throws {
        for address in ["https://localhost/a.png", "https://127.0.0.1/a.png", "https://192.168.1.1/a.png", "https://[::1]/a.png", "https://printer.local/a.png", "https://router/a.png"] {
            let cast = try decodeCast(remote("a", extra: ["author": ["fid": 10, "username": "ten", "pfp_url": address], "embeds": [["url": address]]]))
            XCTAssertNil(cast?.avatarURL, address)
            XCTAssertEqual(cast?.imageURLs, [], address)
        }
    }

    func testAQuoteNeedsItsText() throws {
        let quoted = try decodeCast(remote("a", extra: [
            "embeds": [["cast": ["text": " quoted ", "author": ["fid": 7, "username": "seven"]], "cast_id": ["fid": 7, "hash": "x"]]]
        ]))
        XCTAssertEqual(quoted?.quote, FeedCast.Quote(fid: 7, handle: "seven", text: "quoted"))
        let idOnly = try decodeCast(remote("a", extra: ["embeds": [["cast_id": ["fid": 7, "hash": "x"]]]]))
        XCTAssertNil(idOnly?.quote)
    }
}

final class FeedReaderTests: XCTestCase {
    private let follows: Set<UInt64> = [10]

    func testAPollAsksForAShortPageWithoutRecasts() async throws {
        let server = FakeServer { _ in (200, page([remote("0xa", time: 1000)])) }
        let read = try await FeedReader(connection: neynar, send: server.send).poll(fid: 3, since: 1000, follows: follows)
        XCTAssertEqual(read.casts.map(\.hash), ["0xa"])
        XCTAssertEqual(read.latestSeen, 1000)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url?.host(), "api.neynar.com")
        XCTAssertEqual(request.url?.path(), "/v2/farcaster/feed/following/")
        XCTAssertEqual(request.query("fid"), "3")
        XCTAssertEqual(request.query("limit"), "10")
        XCTAssertEqual(request.query("with_recasts"), "false")
    }

    func testAPollStopsOnceItOverlapsTheLastRead() async throws {
        let server = FakeServer { request in
            request.query("cursor") == nil
                ? (200, page([remote("0xa", time: 2000)], cursor: "two"))
                : (200, page([remote("0xb", time: 800)], cursor: "three"))
        }
        let read = try await FeedReader(connection: neynar, send: server.send).poll(fid: 3, since: 1000, follows: follows)
        XCTAssertEqual(read.casts.map(\.hash), ["0xa", "0xb"])
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAPollStopsAtItsPageLimit() async throws {
        let server = FakeServer { _ in (200, page([remote("0xa", time: 5000)], cursor: "more")) }
        _ = try await FeedReader(connection: neynar, send: server.send).poll(fid: 3, since: 1000, follows: follows)
        XCTAssertEqual(server.requests.count, FeedReader.pollMaxPages)
    }

    func testPeopleOutsideTheListAreSkipped() async throws {
        let server = FakeServer { _ in (200, page([remote("0xa", fid: 99), remote("0xb", fid: 10)])) }
        let read = try await FeedReader(connection: neynar, send: server.send).poll(fid: 3, since: 0, follows: follows)
        XCTAssertEqual(read.casts.map(\.hash), ["0xb"])
        XCTAssertEqual(read.handles, [10: "user10"])
    }

    func testOneBadRowDoesntLoseThePage() async throws {
        let server = FakeServer { _ in (200, page([["hash": "broken"], remote("0xb")])) }
        let read = try await FeedReader(connection: neynar, send: server.send).poll(fid: 3, since: 0, follows: follows)
        XCTAssertEqual(read.casts.map(\.hash), ["0xb"])
    }

    func testAFullReadIsCompleteOnlyIfItReachesTheEnd() async throws {
        let ended = FakeServer { _ in (200, page([remote("0xa", time: 500)], cursor: "more")) }
        let complete = try await FeedReader(connection: neynar, send: ended.send).window(fid: 3, oldestAllowed: 1000, follows: follows)
        XCTAssertTrue(complete.complete)
        XCTAssertEqual(ended.requests.count, 1)
        XCTAssertEqual(ended.requests.first?.query("limit"), "100")

        let endless = FakeServer { _ in (200, page([remote("0xa", time: 5000)], cursor: "more")) }
        let partial = try await FeedReader(connection: neynar, send: endless.send).window(fid: 3, oldestAllowed: 1000, follows: follows)
        XCTAssertFalse(partial.complete)
        XCTAssertEqual(endless.requests.count, FeedReader.windowMaxPages)
    }

    func testTheFollowListComesFromTheNodeWithNamesFromTheFeedServer() async throws {
        let server = FakeServer { request in
            switch request.url!.path() {
            case "/v1/linksByFid" where request.query("pageToken") == nil:
                return (200, json([
                    "messages": [
                        ["data": ["type": "MESSAGE_TYPE_LINK_ADD", "linkBody": ["type": "follow", "targetFid": 20]]],
                        ["data": ["type": "MESSAGE_TYPE_LINK_REMOVE", "linkBody": ["type": "follow", "targetFid": 30]]]
                    ],
                    "nextPageToken": "next"
                ]))
            case "/v1/linksByFid":
                return (200, json(["messages": [["data": ["type": "MESSAGE_TYPE_LINK_ADD", "linkBody": ["type": "follow", "targetFid": 5]]]], "nextPageToken": ""]))
            case "/v2/farcaster/user/bulk/":
                return (200, json(["users": [["fid": 5, "username": "five"], ["fid": 20, "username": "!20"]]]))
            default:
                return (500, "")
            }
        }
        let people = try await FeedReader(connection: neynar, send: server.send).follows(fid: 3)
        XCTAssertEqual(people, [FeedModel.Person(handle: "five", id: 5), FeedModel.Person(handle: "20", id: 20)])
        XCTAssertEqual(server.requests.first?.url?.host(), "snapchain-api.neynar.com")
        XCTAssertEqual(server.requests.last?.query("fids"), "5,20")
    }

    func testAMissingRouteDoesntLookLikeAMissingList() async {
        let server = FakeServer { _ in (404, "") }
        do {
            _ = try await FeedReader(connection: neynar, send: server.send).poll(fid: 3, since: 0, follows: follows)
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual((error as? FeedHTTPError)?.status, 502)
        }
    }

    func testACustomServerGetsTheSameRoutes() async throws {
        let server = FakeServer { _ in (200, page([])) }
        let custom = Connection.custom(URL(string: "https://node.example")!)
        _ = try await FeedReader(connection: custom, send: server.send).poll(fid: 3, since: 0, follows: follows)
        XCTAssertEqual(server.requests.first?.url?.absoluteString.components(separatedBy: "?").first, "https://node.example/v2/farcaster/feed/following/")
        XCTAssertNil(server.requests.first?.value(forHTTPHeaderField: "x-api-key"))
    }
}

final class ConnectionTests: XCTestCase {
    func testAnInviteOnlyGoesToTheServerItNames() {
        let invite = Connection.invite(Invite(typed: "ABCD-EFGH-JKLM@invite.example")!)
        var ours = URLRequest(url: invite.nodeBase.appending(path: "castById"))
        invite.authorize(&ours)
        XCTAssertEqual(ours.url?.absoluteString, "https://invite.example/v1/node/castById")
        XCTAssertEqual(ours.value(forHTTPHeaderField: "X-Invite-Code"), "ABCD-EFGH-JKLM")

        for other in ["https://api.farcaster.xyz/v2", "https://invite.example.evil.example/v1", "http://invite.example/v1"] {
            var request = URLRequest(url: URL(string: other)!)
            invite.authorize(&request)
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Invite-Code"), other)
        }
    }

    func testAnInviteCanNameAPortAndAPath() {
        let invite = Connection.invite(Invite(typed: "abc@server.example:8443/fatline/")!)
        XCTAssertEqual(invite.feedBase.absoluteString, "https://server.example:8443/fatline/v1/farcaster")
        XCTAssertEqual(invite.nodeBase.absoluteString, "https://server.example:8443/fatline/v1/node")
    }

    func testAKeyOnlyGoesToItsOwnServers() {
        for address in ["https://api.neynar.com/v2/farcaster/feed", "https://snapchain-api.neynar.com/v1/info"] {
            var request = URLRequest(url: URL(string: address)!)
            neynar.authorize(&request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key", address)
        }
        for address in ["https://api.farcaster.xyz/v2", "https://api.neynar.com.evil.example/v2", "http://api.neynar.com/v2"] {
            var request = URLRequest(url: URL(string: address)!)
            neynar.authorize(&request)
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"), address)
        }
    }

    private func message(_ data: Data) throws -> String? {
        try JSONDecoder().decode([String: String].self, from: data)["message"]
    }

    private let nodeURL = URL(string: "https://snapchain-api.neynar.com/v1/castById")

    func testNodeErrorsReadLikeTheFatlineServers() throws {
        let body = Data(json(["error": "bad", "error_detail": #"status: NotFound, message: "no such \"cast\"""#]).utf8)
        let (data, status) = neynar.nodeAnswer(body, status: 400, for: nodeURL)
        XCTAssertEqual(status, 404)
        XCTAssertEqual(try message(data), #"no such \"cast\""#)
    }

    func testAKeyProblemIsntBlamedOnTheRequest() throws {
        let (data, status) = neynar.nodeAnswer(Data("{}".utf8), status: 402, for: nodeURL)
        XCTAssertEqual(status, 503)
        XCTAssertEqual(try message(data), "Couldn't reach the network.")
    }

    func testOtherAnswersPassThrough() {
        let body = Data("{\"x\":1}".utf8)
        XCTAssertEqual(neynar.nodeAnswer(body, status: 200, for: nodeURL).0, body)
        XCTAssertEqual(neynar.nodeAnswer(body, status: 400, for: URL(string: "https://api.farcaster.xyz/v2/x")).0, body)
        let invite = Connection.invite(Invite(typed: "ABCD@invite.example")!)
        XCTAssertEqual(invite.nodeAnswer(body, status: 400, for: invite.nodeBase).0, body)
    }
}

final class ConnectionChoiceTests: XCTestCase {
    private let feedPage = json(["casts": []])
    private let nodePage = json(["messages": []])
    private let custom = ConnectionChoice.custom(URL(string: "https://node.example")!)
    private let invite = ConnectionChoice.invite(Invite(typed: "ABCD@invite.example")!)

    func testAnAddressBecomesAnHTTPSServer() {
        XCTAssertEqual(ConnectionChoice.custom(typed: " server.example/ "), .custom(URL(string: "https://server.example")!))
        XCTAssertEqual(ConnectionChoice.custom(typed: "https://node.example:3381"), .custom(URL(string: "https://node.example:3381")!))
        for bad in ["", "http://node.example", "https://", "https://me@node.example", "https://node.example?x=1", "https://node.example#x", "node .example"] {
            XCTAssertNil(ConnectionChoice.custom(typed: bad), bad)
        }
    }

    func testAKeyIsTrimmedAndCantHoldSpaces() {
        XCTAssertEqual(ConnectionChoice.neynarKey(typed: " abc-123\n"), .neynarKey("abc-123"))
        XCTAssertNil(ConnectionChoice.neynarKey(typed: "   "))
        XCTAssertNil(ConnectionChoice.neynarKey(typed: "abc 123"))
    }

    func testAChoiceSurvivesBeingSaved() throws {
        for choice in [invite, .neynarKey("abc"), custom, .hypersnap] {
            XCTAssertEqual(try JSONDecoder().decode(ConnectionChoice.self, from: JSONEncoder().encode(choice)), choice)
        }
    }

    func testAKeyIsCheckedAgainstTheFeedAndTheNode() async {
        let server = FakeServer { [feedPage, nodePage] request in
            (200, request.url!.host() == "api.neynar.com" ? feedPage : nodePage)
        }
        let problem = await ConnectionChoice.neynarKey("abc").problem(send: server.send)
        XCTAssertNil(problem)
        XCTAssertEqual(server.requests.map { $0.url!.host() }, ["api.neynar.com", "snapchain-api.neynar.com"])
        XCTAssertEqual(server.requests.map { $0.value(forHTTPHeaderField: "x-api-key") }, ["abc", "abc"])
        XCTAssertEqual(server.requests.first?.query("limit"), "1")
    }

    func testAnInviteIsCheckedAgainstItsServer() async {
        let server = FakeServer { [feedPage, nodePage] request in
            (200, request.url!.path().contains("farcaster") ? feedPage : nodePage)
        }
        let problem = await invite.problem(send: server.send)
        XCTAssertNil(problem)
        XCTAssertEqual(server.requests.map { $0.url!.path() }, ["/v1/farcaster/feed/following/", "/v1/node/userDataByFid"])
        XCTAssertEqual(server.requests.map { $0.url!.host() }, ["invite.example", "invite.example"])
        XCTAssertEqual(server.requests.map { $0.value(forHTTPHeaderField: "X-Invite-Code") }, ["ABCD", "ABCD"])
    }

    func testAnInviteProblemSaysWhich() async {
        for (status, message) in [(401, "Invalid code."), (402, "Limit reached. Try again later.")] {
            let server = FakeServer { _ in (status, "") }
            let problem = await invite.problem(send: server.send)
            XCTAssertEqual(problem, message)
        }
    }

    func testAnInviteKeepsItsCodeExactlyAndNamesOneHTTPSServer() throws {
        let invite = try XCTUnwrap(Invite(typed: " AbCd-1234@Server.Example\n"))
        XCTAssertEqual(invite.code, "AbCd-1234")
        XCTAssertEqual(invite.address, "Server.Example")
        XCTAssertEqual(Invite(typed: invite.text), invite)
        for bad in ["", "  ", "ABCD", "ABCD@", "@server.example", "ABCD EFGH@server.example", "A@B@server.example",
                    "ABCD@http://server.example", "ABCD@server.example?x=1", "ABCD@server.example#x", "AB\r\nX: y@server.example",
                    String(repeating: "A", count: 129) + "@server.example"] {
            XCTAssertNil(Invite(typed: bad), bad)
        }
    }

    func testAnInviteServerWithoutTheRoutesSaysSo() async {
        let server = FakeServer { _ in (404, "") }
        let problem = await invite.problem(send: server.send)
        XCTAssertEqual(problem, "That server can’t build a feed. Fatline needs one that answers Neynar’s feed routes.")
    }

    func testAKeyProblemSaysWhich() async {
        func problem(feed: Int, node: Int = 200) async -> String? {
            let server = FakeServer { [feedPage, nodePage] request in
                request.url!.host() == "api.neynar.com" ? (feed, feedPage) : (node, nodePage)
            }
            return await ConnectionChoice.neynarKey("abc").problem(send: server.send)
        }
        let refused = await problem(feed: 401)
        XCTAssertEqual(refused, "Invalid key.")
        let broke = await problem(feed: 402)
        XCTAssertEqual(broke, "This key is out of credits.")
        let noNode = await problem(feed: 200, node: 403)
        XCTAssertEqual(noNode, "This key can’t use Neynar’s Snapchain node.")
        let busy = await problem(feed: 429)
        XCTAssertEqual(busy, "Too many requests. Try again in a minute.")
    }

    func testHypersnapIsCheckedWithoutAKey() async {
        let server = FakeServer { [feedPage, nodePage] request in
            (200, request.url!.path().hasPrefix("/v2") ? feedPage : nodePage)
        }
        let problem = await ConnectionChoice.hypersnap.problem(send: server.send)
        XCTAssertNil(problem)
        XCTAssertEqual(server.requests.map { $0.url!.host() }, ["haatz.quilibrium.com", "haatz.quilibrium.com"])
        XCTAssertEqual(server.requests.map { $0.url!.path() }, ["/v2/farcaster/feed/following/", "/v1/userDataByFid"])
        XCTAssertEqual(server.requests.map { $0.value(forHTTPHeaderField: "x-api-key") }, [nil, nil])
    }

    func testAServerWithoutAFeedIsTurnedAway() async {
        let missing = FakeServer { _ in (404, "") }
        let noRoute = await custom.problem(send: missing.send)
        XCTAssertEqual(noRoute, "That server can’t build a feed. Fatline needs one that answers Neynar’s feed routes.")

        let webPage = FakeServer { _ in (200, "<html></html>") }
        let notJSON = await custom.problem(send: webPage.send)
        XCTAssertEqual(notJSON, noRoute)

        let feedOnly = FakeServer { [feedPage] request in request.url!.path().hasPrefix("/v2") ? (200, feedPage) : (404, "") }
        let noNode = await custom.problem(send: feedOnly.send)
        XCTAssertEqual(noNode, "That server doesn’t answer Snapchain’s routes, so Fatline can’t post through it.")
    }

    /// Passes the feed and username reads, and answers `signersByFid` with `signers`.
    private func customServer(status: Int = 200, signers: String) -> FakeServer {
        FakeServer { [feedPage, nodePage] request in
            switch request.url!.path() {
            case "/v1/signersByFid": (status, signers)
            case "/v1/userDataByFid": (200, nodePage)
            default: (200, feedPage)
            }
        }
    }

    func testAServerThatCanSignInPasses() async {
        let server = customServer(signers: json(["signers": [["key": "0x01"]], "currentUserNonce": 2]))
        let problem = await custom.problem(send: server.send)
        XCTAssertNil(problem)
        XCTAssertEqual(server.requests.map { $0.url!.path() }, ["/v2/farcaster/feed/following/", "/v1/userDataByFid", "/v1/signersByFid"])
        XCTAssertEqual(server.requests.last?.query("fid"), "1")
        XCTAssertEqual(server.requests.last?.query("pageSize"), "1")
    }

    func testANonceOfZeroPasses() async {
        let server = customServer(signers: json(["signers": [], "currentUserNonce": 0]))
        let problem = await custom.problem(send: server.send)
        XCTAssertNil(problem)
    }

    func testAServerThatCantSignInIsTurnedAway() async {
        let turnedAway = "That server doesn’t answer Snapchain’s routes, so Fatline can’t post through it."
        let answers: [(String, String)] = [
            ("no nonce", json(["signers": []])),
            ("null nonce", #"{"signers":[],"currentUserNonce":null}"#),
            ("nonce as text", json(["signers": [], "currentUserNonce": "0"])),
            ("nonce as true or false", #"{"signers":[],"currentUserNonce":false}"#),
            ("no signers", json(["currentUserNonce": 0])),
            ("signers not a list", json(["signers": "none", "currentUserNonce": 0])),
            ("not JSON", "<html></html>"),
        ]
        for (name, answer) in answers {
            let server = customServer(signers: answer)
            let problem = await custom.problem(send: server.send)
            XCTAssertEqual(problem, turnedAway, name)
        }
        let missing = customServer(status: 404, signers: "")
        let noRoute = await custom.problem(send: missing.send)
        XCTAssertEqual(noRoute, turnedAway)
    }

    func testAnUnreachableServerSaysSo() async {
        let server = FakeServer { _ in throw URLError(.cannotFindHost) }
        let problem = await custom.problem(send: server.send)
        XCTAssertEqual(problem, "Couldn’t reach that server. Check the address and your internet connection.")
    }

    func testARefusedReadIsToldApartFromAnOutage() {
        for status in [401, 402, 403] {
            XCTAssertEqual(FeedModel.problem(for: FeedHTTPError(status: status), connection: neynar), .refused)
        }
        XCTAssertEqual(FeedModel.problem(for: FeedHTTPError(status: 500)), .unreachable)
        XCTAssertEqual(FeedModel.problem(for: URLError(.timedOut)), .unreachable)
    }

    func testOnlyAnInviteCanRunOutOfItsAllowance() {
        let error = FeedHTTPError(status: 402)
        XCTAssertEqual(FeedModel.problem(for: error, connection: .invite(Invite(typed: "ABCD@invite.example")!)), .limitReached)
        XCTAssertEqual(FeedModel.problem(for: error, connection: neynar), .refused)
    }
}

final class HostileServerTests: XCTestCase {
    func testOverlongTextIsDropped() throws {
        XCTAssertNil(try decodeCast(remote("0xa", extra: ["text": String(repeating: "a", count: 12_001)])))
        XCTAssertNotNil(try decodeCast(remote("0xa", extra: ["text": String(repeating: "a", count: 10_000)])))
    }

    func testAFollowListThatNeverEndsStops() async throws {
        let server = FakeServer { _ in (200, json(["messages": [], "nextPageToken": UUID().uuidString])) }
        let people = try await FeedReader(connection: .neynar(key: "k"), send: server.send).follows(fid: 3)
        XCTAssertEqual(people, [])
        XCTAssertEqual(server.requests.count, 50)
    }

    func testAFollowListThatRepeatsItsTokenStops() async throws {
        let server = FakeServer { _ in (200, json(["messages": [], "nextPageToken": "same"])) }
        _ = try await FeedReader(connection: .neynar(key: "k"), send: server.send).follows(fid: 3)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAHostInAnotherAlphabetIsntALink() {
        XCTAssertFalse(FeedCast.linkedText("see xn--80ak6aa92e.com now").runs.contains { $0.link != nil })
    }

    func testABareAddressOpensOverHTTPS() {
        XCTAssertEqual(FeedCast.linkedText("see example.com now").runs.compactMap(\.link), [URL(string: "https://example.com")!])
        XCTAssertEqual(FeedCast.linkedText("see http://example.com now").runs.compactMap(\.link), [URL(string: "http://example.com")!])
    }

    func testACastCantMakeThousandsOfLinks() {
        let text = (0..<200).map { "a\($0).example.com" }.joined(separator: " ")
        XCTAssertEqual(FeedCast.linkedText(text).runs.compactMap(\.link).count, 20)
    }
}

final class LocalFeedTests: XCTestCase {
    func testACastFromTheFutureIsIgnored() async throws {
        let network = Network([remote("0xa", fid: 10, time: start - 60), remote("0xf", fid: 10, time: start + 86_400)])
        network.change { $0.people = [10] }
        let (feed, _) = make(network, clock: Clock(start))
        let built = try await feed.rebuildPeople()
        XCTAssertEqual(built.file?.casts.map(\.hash), ["0xa"])
    }

    private let start: Int64 = 1_800_000_000
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Network: Sendable {
        struct State {
            var people: [UInt64] = [10]
            var feed: [[String: Any]] = []
            var failFeed = false
            var failList = false
        }

        private let state: OSAllocatedUnfairLock<State>

        init(_ feed: [[String: Any]]) {
            state = OSAllocatedUnfairLock(uncheckedState: State(feed: feed))
        }

        func change(_ body: @Sendable (inout State) -> Void) {
            state.withLockUnchecked { body(&$0) }
        }

        func answer(_ request: URLRequest) -> (Int, String) {
            state.withLockUnchecked { current in
                switch request.url!.path().replacing("/private-path", with: "") {
                case "/v1/linksByFid":
                    if current.failList { return (500, "") }
                    return (200, json(["messages": current.people.map {
                        ["data": ["type": "MESSAGE_TYPE_LINK_ADD", "linkBody": ["type": "follow", "targetFid": $0]]]
                    }]))
                case "/v2/farcaster/user/bulk/":
                    return (200, json(["users": current.people.map { ["fid": $0, "username": "user\($0)"] }]))
                default:
                    return current.failFeed ? (500, "") : (200, page(current.feed))
                }
            }
        }
    }

    private final class Clock: Sendable {
        private let time: OSAllocatedUnfairLock<Date>
        init(_ seconds: Int64) { time = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: TimeInterval(seconds))) }
        var now: Date { time.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private func make(_ network: Network, clock: Clock, connection: Connection = neynar) -> (LocalFeed, FakeServer) {
        let server = FakeServer { network.answer($0) }
        let reader = FeedReader(connection: connection, send: server.send)
        return (LocalFeed(directory: directory, fid: 3, reader: reader, now: { clock.now }), server)
    }

    private func feedLimits(_ server: FakeServer) -> [String?] {
        server.requests.filter { $0.url!.path().hasSuffix("feed/following/") }.map { $0.query("limit") }
    }

    func testAnAccountWithNoListIsAsked() async {
        let (feed, _) = make(Network([]), clock: Clock(start))
        do {
            _ = try await feed.fetch(refreshing: false, etag: nil)
            XCTFail("Expected a 404")
        } catch {
            XCTAssertEqual((error as? FeedHTTPError)?.status, 404)
        }
    }

    func testBuildingTheListReadsTheWholeWindow() async throws {
        let (feed, server) = make(Network([remote("0xa", time: start - 60)]), clock: Clock(start))
        let fetched = try await feed.rebuildPeople()
        XCTAssertEqual(fetched.file?.people, [FeedModel.Person(handle: "user10", id: 10)])
        XCTAssertEqual(fetched.file?.casts.map(\.hash), ["0xa"])
        XCTAssertEqual(fetched.age, 0)
        XCTAssertEqual(feedLimits(server), ["100"])
    }

    func testReadsWaitTheirTurnAndAPullWaitsLess() async throws {
        let clock = Clock(start)
        let (feed, server) = make(Network([remote("0xa", time: start - 60)]), clock: clock)
        _ = try await feed.rebuildPeople()
        server.forget()

        clock.advance(19)
        let unchanged = try await feed.fetch(refreshing: true, etag: nil)
        XCTAssertEqual(unchanged.age, 19)
        XCTAssertTrue(server.requests.isEmpty)

        clock.advance(1)
        _ = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertTrue(server.requests.isEmpty)

        _ = try await feed.fetch(refreshing: true, etag: nil)
        XCTAssertEqual(feedLimits(server), ["10"])
        server.forget()

        clock.advance(44)
        _ = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertTrue(server.requests.isEmpty)
        clock.advance(1)
        _ = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(feedLimits(server), ["10"])
    }

    func testAnUnchangedFeedSendsNoFile() async throws {
        let clock = Clock(start)
        let (feed, _) = make(Network([remote("0xa", time: start - 60)]), clock: clock)
        let first = try await feed.rebuildPeople()
        clock.advance(60)
        let second = try await feed.fetch(refreshing: false, etag: first.etag)
        XCTAssertNil(second.file)
        XCTAssertEqual(second.etag, first.etag)
    }

    func testAPollAddsNewCasts() async throws {
        let clock = Clock(start)
        let network = Network([remote("0xa", time: start - 60)])
        let (feed, _) = make(network, clock: clock)
        let first = try await feed.rebuildPeople()
        clock.advance(60)
        let newCast = remote("0xb", time: start + 30)
        nonisolated(unsafe) let added = newCast
        network.change { $0.feed = [added] }
        let second = try await feed.fetch(refreshing: false, etag: first.etag)
        XCTAssertEqual(second.file?.casts.map(\.hash), ["0xb", "0xa"])
    }

    func testAFullReadComesOnceADay() async throws {
        let clock = Clock(start)
        let (feed, server) = make(Network([remote("0xa", time: start - 60)]), clock: clock)
        _ = try await feed.rebuildPeople()
        server.forget()
        clock.advance(23 * 3600)
        _ = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(feedLimits(server), ["10"])
        server.forget()
        clock.advance(3600)
        _ = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(feedLimits(server), ["100"])
    }

    func testAFullReadRemovesADeletedCast() async throws {
        let clock = Clock(start)
        let network = Network([remote("0xa", time: start - 60), remote("0xb", time: start - 70)])
        let (feed, _) = make(network, clock: clock)
        _ = try await feed.rebuildPeople()
        clock.advance(24 * 3600)
        let kept = remote("0xa", time: start - 60)
        nonisolated(unsafe) let only = kept
        network.change { $0.feed = [only] }
        let fetched = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(fetched.file?.casts.map(\.hash), ["0xa"])
    }

    func testAnUnusuallyShortFullReadRemovesNothing() async throws {
        let clock = Clock(start)
        let casts = (0..<30).map { remote("0x\($0)", time: start - Int64($0) - 60) }
        let network = Network(casts)
        let (feed, _) = make(network, clock: clock)
        _ = try await feed.rebuildPeople()
        clock.advance(24 * 3600)
        network.change { $0.feed = [] }
        let fetched = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(fetched.file?.casts.count, 30)
    }

    func testAFailedReadKeepsTheFeedAndCanRetryRightAway() async throws {
        let clock = Clock(start)
        let network = Network([remote("0xa", time: start - 60)])
        let (feed, server) = make(network, clock: clock)
        let first = try await feed.rebuildPeople()
        clock.advance(60)
        network.change { $0.failFeed = true }
        do {
            _ = try await feed.fetch(refreshing: false, etag: first.etag)
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual((error as? FeedHTTPError)?.status, 500)
        }
        network.change { $0.failFeed = false }
        server.forget()
        let recovered = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(recovered.file?.casts.map(\.hash), ["0xa"])
        XCTAssertEqual(feedLimits(server), ["10"])
    }

    func testAListCanOnlyBeRebuiltEvery30Seconds() async throws {
        let clock = Clock(start)
        let (feed, _) = make(Network([]), clock: clock)
        _ = try await feed.rebuildPeople()
        clock.advance(29)
        do {
            _ = try await feed.rebuildPeople()
            XCTFail("Expected a 429")
        } catch {
            XCTAssertEqual((error as? FeedHTTPError)?.status, 429)
        }
        clock.advance(1)
        _ = try await feed.rebuildPeople()
    }

    func testAFailedListKeepsTheOldOne() async throws {
        let clock = Clock(start)
        let network = Network([remote("0xa", time: start - 60)])
        let (feed, _) = make(network, clock: clock)
        _ = try await feed.rebuildPeople()
        clock.advance(30)
        network.change { $0.failList = true }
        do {
            _ = try await feed.rebuildPeople()
            XCTFail("Expected a failure")
        } catch {}
        clock.advance(30)
        let fetched = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(fetched.file?.people.map(\.id), [10])
        XCTAssertEqual(fetched.file?.casts.map(\.hash), ["0xa"])
    }

    func testAListThatCouldntBeReadYetCountsAsStale() async throws {
        let network = Network([])
        network.change { $0.failFeed = true }
        let (feed, _) = make(network, clock: Clock(start))
        let fetched = try await feed.rebuildPeople()
        XCTAssertEqual(fetched.file?.people.map(\.id), [10])
        XCTAssertEqual(fetched.age, FeedModel.staleAfter)
    }

    func testAnUnfollowLeavesTheFeedAndANewFollowReadsTheWindow() async throws {
        let clock = Clock(start)
        let network = Network([remote("0xa", fid: 10, time: start - 60), remote("0xb", fid: 20, time: start - 70)])
        network.change { $0.people = [10, 20] }
        let (feed, server) = make(network, clock: clock)
        _ = try await feed.rebuildPeople()

        clock.advance(60)
        server.forget()
        network.change { $0.people = [10] }
        let unfollowed = try await feed.rebuildPeople()
        XCTAssertEqual(unfollowed.file?.casts.map(\.hash), ["0xa"])
        XCTAssertEqual(feedLimits(server), ["10"])

        clock.advance(60)
        server.forget()
        network.change { $0.people = [10, 20] }
        let followed = try await feed.rebuildPeople()
        XCTAssertEqual(followed.file?.casts.map(\.hash), ["0xa", "0xb"])
        XCTAssertEqual(feedLimits(server), ["100"])
    }

    func testOldCastsAgeOut() async throws {
        let clock = Clock(start)
        let (feed, _) = make(Network([remote("0xa", time: start - 60)]), clock: clock)
        _ = try await feed.rebuildPeople()
        clock.advance(7 * 24 * 3600)
        let fetched = try await feed.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(fetched.file?.casts ?? [], [])
    }

    private var savedFeed: String {
        get throws { String(decoding: try Data(contentsOf: directory.appending(path: "device-feed.json")), as: UTF8.self) }
    }

    /// A custom server's address can be what lets someone spend its credits.
    func testTheFeedFileDoesntHoldTheServerAddress() async throws {
        let connection = Connection.custom(URL(string: "https://node.example/private-path")!)
        let (feed, _) = make(Network([remote("0xa", time: start - 60)]), clock: Clock(start), connection: connection)
        _ = try await feed.rebuildPeople()
        let saved = try savedFeed
        XCTAssertTrue(saved.contains("0xa"))
        XCTAssertFalse(saved.contains("node.example"))
        XCTAssertFalse(saved.contains("private-path"))
    }

    func testAnAddressSavedByAnEarlierVersionIsRemoved() async throws {
        var earlier = LocalFeed.Saved()
        earlier.source = "https://node.example/private-path/v2/farcaster"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(earlier).write(to: directory.appending(path: "device-feed.json"))
        let connection = Connection.custom(URL(string: "https://node.example/private-path")!)
        let (feed, _) = make(Network([remote("0xa", time: start - 60)]), clock: Clock(start), connection: connection)
        _ = try await feed.rebuildPeople()
        XCTAssertFalse(try savedFeed.contains("private-path"))
    }

    func testChangingServersReplacesTheFeedRightAway() async throws {
        let clock = Clock(start)
        let network = Network([remote("0xa", time: start - 60)])
        let (first, _) = make(network, clock: clock)
        _ = try await first.rebuildPeople()

        let casts = [remote("0xb", time: start - 70)]
        nonisolated(unsafe) let other = casts
        network.change { $0.feed = other }
        let (second, server) = make(network, clock: clock, connection: .custom(URL(string: "https://node.example")!))
        let fetched = try await second.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(fetched.file?.casts.map(\.hash), ["0xb"])
        XCTAssertEqual(feedLimits(server), ["100"])
    }

    func testTheFeedSurvivesARelaunch() async throws {
        let clock = Clock(start)
        let network = Network([remote("0xa", time: start - 60)])
        let (first, _) = make(network, clock: clock)
        _ = try await first.rebuildPeople()
        let (second, server) = make(network, clock: clock)
        let fetched = try await second.fetch(refreshing: false, etag: nil)
        XCTAssertEqual(fetched.file?.casts.map(\.hash), ["0xa"])
        XCTAssertTrue(server.requests.isEmpty, "The read turn carries across launches")
    }
}
