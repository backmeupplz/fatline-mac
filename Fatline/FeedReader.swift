import CryptoKit
import Foundation
import os

/// Skips a row the app can't read instead of failing the page it came in.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) {
        value = try? Value(from: decoder)
    }
}

/// A cast in Neynar's format. Other servers answer in the same one, with the differences noted in `FeedReader`.
struct RemoteCast: Decodable {
    struct Author: Decodable {
        let fid: UInt64
        let username: String?
        let pfpUrl: String?
    }

    struct Profile: Decodable {
        let username: String?
    }

    struct Range: Decodable {
        let start: Int
        let end: Int
    }

    struct Embed: Decodable {
        struct Metadata: Decodable {
            let contentType: String?
        }

        struct Quoted: Decodable {
            let text: String?
            let author: Author?
        }

        let url: String?
        let metadata: Metadata?
        let cast: Quoted?
    }

    let hash: String
    let text: String?
    let timestamp: String
    let parentHash: String?
    let author: Author
    let mentionedProfiles: [Profile]?
    let mentionedProfilesRanges: [Range]?
    fileprivate let embeds: [Lossy<Embed>]?
}

/// Reads who an account follows and what they've posted from a server that speaks Neynar's API.
///
/// Other servers can differ from Neynar in four ways, all handled here: hashes have no `0x`, mentions aren't written
/// into the text, a quote is only an ID so it's left out, and replies come back in the feed.
struct FeedReader: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    struct Read: Sendable {
        var casts: [FeedCast] = []
        var handles: [UInt64: String] = [:]
        var latestSeen: Int64 = 0
        /// False if a full read ran out of pages before reaching the end of the window.
        var complete = true
    }

    /// Neynar charges for the casts a page could return, so a short page keeps an unchanged feed cheap.
    static let pollLimit = 10
    /// A poll that runs out of pages leaves a gap, which the next full read fills.
    static let pollMaxPages = 10
    static let windowLimit = 100
    static let windowMaxPages = 8
    /// A cast can arrive slightly out of order, so a poll reads a little past the last one it saw.
    static let pollOverlapSeconds: Int64 = 120
    static let maxFollows = 3500
    private static let timeout: TimeInterval = 15
    private static let linksPageSize = 1000
    private static let maxLinkPages = 50
    /// The longest cast the network allows is 10,000 bytes, and writing out mentions adds a little.
    private static let maxCastBytes = 12_000
    private static let maxHandleBytes = 64
    private static let maxLinks = 4
    private static let maxImages = 4
    private static let maxLinkBytes = 2048
    private static let usersPerCall = 100
    private static let userCallsAtOnce = 5
    private static let mediaHosts: Set<String> = ["imagedelivery.net", "stream.farcaster.xyz", "media.tenor.com", "media1.tenor.com", "media.firefly.land", "i.imgur.com"]
    private static let mediaExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "svg", "mp4", "mov", "webm", "m3u8", "mp3", "m4a", "wav"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic"]

    let connection: Connection
    var send: Send = { try await HTTP.loadResponse($0) }

    private func get<Answer: Decodable>(_ base: URL, _ path: String, _ query: [String: String]) async throws -> Answer {
        var request = HTTP.getRequest(base, path, query, timeout: Self.timeout)
        connection.authorize(&request)
        let (data, response) = try await send(request)
        // A 404 from upstream isn't the app's signal that an account has no follow list yet.
        guard response.statusCode == 200 else { throw FeedHTTPError(status: response.statusCode == 404 ? 502 : response.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Answer.self, from: data)
    }

    private struct FeedPage: Decodable {
        struct Next: Decodable { let cursor: String? }
        let casts: [Lossy<RemoteCast>]
        let next: Next?
    }

    private func followingPage(fid: UInt64, limit: Int, cursor: String?) async throws -> (casts: [RemoteCast], cursor: String?) {
        var query = ["fid": String(fid), "with_recasts": "false", "limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        let page: FeedPage = try await get(connection.feedBase, "feed/following/", query)
        return (page.casts.compactMap(\.value), page.next?.cursor)
    }

    /// Reads this account's following feed back until it overlaps the last read.
    func poll(fid: UInt64, since latestSeen: Int64, follows: Set<UInt64>) async throws -> Read {
        var read = Read()
        var cursor: String?
        for _ in 0..<Self.pollMaxPages {
            let page = try await followingPage(fid: fid, limit: Self.pollLimit, cursor: cursor)
            Self.collect(&read, page.casts, follows: follows)
            cursor = page.cursor
            guard cursor != nil, let oldest = page.casts.last.flatMap({ Self.seconds($0.timestamp) }),
                  oldest > latestSeen - Self.pollOverlapSeconds else { break }
        }
        return read
    }

    /// Reads everything back to `oldestAllowed`.
    func window(fid: UInt64, oldestAllowed: Int64, follows: Set<UInt64>) async throws -> Read {
        var read = Read()
        var cursor: String?
        for _ in 0..<Self.windowMaxPages {
            let page = try await followingPage(fid: fid, limit: Self.windowLimit, cursor: cursor)
            Self.collect(&read, page.casts, follows: follows)
            cursor = page.cursor
            guard cursor != nil, let oldest = page.casts.last.flatMap({ Self.seconds($0.timestamp) }), oldest >= oldestAllowed else {
                return read
            }
        }
        read.complete = false
        return read
    }

    private struct LinksPage: Decodable {
        struct Message: Decodable {
            struct Payload: Decodable {
                struct Link: Decodable {
                    let type: String?
                    let targetFid: UInt64?
                }
                let type: String?
                let linkBody: Link?
            }
            let data: Payload?
        }
        let messages: [Message]
        let nextPageToken: String?
    }

    /// Everyone this account follows on the network, sorted by FID. A failed read throws.
    func follows(fid: UInt64) async throws -> [FeedModel.Person] {
        var targets = Set<UInt64>()
        var token: String?
        var pages = 0
        repeat {
            pages += 1
            var query = ["fid": String(fid), "link_type": "follow", "pageSize": String(Self.linksPageSize)]
            if let token { query["pageToken"] = token }
            let page: LinksPage = try await get(connection.nodeBase, "linksByFid", query)
            for message in page.messages where message.data?.type == "MESSAGE_TYPE_LINK_ADD" && message.data?.linkBody?.type == "follow" {
                if let target = message.data?.linkBody?.targetFid { targets.insert(target) }
            }
            let next = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
            token = next == token ? nil : next
        } while token != nil && targets.count < Self.maxFollows && pages < Self.maxLinkPages
        let fids = Array(targets.sorted().prefix(Self.maxFollows))
        let names = try await handles(for: fids)
        return fids.map { FeedModel.Person(handle: names[$0] ?? String($0), id: $0) }
    }

    private struct UsersPage: Decodable {
        struct User: Decodable {
            let fid: UInt64
            let username: String?
        }
        let users: [User]
    }

    private func handles(for fids: [UInt64]) async throws -> [UInt64: String] {
        let calls = stride(from: 0, to: fids.count, by: Self.usersPerCall).map { Array(fids[$0..<min($0 + Self.usersPerCall, fids.count)]) }
        var names: [UInt64: String] = [:]
        for start in stride(from: 0, to: calls.count, by: Self.userCallsAtOnce) {
            let batch = calls[start..<min(start + Self.userCallsAtOnce, calls.count)]
            try await withThrowingTaskGroup(of: [UsersPage.User].self) { group in
                for call in batch {
                    group.addTask {
                        let page: UsersPage = try await get(connection.feedBase, "user/bulk/", ["fids": call.map(String.init).joined(separator: ",")])
                        return page.users
                    }
                }
                for try await users in group {
                    for user in users {
                        if let handle = Self.usableHandle(user.username) { names[user.fid] = handle }
                    }
                }
            }
        }
        return names
    }

    private static func collect(_ read: inout Read, _ casts: [RemoteCast], follows: Set<UInt64>) {
        for cast in casts where follows.contains(cast.author.fid) {
            if let time = seconds(cast.timestamp) { read.latestSeen = max(read.latestSeen, time) }
            if let handle = usableHandle(cast.author.username) { read.handles[cast.author.fid] = handle }
            if let kept = feedCast(from: cast) { read.casts.append(kept) }
        }
    }

    /// Neynar writes an account that has no username as `!` and its FID.
    private static func usableHandle(_ username: String?) -> String? {
        guard let username, !username.isEmpty, !username.hasPrefix("!"), username.utf8.count <= maxHandleBytes else { return nil }
        return username
    }

    static func seconds(_ timestamp: String) -> Int64? {
        let exact = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let date = (try? exact.parse(timestamp)) ?? (try? Date.ISO8601FormatStyle().parse(timestamp)) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }

    /// Keeps only what the app shows. Returns nil for a reply, or a cast with nothing to show.
    static func feedCast(from cast: RemoteCast) -> FeedCast? {
        guard cast.parentHash?.isEmpty != false, let time = seconds(cast.timestamp) else { return nil }
        let text = writingOutMentions(in: cast).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= maxCastBytes else { return nil }
        let embeds = (cast.embeds ?? []).compactMap(\.value)
        let links = Array(embeds.filter(isReadableLink).compactMap(\.url).filter { $0.utf8.count <= maxLinkBytes && !isIn(text, $0) }.prefix(maxLinks))
        var quote: FeedCast.Quote?
        if let quoted = embeds.compactMap(\.cast).first, let author = quoted.author,
           let quotedText = quoted.text?.trimmingCharacters(in: .whitespacesAndNewlines), !quotedText.isEmpty,
           quotedText.utf8.count <= maxCastBytes {
            quote = FeedCast.Quote(fid: author.fid, handle: usableHandle(author.username) ?? String(author.fid), text: quotedText)
        }
        let images = Array(embeds.filter(isImage).compactMap(\.url).filter { $0.utf8.count <= maxLinkBytes }.prefix(maxImages))
        guard !text.isEmpty || !links.isEmpty || !images.isEmpty || quote != nil else { return nil }
        let hash = cast.hash.lowercased()
        return FeedCast(
            hash: hash.hasPrefix("0x") ? hash : "0x" + hash,
            fid: cast.author.fid,
            time: time,
            text: text,
            links: links.isEmpty ? nil : links,
            quote: quote,
            avatar: cast.author.pfpUrl.flatMap { $0.utf8.count <= maxLinkBytes ? $0 : nil },
            images: images.isEmpty ? nil : images
        )
    }

    /// A picture the app can show. When Neynar hasn't inspected the link yet there's no type, so its address decides.
    private static func isImage(_ embed: RemoteCast.Embed) -> Bool {
        guard let link = embed.url, let url = URL(string: link), url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased() else { return false }
        if let type = embed.metadata?.contentType?.lowercased(), !type.isEmpty {
            return type.hasPrefix("image/") && !type.hasPrefix("image/svg")
        }
        return host == "imagedelivery.net" || imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Neynar's text already has each mention, and its range covers it. The network's own text leaves a
    /// gap, marked by an empty range at that UTF-8 offset, which is filled here from the last one back so
    /// earlier offsets stay right.
    private static func writingOutMentions(in cast: RemoteCast) -> String {
        let text = cast.text ?? ""
        let missing = zip(cast.mentionedProfiles ?? [], cast.mentionedProfilesRanges ?? []).filter { $0.1.start == $0.1.end }
        guard !missing.isEmpty else { return text }
        var bytes = Array(text.utf8)
        for (profile, range) in missing.sorted(by: { $0.1.start > $1.1.start }) {
            guard let handle = usableHandle(profile.username), (0...bytes.count).contains(range.start) else { continue }
            bytes.insert(contentsOf: Array("@\(handle)".utf8), at: range.start)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Neynar usually hasn't inspected a link when a cast is read, so media is recognized by its URL too.
    private static func isReadableLink(_ embed: RemoteCast.Embed) -> Bool {
        guard let link = embed.url, let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host()?.lowercased(),
              !mediaHosts.contains(host), !mediaExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let type = embed.metadata?.contentType?.lowercased() ?? ""
        return !type.hasPrefix("image/") && !type.hasPrefix("video/") && !type.hasPrefix("audio/")
    }

    private static func isIn(_ text: String, _ link: String) -> Bool {
        text.contains(link.replacing(#/^https?:\/\//#.ignoresCase(), with: ""))
    }
}

/// An account's feed, kept on this Mac and read from the network when the app asks. `FeedModel` runs
/// one refresh at a time, so reads here don't overlap.
actor LocalFeed {
    struct Saved: Codable {
        var file = FeedFile(people: [], casts: [])
        /// A hash of the server this copy came from, because a custom server's address can be its only credential.
        var source: String?
        var hasList = false
        var checkedAt: Date?
        /// Newest cast time seen from anyone, in Unix seconds.
        var latestSeen: Int64 = 0
        var lastRead: Date?
        var lastFull: Date?
        var lastPeople: Date?
        /// Nil in a copy saved before casts carried avatars and images.
        var hasMedia: Bool?
    }

    static let readGap: TimeInterval = 45
    static let refreshGap: TimeInterval = 20
    static let peopleGap: TimeInterval = 30
    /// A full read is how casts deleted in other apps leave the feed.
    static let fullReadEvery: TimeInterval = 24 * 60 * 60
    static let windowSeconds: TimeInterval = 7 * 24 * 60 * 60
    static let maxCasts = 1000
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Fatline", category: "feed")

    private let path: URL
    private let fid: UInt64
    private let reader: FeedReader
    private let now: @Sendable () -> Date
    private var saved: Saved
    private var saveFailed = false

    init(directory: URL, fid: UInt64, reader: FeedReader, now: @escaping @Sendable () -> Date = { Date.now }) {
        path = directory.appending(path: "device-feed.json")
        self.fid = fid
        self.reader = reader
        self.now = now
        var loaded = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        let source = Data(SHA256.hash(data: Data(reader.connection.feedBase.absoluteString.utf8))).hex
        if loaded.source != source {
            // Servers don't hold the same casts, and one server's answers shouldn't outlive it.
            loaded.source = source
            loaded.file.casts = []
            loaded.latestSeen = 0
            loaded.lastRead = nil
            loaded.lastFull = nil
        }
        if loaded.hasMedia != true {
            // An older copy has no avatars or images, so the next read replaces it.
            loaded.hasMedia = true
            loaded.lastRead = nil
            loaded.lastFull = nil
        }
        saved = loaded
    }

    private func isDue(_ last: Date?, _ gap: TimeInterval) -> Bool {
        now().timeIntervalSince(last ?? .distantPast) >= gap
    }

    /// An account with no list yet gets a 404, which is how the app knows to build one.
    func fetch(refreshing: Bool, etag: String?) async throws -> FeedFetch {
        guard saved.hasList else { throw FeedHTTPError(status: 404) }
        if isDue(saved.lastRead, refreshing ? Self.refreshGap : Self.readGap) {
            try await read(full: isDue(saved.lastFull, Self.fullReadEvery))
        }
        return try answer(etag: etag)
    }

    /// Reads who this account follows and rebuilds the feed around that. Only a failed read of the list
    /// throws, and it keeps the old list.
    func rebuildPeople() async throws -> FeedFetch {
        guard isDue(saved.lastPeople, Self.peopleGap) else { throw FeedHTTPError(status: 429) }
        saved.lastPeople = now()
        store()
        let people = try await reader.follows(fid: fid)
        let before = Set(saved.file.people.map(\.id))
        let added = !saved.hasList || people.contains { !before.contains($0.id) }
        saved.hasList = true
        saved.file.people = people
        saved.file.casts = tidy(saved.file.casts)
        store()
        do {
            // Someone new on the list has casts a poll wouldn't reach.
            if added {
                try await read(full: true)
            } else if isDue(saved.lastRead, Self.readGap) {
                try await read(full: isDue(saved.lastFull, Self.fullReadEvery))
            }
        } catch {
            // The list is still good. The feed's age shows it's behind.
            Self.logger.log("read after list failed: \(FeedModel.describe(error), privacy: .public)")
        }
        return try answer(etag: nil)
    }

    private func read(full: Bool) async throws {
        guard !saved.file.people.isEmpty else { return }
        let time = now()
        let follows = Set(saved.file.people.map(\.id))
        let result: FeedReader.Read
        if full {
            let oldest = Int64(time.timeIntervalSince1970 - Self.windowSeconds)
            result = try await reader.window(fid: fid, oldestAllowed: oldest, follows: follows)
            let replacement = tidy(result.casts)
            // An unusually short read is treated as a bad one, because real deletions can wait.
            let trusted = result.complete && (saved.file.casts.count < 20 || replacement.count * 2 >= saved.file.casts.count)
            saved.file.casts = trusted ? replacement : tidy(saved.file.casts + result.casts)
            saved.lastFull = time
        } else {
            result = try await reader.poll(fid: fid, since: saved.latestSeen, follows: follows)
            saved.file.casts = tidy(saved.file.casts + result.casts)
        }
        saved.file.people = saved.file.people.map { FeedModel.Person(handle: result.handles[$0.id] ?? $0.handle, id: $0.id) }
        saved.latestSeen = max(saved.latestSeen, min(result.latestSeen, latestAllowed))
        saved.lastRead = time
        saved.checkedAt = time
        store()
    }

    /// Drops casts that aged out or came from someone this account doesn't follow, then keeps the newest.
    /// A little past now, for clocks that disagree. Anything later would sit at the top of the feed for good.
    private var latestAllowed: Int64 { Int64(now().timeIntervalSince1970) + 300 }

    private func tidy(_ casts: [FeedCast]) -> [FeedCast] {
        let oldest = Int64(now().timeIntervalSince1970 - Self.windowSeconds)
        let follows = Set(saved.file.people.map(\.id))
        var byHash: [String: FeedCast] = [:]
        let newest = latestAllowed
        for cast in casts where cast.time >= oldest && cast.time <= newest && follows.contains(cast.fid) { byHash[cast.hash] = cast }
        return Array(byHash.values.sorted(by: FeedModel.newer).prefix(Self.maxCasts))
    }

    private func answer(etag: String?) throws -> FeedFetch {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let tag = Data(SHA256.hash(data: try encoder.encode(saved.file))).hex
        // A list with no successful read yet counts as stale, so the app says the feed is behind.
        let age = saved.checkedAt.map { max(0, now().timeIntervalSince($0)) } ?? FeedModel.staleAfter
        return FeedFetch(file: etag == tag ? nil : saved.file, etag: tag, age: age)
    }

    private func store() {
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: path, options: .atomic)
        } catch {
            Self.logger.log("couldn't save the feed: \(FeedModel.describe(error), privacy: .public)")
        }
    }
}
