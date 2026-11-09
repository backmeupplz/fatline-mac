import Foundation
import os

/// Where this app sends its requests and the one credential that goes with them. Every way of
/// connecting is one of these, so the rest of the app doesn't need to know which is in use.
struct Connection: Hashable, Sendable {
    struct Header: Hashable, Sendable {
        let name: String
        let value: String
    }

    private static let inviteHeader = "X-Invite-Code"

    /// Shown in Settings and Copy Diagnostics, so it never holds a key or an address.
    let name: String
    /// Neynar's `/v2/farcaster` routes, or a server that answers the same way.
    let feedBase: URL
    /// Snapchain's `/v1` routes.
    let nodeBase: URL
    let header: Header?

    /// A server named by the invite itself. docs/SERVER.md describes what it has to answer.
    static func invite(_ invite: Invite) -> Connection {
        let base = invite.server.appending(path: "v1")
        return Connection(
            name: "Code",
            feedBase: base.appending(path: "farcaster"),
            nodeBase: base.appending(path: "node"),
            header: Header(name: inviteHeader, value: invite.code)
        )
    }

    static func neynar(key: String) -> Connection {
        Connection(
            name: "Neynar Key",
            feedBase: URL(string: "https://api.neynar.com/v2/farcaster")!,
            nodeBase: URL(string: "https://snapchain-api.neynar.com/v1")!,
            header: Header(name: "x-api-key", value: key)
        )
    }

    /// A server that answers both Neynar's feed routes and Snapchain's.
    static func custom(_ url: URL) -> Connection {
        Connection(
            name: "Custom Server",
            feedBase: url.appending(path: "v2/farcaster"),
            nodeBase: url.appending(path: "v1"),
            header: nil
        )
    }

    /// Before a choice is made. The `.invalid` domain never resolves, so nothing leaves this Mac.
    private static let notChosen = Connection(
        name: "Not Connected",
        feedBase: URL(string: "https://not-connected.invalid/v2/farcaster")!,
        nodeBase: URL(string: "https://not-connected.invalid/v1")!,
        header: nil
    )

    var usesInvite: Bool { header?.name == Self.inviteHeader }

    private static let active = OSAllocatedUnfairLock(initialState: starting())

    static var current: Connection { active.withLock { $0 } }

    static func use(_ connection: Connection) {
        active.withLock { $0 = connection }
    }

    private static func starting() -> Connection {
        buildOverride ?? ConnectionChoice.saved()?.connection ?? notChosen
    }

    /// True when a Debug build was launched with a connection, so there's nothing to ask.
    static var isSetByLaunch: Bool { buildOverride != nil }

    private static var buildOverride: Connection? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let invite = environment["FATLINE_INVITE"].flatMap(Invite.init(typed:)) { return .invite(invite) }
        if let key = environment["FATLINE_NEYNAR_KEY"], !key.isEmpty { return .neynar(key: key) }
        if let server = environment["FATLINE_SERVER_URL"], let url = URL(string: server) { return .custom(url) }
        #endif
        return nil
    }

    /// Adds the credential to requests for this connection only. The same HTTP code also calls Farcaster.
    func authorize(_ request: inout URLRequest) {
        guard let header, let url = request.url, [feedBase, nodeBase].contains(where: { Self.sameServer($0, url) }) else { return }
        request.setValue(header.value, forHTTPHeaderField: header.name)
    }

    private static func sameServer(_ left: URL, _ right: URL) -> Bool {
        left.scheme == right.scheme && left.host() == right.host() && left.port == right.port
    }

    /// Reading a node directly returns its own errors, which look like
    /// `{error, error_detail: 'status: NotFound, message: "..."'}`. The app expects what an invite server
    /// sends: a `message` and a real status. docs/SERVER.md describes that translation.
    func nodeAnswer(_ data: Data, status: Int, for url: URL?) -> (Data, Int) {
        guard !usesInvite, !(200..<300).contains(status), let url, Self.sameServer(nodeBase, url) else { return (data, status) }
        struct Failure: Decodable {
            let message: String?
            let error: String?
            let error_detail: String?
        }
        // These describe the key or its credits, not the request.
        if [401, 402, 403].contains(status) { return (Self.failure("Couldn't reach the network."), 503) }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        let detail = failure?.error_detail ?? ""
        let quoted = detail.firstMatch(of: #/message: "((?:[^"\\]|\\.)*)"/#).map { String($0.1) }
        let message = failure?.message ?? quoted ?? failure?.error ?? "The network rejected this request."
        return (Self.failure(String(message.prefix(300))), detail.contains("status: NotFound") ? 404 : status)
    }

    private static func failure(_ message: String) -> Data {
        (try? JSONEncoder().encode(["message": message])) ?? Data()
    }
}

/// A code and the server that accepts it, written as `code@server.example`. The server may have a port
/// or a path, as in `code@server.example:8443/fatline`.
struct Invite: Codable, Hashable, Sendable {
    let code: String
    let server: URL

    private static let codeCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Nil for anything that isn't exactly one safe code and one HTTPS server.
    init?(typed text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...128).contains(parts[0].count), parts[0].allSatisfy(Self.codeCharacters.contains),
              let server = ConnectionChoice.httpsServer(String(parts[1])) else { return nil }
        code = String(parts[0])
        self.server = server
    }

    /// The server as it's shown to the person, so they can see who they're trusting.
    var address: String {
        server.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    var text: String { "\(code)@\(address)" }
}

/// What the person picked, as it's saved on this Mac.
enum ConnectionChoice: Codable, Equatable, Sendable {
    case invite(Invite)
    case neynarKey(String)
    case custom(URL)

    private static let item = KeychainValue<ConnectionChoice>(account: "connection-v1")

    var connection: Connection {
        switch self {
        case .invite(let invite): .invite(invite)
        case .neynarKey(let key): .neynar(key: key)
        case .custom(let url): .custom(url)
        }
    }

    static func saved() -> ConnectionChoice? {
        #if DEBUG
        // Tests run inside the app, and shouldn't read through a key saved on this Mac.
        let process = ProcessInfo.processInfo
        if process.arguments.contains("-FatlineIgnoreSavedAccount") || process.environment["XCTestConfigurationFilePath"] != nil { return nil }
        #endif
        return try? item.load()
    }

    func save() throws {
        try Self.item.save(self)
    }

    static func invite(typed text: String) -> ConnectionChoice? {
        Invite(typed: text).map(ConnectionChoice.invite)
    }

    /// Nil for something that can't be a key, so it never reaches a request header.
    static func neynarKey(typed text: String) -> ConnectionChoice? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty || key.contains(where: \.isWhitespace) ? nil : .neynarKey(key)
    }

    static func custom(typed text: String) -> ConnectionChoice? {
        httpsServer(text).map(ConnectionChoice.custom)
    }

    /// Accepts an address with or without `https://`. A server gets only HTTPS, and only its address.
    static func httpsServer(_ text: String) -> URL? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains(where: \.isWhitespace) else { return nil }
        if !address.contains("://") { address = "https://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        guard let parts = URLComponents(string: address), parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        return url
    }

    private enum Route { case feed, node }

    /// Read the same way sign-in reads it. It's 0 for an account that has never added a key this way.
    private struct KeyNonce: Decodable { let currentUserNonce: UInt32 }

    /// Tries the cheapest read of each kind this connection depends on, and returns what's wrong, if
    /// anything. Reading FID 1 costs a few credits, and works the same for any account.
    func problem(send: @escaping FeedReader.Send = { try await HTTP.loadResponse($0) }) async -> String? {
        let connection = self.connection
        func read(_ base: URL, _ path: String, _ query: [String: String], route: Route, key: String, needsNonce: Bool = false) async throws -> String? {
            var request = HTTP.getRequest(base, path, query, timeout: 15)
            connection.authorize(&request)
            let (data, response) = try await send(request)
            if let problem = problem(status: response.statusCode, route: route) { return problem }
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let hasNonce = !needsNonce || (try? JSONDecoder().decode(KeyNonce.self, from: data)) != nil
            return body?[key] is [Any] && hasNonce ? nil : missingRoute(route)
        }
        do {
            if let problem = try await read(connection.feedBase, "feed/following/", ["fid": "1", "limit": "1", "with_recasts": "false"], route: .feed, key: "casts") {
                return problem
            }
            if let problem = try await read(connection.nodeBase, "userDataByFid", ["fid": "1", "user_data_type": "USER_DATA_TYPE_USERNAME"], route: .node, key: "messages") {
                return problem
            }
            // Only a custom server can pass those reads and still be unable to sign in. Any more reads
            // for a code or a Neynar key would just cost credits.
            guard case .custom = self else { return nil }
            return try await read(connection.nodeBase, "signersByFid", ["fid": "1", "pageSize": "1"], route: .node, key: "signers", needsNonce: true)
        } catch {
            return "Couldn’t reach that server. Check the address and your internet connection."
        }
    }

    private func problem(status: Int, route: Route) -> String? {
        switch (status, self) {
        case (200, _): nil
        case (401, .invite), (403, .invite): "Invalid code."
        case (402, .invite): "Limit reached. Try again later."
        case (404, .invite): missingRoute(route)
        case (401, .neynarKey), (403, .neynarKey):
            route == .node ? "This key can’t use Neynar’s Snapchain node." : "Invalid key."
        case (402, .neynarKey): "This key is out of credits."
        case (401, .custom), (403, .custom): "That server requires a key. Fatline can’t send one."
        case (404, .custom): missingRoute(route)
        case (429, _): "Too many requests. Try again in a minute."
        default: "That server answered with an error (HTTP \(status)). Try again."
        }
    }

    private func missingRoute(_ route: Route) -> String {
        switch route {
        case .feed: "That server can’t build a feed. Fatline needs one that answers Neynar’s feed routes."
        case .node: "That server doesn’t answer Snapchain’s routes, so Fatline can’t post through it."
        }
    }
}
