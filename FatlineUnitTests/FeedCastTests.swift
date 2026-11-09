import SwiftUI
import ImageIO
import XCTest
@testable import Fatline

final class UpdateCheckTests: XCTestCase {
    func testComparesVersionsByNumber() {
        XCTAssertTrue(UpdateCheck.isNewer("0.2.0", than: "0.1.1"))
        XCTAssertTrue(UpdateCheck.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.1", than: "0.1.1"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.0", than: "0.1.1"))
    }
}

final class FeedFileTests: XCTestCase {
    private func cast(hash: String, fid: UInt64 = 3, age: Int64 = 60, text: String = "Hello") -> FeedCast {
        FeedCast(hash: hash, fid: fid, time: Int64(Date.now.timeIntervalSince1970) - age, text: text)
    }

    func testDecodesTheServerFile() throws {
        let json = #"""
        {"people":[{"fid":3,"handle":"dwr"}],"casts":[
          {"hash":"0xa","fid":3,"time":1800000000,"text":"Hi","links":["https://example.com/a"],
           "quote":{"fid":2,"handle":"v","text":"Quoted"}},
          {"hash":"0xb","fid":3,"time":1800000001,"text":"Plain"}
        ]}
        """#
        let file = try JSONDecoder().decode(FeedFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.people, [FeedModel.Person(handle: "dwr", id: 3)])
        XCTAssertEqual(file.casts[0].quote?.handle, "v")
        XCTAssertEqual(file.casts[0].webLinks.map(\.absoluteString), ["https://example.com/a"])
        XCTAssertNil(file.casts[1].links)
    }

    func testOnlyWebLinksCanBeOpened() {
        var candidate = cast(hash: "0xa")
        candidate.links = ["https://ok.example", "HTTP://ok.example/b", "javascript:alert(1)", "fatline://approve?token=0x12", "file:///etc/passwd", "not a url", "https://"]
        XCTAssertEqual(candidate.webLinks.map(\.absoluteString), ["https://ok.example", "HTTP://ok.example/b"])
    }

    func testLinkLabelsShowTheRealHost() {
        let labels = [
            "https://www.example.com/a": "example.com/a",
            "https://example.com/": "example.com",
            "https://WWW.example.com": "example.com",
            // Removing every www. would make this one read as paypal.com.
            "https://pwww.aypal.com/login": "pwww.aypal.com/login",
            "https://paypal.com@evil.example/x": "evil.example/x"
        ]
        for (link, label) in labels {
            XCTAssertEqual(FeedCast.label(for: URL(string: link)!), label)
        }
    }

    func testLinksInTheTextOpenTheAddressTheyShow() {
        let text = "Read https://example.com/a. Or example.org/b, mail a@b.example, javascript:alert(1)"
        let linked = FeedCast.linkedText(text)
        XCTAssertEqual(String(linked.characters), text)
        let runs = linked.runs.filter { $0.link != nil }
        XCTAssertEqual(runs.map { String(linked[$0.range].characters) }, ["https://example.com/a", "example.org/b"])
        // A bare address gets a web scheme from the system, and still opens the host it shows.
        XCTAssertEqual(runs.map { $0.link.map(FeedCast.label) }, ["example.com/a", "example.org/b"])
        XCTAssertTrue(runs.allSatisfy { ["https", "http"].contains($0.link?.scheme) })
        XCTAssertTrue(runs.allSatisfy { $0[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] == .single })
    }

    func testTextWithoutLinksIsUnchanged() {
        let text = "Markdown stays **plain** and [so do](brackets)"
        let linked = FeedCast.linkedText(text)
        XCTAssertEqual(String(linked.characters), text)
        XCTAssertTrue(linked.runs.allSatisfy { $0.link == nil })
    }

    func testFarcasterLinkUsesTheHandleAndShortHash() {
        let cast = FeedCast(hash: "0x05e2ff3eafb011607c64ddc159164de23a4ac336", fid: 3, time: 0, text: "Hi")
        XCTAssertEqual(cast.farcasterURL(handle: "dwr")?.absoluteString, "https://farcaster.xyz/dwr/0x05e2ff3e")
        XCTAssertEqual(cast.farcasterURL(handle: "vitalik.eth")?.absoluteString, "https://farcaster.xyz/vitalik.eth/0x05e2ff3e")
    }

    func testNoFarcasterLinkWithoutARealHandle() {
        let cast = FeedCast(hash: "0x05e2ff3eafb011607c64ddc159164de23a4ac336", fid: 3, time: 0, text: "Hi")
        XCTAssertNil(cast.farcasterURL(handle: "3"))
        XCTAssertNil(cast.farcasterURL(handle: ""))
        XCTAssertNil(cast.farcasterURL(handle: "a/b"))
        XCTAssertNil(FeedCast(hash: "0x1", fid: 3, time: 0, text: "Hi").farcasterURL(handle: "dwr"))
    }

    func testShortAgesCountUp() {
        let posted = cast(hash: "0xa", age: 0)
        let at = { (seconds: TimeInterval) in posted.shortAge(at: posted.date.addingTimeInterval(seconds)) }
        XCTAssertEqual(at(-30), "Now")
        XCTAssertEqual(at(59), "Now")
        XCTAssertEqual(at(60), "1m")
        XCTAssertEqual(at(3 * 3600 + 5), "3h")
        XCTAssertEqual(at(2 * 86400), "2d")
        XCTAssertEqual(at(8 * 86400), posted.date.formatted(.dateTime.month(.abbreviated).day()))
    }

    func testBlankCastsAreLeftOutUnlessSomethingCanBeShown() {
        XCTAssertFalse(cast(hash: "0xa", text: "  ").isReadable)
        var link = cast(hash: "0xb", text: "")
        link.links = ["https://ok.example"]
        XCTAssertTrue(link.isReadable)
        var unsafe = cast(hash: "0xc", text: "")
        unsafe.links = ["javascript:alert(1)"]
        XCTAssertFalse(unsafe.isReadable)
        var quote = cast(hash: "0xd", text: "")
        quote.quote = .init(fid: 2, handle: "v", text: "Quoted")
        XCTAssertTrue(quote.isReadable)
    }

    func testOnlyCastsWithinFiveMinutesInTheFutureAreKept() {
        XCTAssertTrue(cast(hash: "0xa", age: -200).isReadable)
        XCTAssertFalse(cast(hash: "0xb", age: -600).isReadable)
    }

    func testFeedIsNewestFirstWithoutHiddenPeopleOrRepeats() {
        let newest = cast(hash: "0xa", age: 10)
        let older = cast(hash: "0xb", age: 20)
        let hidden = cast(hash: "0xc", fid: 4, age: 5)
        let feed = FeedModel.feed(from: [older, newest, newest, hidden], allowed: [3])
        XCTAssertEqual(feed.map(\.hash), ["0xa", "0xb"])
    }

    func testNewerSortsByTimeThenHash() {
        let time: Int64 = 1_800_000_000
        let left = FeedCast(hash: "0xa", fid: 3, time: time, text: "a")
        let right = FeedCast(hash: "0xb", fid: 3, time: time, text: "b")
        XCTAssertTrue(FeedModel.newer(left, right))
        XCTAssertFalse(FeedModel.newer(right, left))
        XCTAssertTrue(FeedModel.newer(FeedCast(hash: "0xz", fid: 3, time: time + 1, text: "c"), left))
    }
}

private actor FetchLog {
    struct Call: Equatable {
        let refreshing: Bool
        let etag: String?
    }

    private(set) var calls: [Call] = []
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ refreshing: Bool, _ etag: String?) {
        calls.append(Call(refreshing: refreshing, etag: etag))
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
final class FeedRefreshTests: XCTestCase {
    private nonisolated static let dwr = FeedModel.Person(handle: "dwr", id: 3)

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private nonisolated static func cast(hash: String, fid: UInt64 = 3, text: String = "Hello") -> FeedCast {
        FeedCast(hash: hash, fid: fid, time: Int64(Date.now.timeIntervalSince1970) - 60, text: text)
    }

    private nonisolated static func fetch(_ hashes: [String] = [], age: TimeInterval = 5, etag: String? = "\"v1\"") -> FeedFetch {
        FeedFetch(file: FeedFile(people: [dwr], casts: hashes.map { cast(hash: $0) }), etag: etag, age: age)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out")
    }

    func testShowsTheFileAndItsPeople() async {
        let model = FeedModel(directory: directory()) { _, _ in Self.fetch(["0xa"]) }
        await model.refresh()
        XCTAssertEqual(model.casts.map(\.hash), ["0xa"])
        XCTAssertEqual(model.people, [Self.dwr])
        XCTAssertNil(model.problem)
    }

    func testOnlyAPullOrAPostRefreshesTheServer() async {
        let log = FetchLog()
        let model = FeedModel(directory: directory()) { refreshing, etag in
            await log.record(refreshing, etag)
            return Self.fetch()
        }
        await model.refresh(reason: "launch")
        await model.refresh(reason: "pull")
        await model.refresh(reason: "post")
        await model.refresh(reason: "foreground")
        let calls = await log.calls
        XCTAssertEqual(calls.map(\.refreshing), [false, true, true, false])
    }

    func testAnUnchangedAnswerKeepsTheCastsAndUpdatesTheAge() async {
        let log = FetchLog()
        let model = FeedModel(directory: directory()) { refreshing, etag in
            await log.record(refreshing, etag)
            if etag == nil { return Self.fetch(["0xa"], age: 900) }
            return FeedFetch(file: nil, etag: etag, age: 3)
        }
        await model.refresh()
        XCTAssertEqual(model.problem, .paused)
        await model.refresh()
        XCTAssertEqual(model.casts.map(\.hash), ["0xa"])
        XCTAssertNil(model.problem)
        let calls = await log.calls
        XCTAssertEqual(calls.map(\.etag), [nil, "\"v1\""])
        XCTAssertLessThan(Date.now.timeIntervalSince(model.lastChecked!), 60)
    }

    func testAFeedIsPausedOnlyOnceItsOldEnough() async {
        let young = FeedModel(directory: directory()) { _, _ in Self.fetch(["0xa"], age: FeedModel.staleAfter - 1) }
        await young.refresh()
        XCTAssertNil(young.problem)
        let old = FeedModel(directory: directory()) { _, _ in Self.fetch(["0xa"], age: FeedModel.staleAfter) }
        await old.refresh()
        XCTAssertEqual(old.problem, .paused)
    }

    func testAFailedRequestKeepsCastsAndClearsOnRecovery() async {
        let log = FetchLog()
        let model = FeedModel(directory: directory()) { refreshing, etag in
            await log.record(refreshing, etag)
            let count = await log.calls.count
            if count == 2 { throw URLError(.notConnectedToInternet) }
            return Self.fetch(["0xa"])
        }
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(model.casts.map(\.hash), ["0xa"])
        XCTAssertEqual(model.problem, .unreachable)
        await model.refresh()
        XCTAssertNil(model.problem)
    }

    func testSavedFeedLoadsAcrossLaunchesWithHiddenPeople() async throws {
        let folder = directory()
        let first = FeedModel(directory: folder) { _, _ in Self.fetch(["0xa"]) }
        await first.start()
        try first.toggleVisibility(Self.dwr)
        XCTAssertTrue(first.casts.isEmpty)
        XCTAssertTrue(first.names.isEmpty)

        let second = FeedModel(directory: folder) { _, _ in throw URLError(.notConnectedToInternet) }
        await second.start()
        XCTAssertEqual(second.people, [Self.dwr])
        XCTAssertTrue(second.isHidden(Self.dwr))
        try second.toggleVisibility(Self.dwr)
        XCTAssertEqual(second.casts.map(\.hash), ["0xa"])
    }

    func testHiddenPeopleSurviveFromTheCurrentBuildsSavedFormat() async throws {
        let folder = directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = #"{"hidden":[3],"casts":{"3":[{"hash":"0xold","data":{"fid":3,"timestamp":1,"castAddBody":{"text":"Old"}}}]}}"#
        try Data(saved.utf8).write(to: folder.appending(path: "feed.json"))
        let log = FetchLog()
        let model = FeedModel(directory: folder) { refreshing, etag in
            await log.record(refreshing, etag)
            return Self.fetch(["0xa"])
        }
        await model.start()
        XCTAssertTrue(model.isHidden(Self.dwr))
        let calls = await log.calls
        XCTAssertEqual(calls.first?.etag, nil)
    }

    // MARK: Follow list

    private nonisolated static let v = FeedModel.Person(handle: "v", id: 2)

    private nonisolated static func listed(_ people: [FeedModel.Person]) -> FeedFetch {
        FeedFetch(file: FeedFile(people: people, casts: []), etag: "\"list\"", age: 0)
    }

    private actor Counter {
        private(set) var count = 0
        func add() { count += 1 }
    }

    func testASignInReadsTheFollowListInsteadOfTheFeed() async {
        let lists = Counter()
        let model = FeedModel(directory: directory(), fetchFeed: { _, _ in
            XCTFail("A sign-in builds the list first")
            return Self.fetch()
        }, fetchPeople: {
            await lists.add()
            return Self.listed([Self.v])
        })
        await model.start(signedIn: true)
        let count = await lists.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.people, [Self.v])
    }

    func testOnlyASignInOrTheButtonReadTheFollowList() async throws {
        let lists = Counter()
        let model = FeedModel(directory: directory(), fetchFeed: { _, _ in Self.fetch(["0xa"]) }, fetchPeople: {
            await lists.add()
            return Self.listed([Self.v])
        })
        await model.start()
        await model.refresh(reason: "foreground")
        await model.refresh(reason: "pull")
        await model.refresh(reason: "post")
        var count = await lists.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.people, [Self.dwr])

        await model.refreshPeople()
        count = await lists.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.people, [Self.v])
        XCTAssertFalse(model.refreshingPeople)
    }

    func testAnAccountWithNoListOnTheServerGetsOne() async {
        let model = FeedModel(directory: directory(), fetchFeed: { _, _ in
            throw FeedHTTPError(status: 404)
        }, fetchPeople: { Self.listed([Self.dwr]) })
        await model.start()
        XCTAssertEqual(model.people, [Self.dwr])
        XCTAssertNil(model.problem)
    }

    func testAFailedListRefreshKeepsTheListAndDoesntFlagTheFeed() async {
        let fails = Counter()
        let model = FeedModel(directory: directory(), fetchFeed: { _, _ in Self.fetch(["0xa"]) }, fetchPeople: {
            await fails.add()
            if await fails.count == 1 { throw FeedHTTPError(status: 429) }
            return Self.listed([Self.v])
        })
        await model.start()
        await model.refreshPeople()
        XCTAssertTrue(model.peopleRefreshFailed)
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.people, [Self.dwr])

        await model.refreshPeople()
        XCTAssertFalse(model.peopleRefreshFailed)
        XCTAssertEqual(model.people, [Self.v])
    }

    func testAFailedSignInReadShowsAProblem() async {
        let model = FeedModel(directory: directory(), fetchFeed: { _, _ in Self.fetch() }, fetchPeople: {
            throw URLError(.notConnectedToInternet)
        })
        await model.start(signedIn: true)
        XCTAssertEqual(model.problem, .unreachable)
        XCTAssertFalse(model.peopleRefreshFailed)
    }

    func testFollowingNoOneIsntAStaleFeed() async {
        let model = FeedModel(directory: directory(), fetchFeed: { _, _ in Self.fetch() }, fetchPeople: {
            FeedFetch(file: FeedFile(people: [], casts: []), etag: "\"list\"", age: FeedModel.staleAfter)
        })
        await model.start(signedIn: true)
        XCTAssertTrue(model.hasLoadedFeed)
        XCTAssertEqual(model.people, [])
        XCTAssertNil(model.problem)
    }

    func testAnEmptyListIsRecheckedOnARefresh() async {
        let lists = Counter()
        let model = FeedModel(directory: directory(), fetchFeed: { _, _ in
            XCTFail("An empty list reads the list, not the feed")
            return Self.fetch()
        }, fetchPeople: {
            await lists.add()
            return Self.listed(await lists.count == 1 ? [] : [Self.v])
        })
        await model.start(signedIn: true)
        XCTAssertEqual(model.people, [])
        await model.refresh(reason: "pull")
        XCTAssertEqual(model.people, [Self.v])
    }

    func testRecheckingAnEmptyListTooSoonIsntAProblem() async {
        let lists = Counter()
        let model = FeedModel(directory: directory(), fetchFeed: { _, _ in Self.listed([]) }, fetchPeople: {
            await lists.add()
            if await lists.count > 1 { throw FeedHTTPError(status: 429) }
            return Self.listed([])
        })
        await model.start(signedIn: true)
        await model.refresh(reason: "pull")
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.people, [])
    }

    func testAFailedRecheckOfAnEmptyListShowsAProblem() async {
        let lists = Counter()
        let model = FeedModel(directory: directory(), fetchFeed: { _, _ in Self.listed([]) }, fetchPeople: {
            await lists.add()
            if await lists.count > 1 { throw URLError(.notConnectedToInternet) }
            return Self.listed([])
        })
        await model.start(signedIn: true)
        await model.refresh(reason: "pull")
        XCTAssertEqual(model.problem, .unreachable)
    }

    func testAQueuedListRefreshIsntReplaced() async throws {
        let log = FetchLog()
        let lists = Counter()
        let model = FeedModel(directory: directory(), fetchFeed: { refreshing, etag in
            await log.record(refreshing, etag)
            await log.wait()
            return Self.fetch()
        }, fetchPeople: {
            await lists.add()
            return Self.listed([Self.v])
        })
        let first = Task { await model.refresh(reason: "launch") }
        try await waitUntil { await log.calls.count == 1 }
        let button = Task { await model.refreshPeople() }
        try await Task.sleep(for: .milliseconds(20))
        let later = Task { await model.refresh(reason: "foreground") }
        try await Task.sleep(for: .milliseconds(20))
        await log.open()
        await first.value
        await button.value
        await later.value
        let count = await lists.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.people, [Self.v])
    }

    func testARepeatedPersonDoesntCrash() async {
        let repeated = FeedFile(people: [Self.dwr, Self.dwr], casts: [])
        let model = FeedModel(directory: directory()) { _, _ in FeedFetch(file: repeated, etag: nil, age: 0) }
        await model.refresh()
        XCTAssertEqual(model.names, [3: "dwr"])
    }

    func testRefreshRequestedDuringARefreshRunsAgain() async throws {
        let log = FetchLog()
        let model = FeedModel(directory: directory()) { refreshing, etag in
            await log.record(refreshing, etag)
            if await log.calls.count == 1 { await log.wait() }
            return Self.fetch(await log.calls.count > 1 ? ["0xnew"] : [], etag: nil)
        }
        let first = Task { await model.refresh(reason: "launch") }
        try await waitUntil { await log.calls.count == 1 }
        let second = Task { await model.refresh(reason: "post") }
        try await Task.sleep(for: .milliseconds(20))
        await log.open()
        await first.value
        await second.value

        XCTAssertEqual(model.casts.map(\.hash), ["0xnew"])
        XCTAssertFalse(model.loading)
        let count = await log.calls.count
        XCTAssertEqual(count, 2)
        XCTAssertTrue(model.diagnostics.contains(" post "))
    }

    func testCancellingTheCallerKeepsTheResults() async throws {
        let log = FetchLog()
        let model = FeedModel(directory: directory()) { refreshing, etag in
            await log.record(refreshing, etag)
            await log.wait()
            return Self.fetch(["0xkept"])
        }
        let refresh = Task { await model.refresh() }
        try await waitUntil { model.loading }
        refresh.cancel()
        await log.open()
        try await waitUntil { !model.loading }
        XCTAssertEqual(model.casts.map(\.hash), ["0xkept"])
    }

    func testDiagnosticsReportCausesWithoutCastText() async throws {
        let log = FetchLog()
        let model = FeedModel(directory: directory(), ownFID: 3) { refreshing, etag in
            await log.record(refreshing, etag)
            switch await log.calls.count {
            case 1: return FeedFetch(file: FeedFile(people: [Self.dwr], casts: [Self.cast(hash: "0xcached", text: "secret words")]), etag: nil, age: 12)
            case 2: throw URLError(.timedOut)
            case 3: throw FeedHTTPError(status: 503)
            default: _ = try JSONDecoder().decode(FeedFile.self, from: Data("{}".utf8)); return Self.fetch()
            }
        }
        for _ in 0..<4 { await model.refresh() }
        let text = model.diagnostics
        XCTAssertTrue(text.contains("updated 1 casts, age 12s"), text)
        XCTAssertTrue(text.contains("failed: URLError -1001"), text)
        XCTAssertTrue(text.contains("failed: HTTP 503"), text)
        XCTAssertTrue(text.contains("failed: decode missing people"), text)
        XCTAssertTrue(text.contains("yours 0xcached"), text)
        XCTAssertTrue(text.contains("Account FID 3"), text)
        XCTAssertFalse(text.contains("secret words"), text)
    }

    func testDiagnosticsKeepRecentRefreshesOnly() async {
        let model = FeedModel(directory: directory()) { _, _ in Self.fetch() }
        for number in 0..<10 { await model.refresh(reason: "run\(number)") }
        XCTAssertTrue(model.diagnostics.contains("run9"))
        XCTAssertTrue(model.diagnostics.contains("run2"))
        XCTAssertFalse(model.diagnostics.contains("run1 "))
    }

    // MARK: Posts

    private func posted(hash: String = "0xposted", fid: UInt64 = 3) -> FeedCast {
        FeedCast(posted: SignedCast(fid: fid, text: "Just posted", hash: hash, bytes: Data()))
    }

    func testPostedCastLeadsTheFeedAndSurvivesARefreshThatLacksIt() async {
        let model = FeedModel(directory: directory()) { _, _ in Self.fetch(["0xold"]) }
        await model.refresh()
        model.addPosted(posted())
        XCTAssertEqual(model.casts.map(\.hash), ["0xposted", "0xold"])
        await model.refresh(reason: "post")
        XCTAssertEqual(model.casts.map(\.hash), ["0xposted", "0xold"])
    }

    func testPostedCastIsReleasedOnceAReadReturnsIt() async {
        let log = FetchLog()
        let model = FeedModel(directory: directory()) { refreshing, etag in
            await log.record(refreshing, etag)
            return Self.fetch(await log.calls.count == 1 ? [] : (await log.calls.count == 2 ? ["0xposted"] : []))
        }
        await model.refresh()
        model.addPosted(posted())
        model.addPosted(posted())
        await model.refresh()
        XCTAssertEqual(model.casts.map(\.hash), ["0xposted"])
        // Released by that read, so a later read that drops the cast also drops it from the feed.
        await model.refresh()
        XCTAssertTrue(model.casts.isEmpty)
    }

    func testPostedCastExpiresWhenNoReadEverReturnsIt() async {
        let model = FeedModel(directory: directory(), postHold: 0) { _, _ in Self.fetch() }
        await model.refresh()
        model.addPosted(posted())
        XCTAssertEqual(model.casts.map(\.hash), ["0xposted"])
        await model.refresh()
        XCTAssertTrue(model.casts.isEmpty)
    }

    func testFailedReadKeepsAnExpiredPostedCast() async {
        let log = FetchLog()
        let model = FeedModel(directory: directory(), postHold: 0) { refreshing, etag in
            await log.record(refreshing, etag)
            if await log.calls.count > 1 { throw URLError(.timedOut) }
            return Self.fetch()
        }
        await model.refresh()
        model.addPosted(posted())
        await model.refresh()
        XCTAssertEqual(model.casts.map(\.hash), ["0xposted"])
    }

    func testPostedCastFromSomeoneOutsideTheFeedIsNotShown() async {
        let model = FeedModel(directory: directory()) { _, _ in Self.fetch() }
        await model.refresh()
        model.addPosted(posted(fid: 1_370_256))
        XCTAssertTrue(model.casts.isEmpty)
    }

    private static let outsider: UInt64 = 1_370_256

    func testOwnPostOutsidePeopleLeadsTheFeedAndStaysAcrossLaunches() async {
        let folder = directory()
        let model = FeedModel(directory: folder, ownFID: Self.outsider, ownHandle: "someone", postHold: 0) { _, _ in
            Self.fetch(["0xold"])
        }
        await model.refresh()
        model.addPosted(posted(fid: Self.outsider))
        XCTAssertEqual(model.casts.map(\.hash), ["0xposted", "0xold"])
        XCTAssertEqual(model.handle(for: Self.outsider), "someone")
        // The shared feed never has it, so no read releases it.
        await model.refresh()
        XCTAssertEqual(model.casts.map(\.hash), ["0xposted", "0xold"])

        let relaunched = FeedModel(directory: folder, ownFID: Self.outsider) { _, _ in Self.fetch(["0xold"]) }
        await relaunched.start()
        XCTAssertEqual(relaunched.casts.map(\.hash), ["0xposted", "0xold"])
    }

    func testOwnPostsOutsidePeopleLeaveWithTheWindow() async {
        let model = FeedModel(directory: directory(), ownFID: Self.outsider) { _, _ in Self.fetch() }
        await model.refresh()
        let weekOld = Int64(Date.now.timeIntervalSince1970 - FeedModel.window - 60)
        model.addPosted(FeedCast(hash: "0xweekold", fid: Self.outsider, time: weekOld, text: "Old"))
        model.addPosted(posted(fid: Self.outsider))
        await model.refresh()
        XCTAssertEqual(model.casts.map(\.hash), ["0xposted"])
    }

    func testOwnAccountHiddenInPeopleStaysHidden() async throws {
        let model = FeedModel(directory: directory(), ownFID: 3) { _, _ in Self.fetch(["0xold"]) }
        await model.refresh()
        try model.toggleVisibility(Self.dwr)
        model.addPosted(posted(fid: 3))
        XCTAssertTrue(model.casts.isEmpty)
    }

    func testDeletedCastLeavesTheFeedAndStaysGoneAcrossLaunches() async {
        let folder = directory()
        let model = FeedModel(directory: folder, ownFID: 3) { _, _ in Self.fetch(["0xmine", "0xold"]) }
        await model.refresh()
        let mine = model.casts.first { $0.hash == "0xmine" }!
        XCTAssertTrue(model.isOwn(mine))
        model.removeDeleted(mine)
        XCTAssertEqual(model.casts.map(\.hash), ["0xold"])
        // The server's file can lag behind the deletion.
        await model.refresh()
        XCTAssertEqual(model.casts.map(\.hash), ["0xold"])

        let relaunched = FeedModel(directory: folder, ownFID: 3) { _, _ in Self.fetch(["0xmine", "0xold"]) }
        await relaunched.start()
        XCTAssertEqual(relaunched.casts.map(\.hash), ["0xold"])
    }

    func testDeletingAPostFromOutsidePeopleRemovesIt() async {
        let model = FeedModel(directory: directory(), ownFID: Self.outsider) { _, _ in Self.fetch() }
        await model.refresh()
        let cast = posted(fid: Self.outsider)
        model.addPosted(cast)
        model.removeDeleted(cast)
        XCTAssertTrue(model.casts.isEmpty)
        XCTAssertFalse(model.isOwn(Self.cast(hash: "0xother")))
    }

    func testPostedCastUsesItsSignedTime() {
        var signed = SignedCast(fid: 3, text: "Hi", hash: "0x1", bytes: Data())
        signed.timestamp = 100
        XCTAssertEqual(FeedCast(posted: signed).time, 1_609_459_300)
    }

    func testPendingCastSavedByAnEarlierBuildStillLoads() throws {
        let saved = Data(#"{"fid":3,"text":"Hi","hash":"0x1","bytes":""}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SignedCast.self, from: saved).timestamp)
    }
}

final class CastImageTests: XCTestCase {
    private func picture(as type: String) throws -> Data {
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), type)
        return data as Data
    }

    func testTheFormatsPeoplePostAreDecoded() throws {
        for type in ["public.jpeg", "public.png", "com.compuserve.gif", "public.heic"] {
            XCTAssertNotNil(CastImages.decode(try picture(as: type), maxPixels: 32), type)
        }
    }

    func testOtherFormatsAreRefusedEvenWhenMacOSCouldReadThem() throws {
        for type in ["public.tiff", "com.microsoft.bmp", "com.adobe.photoshop-image"] {
            XCTAssertNil(CastImages.decode(try picture(as: type), maxPixels: 32), type)
        }
        XCTAssertNil(CastImages.decode(Data("not a picture".utf8), maxPixels: 32))
    }

    func testARedirectIsHeldToTheSameRulesAsTheCast() async throws {
        let redirects = CastImages.Redirects()
        let start = try XCTUnwrap(URL(string: "https://example.com/a.png"))
        let response = try XCTUnwrap(HTTPURLResponse(url: start, statusCode: 302, httpVersion: nil, headerFields: nil))
        let task = URLSession.shared.dataTask(with: start)

        func answer(_ address: String) async throws -> URL? {
            let next = URLRequest(url: try XCTUnwrap(URL(string: address)))
            return await redirects.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: next)?.url
        }

        for address in ["http://example.com/a.png", "https://localhost/a.png", "https://127.0.0.1/a.png", "https://192.168.1.1/a.png", "https://[::1]/a.png", "https://printer.local/a.png", "https://router/a.png"] {
            let followed = try await answer(address)
            XCTAssertNil(followed, address)
        }
        let followed = try await answer("https://cdn.example.com/b.png")
        XCTAssertEqual(followed?.absoluteString, "https://cdn.example.com/b.png")
    }
}
