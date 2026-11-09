import Foundation
import Observation
import os

/// One feed refresh, as reported by Copy Diagnostics. It holds counts, ages, and a public cast hash,
/// and never cast text or anything related to keys.
struct FeedRefreshRecord: Sendable {
    let reason: String
    let started: Date
    let seconds: Double
    let outcome: String
    let newestOwnCast: String?
}

struct FeedHTTPError: Error {
    let status: Int
}

struct FeedCast: Codable, Hashable, Identifiable, Sendable {
    struct Quote: Codable, Hashable, Sendable {
        let fid: UInt64
        let handle: String
        let text: String
    }

    let hash: String
    let fid: UInt64
    /// Unix seconds.
    let time: Int64
    let text: String
    var links: [String]? = nil
    var quote: Quote? = nil
    /// The author's profile picture at the time this cast was read.
    var avatar: String? = nil
    /// Pictures attached to the cast. Video and other attachments are left out when it's read.
    var images: [String]? = nil

    var id: String { hash }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }

    var avatarURL: URL? { avatar.flatMap(Self.imageURL) }
    var imageURLs: [URL] { (images ?? []).compactMap(Self.imageURL) }

    /// A picture's author chooses its address, so only HTTPS to a named public host is fetched. That
    /// keeps a cast from making this Mac call something on its own network.
    static func imageURL(_ link: String) -> URL? {
        guard let url = URL(string: link), url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(),
              host.contains("."), host.contains(where: \.isLetter), !host.contains(":"),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal") else { return nil }
        return url
    }

    /// Web links that can be opened safely. The server only sends these, and this checks again.
    var webLinks: [URL] {
        (links ?? []).compactMap { link in
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", url.host() != nil else { return nil }
            return url
        }
    }

    var isReadable: Bool {
        date <= .now.addingTimeInterval(300) &&
            (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !webLinks.isEmpty || !imageURLs.isEmpty || quote != nil)
    }
}

extension FeedCast {
    /// What a link shows. Only a leading www. comes off, so a label can't be made to read as another site.
    static func label(for url: URL) -> String {
        let host = url.host() ?? ""
        let shown = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return shown + (url.path() == "/" ? "" : url.path())
    }

    /// The cast on Farcaster's website, which opens the Farcaster app when it's installed. Nil when the
    /// handle is only a stand-in FID or has characters a username can't have.
    func farcasterURL(handle: String) -> URL? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard !handle.isEmpty, handle != String(fid), handle.lowercased().allSatisfy(allowed.contains),
              hash.hasPrefix("0x"), hash.count >= 10 else { return nil }
        return URL(string: "https://farcaster.xyz/\(handle.lowercased())/\(hash.prefix(10).lowercased())")
    }

    /// The feed's short timestamp, such as Now, 5m, 3h, or 2d.
    func shortAge(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        if seconds < 604800 { return "\(seconds / 86400)d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The feed row for a cast just posted from this Mac. A pending cast with no timestamp uses the
    /// current time.
    init(posted cast: SignedCast) {
        let timestamp = cast.timestamp ?? (try? SnapchainMessage.timestamp()) ?? 0
        self.init(hash: cast.hash, fid: cast.fid, time: 1_609_459_200 + Int64(timestamp), text: cast.text)
    }
}

/// This account's feed: who it follows, and their recent casts.
struct FeedFile: Codable, Sendable {
    var people: [FeedModel.Person]
    var casts: [FeedCast]
}

struct FeedFetch: Sendable {
    /// Nil when this Mac already has this version.
    let file: FeedFile?
    let etag: String?
    /// How long ago the network was last read successfully.
    let age: TimeInterval
}

@MainActor
@Observable
final class FeedModel {
    struct Person: Codable, Hashable, Identifiable, Sendable {
        let handle: String
        let id: UInt64

        enum CodingKeys: String, CodingKey {
            case handle
            case id = "fid"
        }
    }

    /// Why the feed on screen may be behind. The feed keeps showing what it has in both cases.
    enum Problem: Equatable {
        /// There's a follow list, but the network hasn't been read successfully for a while.
        case paused
        /// This Mac couldn't reach the server.
        case unreachable
        /// The server turned the request down, which usually means a bad key or no credits left.
        case refused
        /// This invite code has used its allowance for now.
        case limitReached
    }

    private struct Snapshot: Codable {
        var hidden: Set<UInt64> = []
        var people: [Person]?
        var feedCasts: [FeedCast]?
        var etag: String?
        var checkedAt: Date?
        /// Posts from this Mac by an account that doesn't follow itself. Its feed never has them, so
        /// they're kept here for as long as the feed keeps everyone else's.
        var ownPosts: [FeedCast]?
        /// Casts this account deleted from this Mac, by hash, with each cast's time. A read can lag
        /// behind a deletion, so these stay filtered for as long as the feed could still have them.
        var deleted: [String: Int64]?
    }

    private static let signIn = "sign-in"
    private static let peopleButton = "people"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Fatline", category: "feed")
    private static let historyLimit = 8
    /// The server reads the network when this Mac asks, so this old an answer means it couldn't.
    nonisolated static let staleAfter: TimeInterval = 10 * 60
    /// The server's feed covers the same 7 days.
    nonisolated static let window: TimeInterval = 7 * 24 * 60 * 60

    private let file: URL
    private let ownFID: UInt64?
    private let ownHandle: String?
    private let fetchFeed: @Sendable (_ refreshing: Bool, _ etag: String?) async throws -> FeedFetch
    private let fetchPeople: @Sendable () async throws -> FeedFetch
    private var snapshot = Snapshot()
    private var didLoad = false
    private var lastRefresh: Date?
    private(set) var loading = false
    private var refreshTask: Task<Void, Never>?
    private var queuedRefreshReason: String?
    private var history: [FeedRefreshRecord] = []
    private var saveFailed = false
    private(set) var problem: Problem?
    private(set) var refreshingPeople = false
    private(set) var peopleRefreshFailed = false
    private var heldPosts: [HeldPost] = []
    private let postHold: TimeInterval

    /// The node can accept a cast before the server's read returns it. A post stays here until a read
    /// returns it, or until the hold runs out so a cast the network never kept can't stay in the feed.
    private struct HeldPost {
        let cast: FeedCast
        let added: Date
    }

    init(directory: URL, ownFID: UInt64? = nil, ownHandle: String? = nil, postHold: TimeInterval = 120,
         fetchFeed: (@Sendable (_ refreshing: Bool, _ etag: String?) async throws -> FeedFetch)? = nil,
         fetchPeople: (@Sendable () async throws -> FeedFetch)? = nil) {
        file = directory.appending(path: "feed.json")
        self.ownFID = ownFID
        self.ownHandle = ownHandle
        self.postHold = postHold
        let local = ownFID.map { LocalFeed(directory: directory, fid: $0, reader: FeedReader(connection: .current)) }
        self.fetchFeed = fetchFeed ?? { refreshing, etag in
            guard let local else { throw FeedHTTPError(status: 400) }
            return try await local.fetch(refreshing: refreshing, etag: etag)
        }
        self.fetchPeople = fetchPeople ?? {
            guard let local else { throw FeedHTTPError(status: 400) }
            return try await local.rebuildPeople()
        }
    }

    var people: [Person] { snapshot.people ?? [] }
    var hasLoadedFeed: Bool { snapshot.people != nil }
    /// When the server last read the network successfully, as of the most recent answer.
    var lastChecked: Date? { snapshot.checkedAt }

    var names: [UInt64: String] {
        Dictionary(people.filter { !isHidden($0) }.map { ($0.id, $0.handle) }) { first, _ in first }
    }

    var status: String? {
        saveFailed ? "Couldn’t save the feed on this Mac." : nil
    }

    var casts: [FeedCast] {
        let all = (snapshot.feedCasts ?? []) + heldPosts.map(\.cast) + (snapshot.ownPosts ?? [])
        return Self.feed(from: all, allowed: allowedFIDs, excluding: Set((snapshot.deleted ?? [:]).keys))
    }

    func isOwn(_ cast: FeedCast) -> Bool { cast.fid == ownFID }

    /// Everyone in People who isn't hidden, plus this account if it's outside People, where it has no
    /// Hide button. An account in People that hid itself stays hidden.
    private var allowedFIDs: Set<UInt64> {
        var allowed = Set(names.keys)
        if let ownFID, !isInPeople(ownFID) { allowed.insert(ownFID) }
        return allowed
    }

    private func isInPeople(_ fid: UInt64) -> Bool {
        people.contains { $0.id == fid }
    }

    /// The handle a cast shows. This account may be outside People, so its own handle is known here.
    func handle(for fid: UInt64) -> String {
        names[fid] ?? (fid == ownFID ? ownHandle : nil) ?? String(fid)
    }

    /// Shows a cast the node has accepted. The feed will have it soon if the account follows itself,
    /// so it's held until then. Otherwise it's kept on this Mac.
    func addPosted(_ cast: FeedCast) {
        if hasLoadedFeed, cast.fid == ownFID, !isInPeople(cast.fid) {
            var own = snapshot.ownPosts ?? []
            guard !own.contains(where: { $0.hash == cast.hash }) else { return }
            own.append(cast)
            snapshot.ownPosts = own
            do {
                try persist(snapshot)
                saveFailed = false
            } catch { saveFailed = true }
            return
        }
        guard !heldPosts.contains(where: { $0.cast.hash == cast.hash }) else { return }
        heldPosts.append(HeldPost(cast: cast, added: .now))
    }

    /// Takes a cast this account deleted out of the feed right away. The server drops it from everyone's
    /// file too, and this covers a read that hasn't caught up.
    func removeDeleted(_ cast: FeedCast) {
        heldPosts.removeAll { $0.cast.hash == cast.hash }
        let own = (snapshot.ownPosts ?? []).filter { $0.hash != cast.hash }
        snapshot.ownPosts = own.isEmpty ? nil : own
        snapshot.deleted = (snapshot.deleted ?? [:]).merging([cast.hash: cast.time]) { _, new in new }
        do {
            try persist(snapshot)
            saveFailed = false
        } catch { saveFailed = true }
    }

    private func pruneOwnPosts() {
        let oldest = Date.now.addingTimeInterval(-Self.window)
        let kept = (snapshot.ownPosts ?? []).filter { $0.date > oldest }
        snapshot.ownPosts = kept.isEmpty ? nil : kept
        let deleted = (snapshot.deleted ?? [:]).filter { Date(timeIntervalSince1970: TimeInterval($0.value)) > oldest }
        snapshot.deleted = deleted.isEmpty ? nil : deleted
    }

    /// Runs only after a successful read, so a failed read can't take a post away.
    private func releaseHeldPosts() {
        let read = Set((snapshot.feedCasts ?? []).map(\.hash))
        heldPosts.removeAll { Date.now.timeIntervalSince($0.added) >= postHold || read.contains($0.cast.hash) }
    }

    nonisolated static func feed(from casts: [FeedCast], allowed: Set<UInt64>, excluding deleted: Set<String> = []) -> [FeedCast] {
        var seen = Set<String>()
        return casts
            .filter { allowed.contains($0.fid) && !deleted.contains($0.hash) && $0.isReadable && seen.insert($0.hash).inserted }
            .sorted(by: newer)
    }

    /// A new sign-in reads who the account follows from the network. A launch uses the list it has.
    func start(signedIn: Bool = false) async {
        guard !didLoad else { return }
        didLoad = true
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = saved
        }
        await refresh(reason: signedIn ? Self.signIn : "launch")
    }

    /// Rereads who this account follows. Only the button on the People screen calls this.
    func refreshPeople() async {
        refreshingPeople = true
        defer { refreshingPeople = false }
        await refresh(reason: Self.peopleButton)
    }

    /// Returning to the app refreshes the feed, but quick app switches don't ask again.
    func refreshIfStale() async {
        guard didLoad, !loading, Date.now.timeIntervalSince(lastRefresh ?? .distantPast) >= 60 else { return }
        await refresh(reason: "foreground")
    }

    func isHidden(_ person: Person) -> Bool { snapshot.hidden.contains(person.id) }

    func toggleVisibility(_ person: Person) throws {
        var next = snapshot
        if next.hidden.remove(person.id) == nil { next.hidden.insert(person.id) }
        try persist(next)
        snapshot = next
        saveFailed = false
    }

    /// A refresh requested while another is running runs again afterward, because the running one may
    /// have already read the feed before the change. The model owns the work, so a view going away
    /// can't discard it. Callers wait until the feed has caught up.
    func refresh(reason: String = "refresh") async {
        if let refreshTask {
            // A list rebuild also brings the feed up to date, so nothing should replace one in the queue.
            if queuedRefreshReason.map(Self.rebuildsPeople) != true { queuedRefreshReason = reason }
            await refreshTask.value
            return
        }
        loading = true
        let task = Task { [self] in
            var reason = reason
            while true {
                await load(reason: reason)
                guard let next = queuedRefreshReason else { break }
                queuedRefreshReason = nil
                reason = next
            }
            refreshTask = nil
            loading = false
        }
        refreshTask = task
        await task.value
    }

    private static func rebuildsPeople(_ reason: String) -> Bool {
        reason == signIn || reason == peopleButton
    }

    /// A pull or a new post can read the network sooner than opening the app can. An account the server
    /// has no list for gets one here, which covers a sign-in from before lists and a sign-in that failed.
    private func fetchLatest(reason: String) async throws -> FeedFetch {
        if Self.rebuildsPeople(reason) { return try await fetchPeople() }
        // Following no one, the list is the only thing that can change. Asking again too soon isn't a problem.
        if hasLoadedFeed, people.isEmpty {
            do {
                return try await fetchPeople()
            } catch let error as FeedHTTPError where error.status == 429 {}
        }
        do {
            // An ETag without saved casts would get a 304 with nothing to show.
            let etag = snapshot.feedCasts == nil ? nil : snapshot.etag
            return try await fetchFeed(reason == "pull" || reason == "post", etag)
        } catch let error as FeedHTTPError where error.status == 404 {
            return try await fetchPeople()
        }
    }

    private func load(reason: String) async {
        let started = Date.now
        let outcome: String
        do {
            let fetch = try await fetchLatest(reason: reason)
            if let file = fetch.file {
                snapshot.people = file.people
                snapshot.feedCasts = file.casts
                snapshot.etag = fetch.etag
            }
            snapshot.checkedAt = Date.now.addingTimeInterval(-fetch.age)
            // With no one to read, there's nothing for the feed to be behind on.
            problem = fetch.age >= Self.staleAfter && !people.isEmpty ? .paused : nil
            releaseHeldPosts()
            if reason == Self.peopleButton { peopleRefreshFailed = false }
            let shape = fetch.file.map { "updated \($0.casts.count) casts" } ?? "unchanged"
            outcome = "\(shape), age \(Int(fetch.age))s"
        } catch {
            // The People screen reports a failed list refresh itself, and the feed is no worse off for it.
            if reason == Self.peopleButton { peopleRefreshFailed = true } else { problem = Self.problem(for: error) }
            outcome = "failed: \(Self.describe(error))"
        }

        lastRefresh = .now
        pruneOwnPosts()
        do {
            try persist(snapshot)
            saveFailed = false
        } catch { saveFailed = true }

        let record = FeedRefreshRecord(
            reason: reason,
            started: started,
            seconds: Date.now.timeIntervalSince(started),
            outcome: outcome,
            newestOwnCast: newestOwnCast
        )
        history.insert(record, at: 0)
        history.removeLast(max(0, history.count - Self.historyLimit))
        Self.logger.log("\(Self.line(for: record), privacy: .public)")
    }

    nonisolated static func problem(for error: any Error, connection: Connection = .current) -> Problem {
        guard let error = error as? FeedHTTPError else { return .unreachable }
        if error.status == 402, connection.usesInvite { return .limitReached }
        return [401, 402, 403].contains(error.status) ? .refused : .unreachable
    }

    private var newestOwnCast: String? {
        guard let ownFID, let cast = (snapshot.feedCasts ?? []).filter({ $0.fid == ownFID }).max(by: { Self.newer($1, $0) }) else {
            return nil
        }
        return "\(cast.hash.prefix(10)) at \(cast.date.ISO8601Format())"
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let error as FeedHTTPError:
            return "HTTP \(error.status)"
        case let error as URLError:
            return "URLError \(error.code.rawValue)"
        case is CancellationError:
            return "cancelled"
        case let error as DecodingError:
            // Only the kind of failure and field names, since debug descriptions can quote the response.
            switch error {
            case .keyNotFound(let key, _): return "decode missing \(key.stringValue)"
            case .typeMismatch(_, let context): return "decode type mismatch at \(path(context))"
            case .valueNotFound(_, let context): return "decode null at \(path(context))"
            case .dataCorrupted(let context): return "decode corrupted at \(path(context))"
            @unknown default: return "decode error"
            }
        default:
            return String(describing: type(of: error))
        }
    }

    private nonisolated static func path(_ context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }

    private nonisolated static func line(for record: FeedRefreshRecord) -> String {
        var line = "\(record.started.ISO8601Format()) \(record.reason) "
            + "\(String(format: "%.1f", record.seconds))s \(record.outcome)"
        if let own = record.newestOwnCast { line += ", yours \(own)" }
        return line
    }

    /// The app's name, version, and build, as Settings and Copy Diagnostics show them.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Fatline \(version) (\(build))"
    }

    /// Text someone can paste into a bug report. See `FeedRefreshRecord` for what it may contain.
    var diagnostics: String {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let lines = [
            "\(Self.versionLine), macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            "Now \(Date.now.ISO8601Format())",
            "Connection \(Connection.current.name)",
            "Account FID \(ownFID.map(String.init) ?? "unknown")",
            "People \(people.count), hidden \(snapshot.hidden.count)",
            "Casts in feed \(casts.count), problem \(problem.map { "\($0)" } ?? "none")",
            "Last checked \(lastChecked?.ISO8601Format() ?? "never")",
            "Refreshing \(loading ? "yes" : "no"), save failed \(saveFailed ? "yes" : "no")",
            "Refreshes, newest first:"
        ] + (history.isEmpty ? ["none yet"] : history.map(Self.line))
        return lines.joined(separator: "\n")
    }

    private func persist(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }

    nonisolated static func newer(_ left: FeedCast, _ right: FeedCast) -> Bool {
        left.time == right.time ? left.hash < right.hash : left.time > right.time
    }
}
