import SwiftUI

/// The signed-in account and everything done with it: the draft, posting and retrying, deleting, and
/// signing in and out. Both apps share this, because a retry has to resend the exact signed bytes and
/// that should only ever be written once.
@MainActor
@Observable
final class PostingSession {
    var draft = ""
    /// What's on disk, so a save only happens when there's something new to write.
    private var savedDraft: String?
    private(set) var ready = false
    private(set) var saveFailed = false
    var account: PostingAccount?
    var busy = false
    var notice: String?
    private(set) var postToast: PostToast?
    private(set) var activePostTitle: String?
    var showComposer = false
    var recoveryError: String?
    private(set) var keyInactive = false
    /// Nil until a key check answers. A key without the delete scope can only post.
    private(set) var keyCanDelete: Bool?
    private var lastKeyCheck: Date?
    private(set) var latestPost: FeedCast?
    /// True from a sign-in until sign-out, so the feed that opens next reads the follow list.
    private(set) var signedInNow = false
    private(set) var connection = Connection.current
    private(set) var savedConnection = ConnectionChoice.saved()

    private let node = Snapchain()

    /// Each account's drafts and saved feed.
    static func accountFolder(_ fid: UInt64) -> URL {
        AppSupport.appFolder.appending(path: "Accounts/\(fid)", directoryHint: .isDirectory)
    }

    private var store: DraftStore? {
        guard let fid = account?.fid else { return nil }
        return DraftStore(directory: Self.accountFolder(fid))
    }

    private var draftIsValid: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= 320
    }

    var sendDisabled: Bool {
        account?.fid == nil || busy || !ready || saveFailed || (account?.pending == nil && !draftIsValid)
    }

    /// Why Sign Out is unavailable, shown under the button. A pending cast normally blocks it so the cast
    /// isn't lost, but an inactive key can never send it.
    var signOutBlock: String? {
        if busy { return "Wait for Fatline to finish." }
        if account?.pending != nil, !keyInactive { return "You have an unsent cast. Open the composer to retry or discard it." }
        if !ready || saveFailed { return "Your draft couldn’t be saved. Open the composer to retry." }
        return nil
    }

    /// A launch argument can start on the sign-in screen. Ignoring the saved account, instead of
    /// deleting it, leaves that sign-in in place.
    func loadSavedAccount() {
        #if DEBUG
        let ignoreSaved = ProcessInfo.processInfo.arguments.contains("-FatlineIgnoreSavedAccount")
        #else
        let ignoreSaved = false
        #endif
        account = ignoreSaved ? nil : try? PostingKeychain.load()
        if account?.fid != nil, !ready { loadDraft() }
    }

    func useConnection(_ choice: ConnectionChoice) throws {
        try choice.save()
        savedConnection = choice
        Connection.use(choice.connection)
        connection = choice.connection
    }

    /// A failed lookup says nothing about the key, so only a clear answer changes the state.
    @discardableResult
    func checkKey() async -> Bool {
        lastKeyCheck = .now
        guard let account, let fid = account.fid, let key = try? account.publicKey,
              let state = try? await node.signerState(fid: fid, publicKey: key),
              self.account?.fid == fid else { return false }
        keyInactive = state.status != .active
        keyCanDelete = state.canDelete
        return keyInactive
    }

    /// Each check costs credits, so returning to the app checks at most hourly. A failed post checks right away.
    func checkKeyIfDue() {
        if Date.now.timeIntervalSince(lastKeyCheck ?? .distantPast) >= 3600 {
            Task { await checkKey() }
        }
    }

    /// Signs and sends a deletion of one of this account's casts with the posting key.
    func deleteCast(_ cast: FeedCast) async throws {
        guard let account, let fid = account.fid, cast.fid == fid else { throw PostingError.missingKey }
        if keyCanDelete == false { throw PostingError.postOnlyKey }
        let removal = try SignedRemoval.make(fid: fid, target: cast.hash, key: account.signingKey)
        do {
            try await node.remove(removal)
            setPostToast(PostToast(detail: nil, confirmation: "Deleted"))
        } catch {
            // A refusal may come from the key, so the next answer reflects what it can do now.
            if await checkKey() { throw PostingError.inactiveKey }
            if keyCanDelete == false { throw PostingError.postOnlyKey }
            throw error
        }
    }

    func setPostToast(_ toast: PostToast?) {
        withAnimation(AppSupport.reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            postToast = toast
        }
        if let toast {
            AppSupport.announce([toast.title, toast.detail].compactMap { $0 }.joined(separator: ". "))
        }
    }

    func openComposer() {
        setPostToast(nil)
        showComposer = true
    }

    /// Cancel keeps the draft, and stays open if the draft can't be saved.
    func cancelComposer() {
        if ready { saveDraft() }
        guard !saveFailed else { return }
        showComposer = false
        setPostToast(nil)
    }

    func importPhrase(_ phrase: String) {
        guard !busy, account?.fid == nil else { return }
        let signer: RecoverySigner
        do {
            signer = try RecoverySigner(phrase: phrase)
        } catch {
            recoveryError = error.localizedDescription
            return
        }
        busy = true
        recoveryError = nil
        Task {
            defer { busy = false }
            do {
                let identity = try await node.account(custodyAddress: signer.address)
                var candidate = PostingAccount()
                candidate.registration = try signer.registration(fid: identity.fid, nonce: identity.nonce, key: candidate.signingKey)
                try PostingKeychain.save(candidate)
                account = candidate
                try await register(candidate)
            } catch { recoveryError = error.localizedDescription }
        }
    }

    func completeRegistration() async {
        guard !busy, let candidate = account, candidate.registration != nil else { return }
        busy = true
        recoveryError = nil
        defer { busy = false }
        do { try await register(candidate) }
        catch { recoveryError = error.localizedDescription }
    }

    private func register(_ account: PostingAccount) async throws {
        var candidate = account
        guard let registration = candidate.registration else { return }
        try await node.register(registration, publicKey: candidate.publicKey)
        candidate.fid = registration.fid
        candidate.username = (try? await node.username(fid: registration.fid)) ?? String(registration.fid)
        candidate.registration = nil
        try PostingKeychain.save(candidate)
        openAccount(candidate)
    }

    func openAccount(_ candidate: PostingAccount) {
        signedInNow = true
        account = candidate
        notice = nil
        ready = false
        loadDraft()
    }

    func signOut() throws {
        guard signOutBlock == nil else { return }
        try store?.save(draft)
        try PostingKeychain.remove()
        ready = false
        keyInactive = false
        keyCanDelete = nil
        signedInNow = false
        account = nil
        draft = ""
        notice = nil
        showComposer = false
        setPostToast(nil)
    }

    func send() async {
        guard !busy, var candidate = account, let fid = candidate.fid else { return }
        let hadPendingCast = candidate.pending != nil
        activePostTitle = hadPendingCast ? "Retry" : "Post"
        busy = true
        notice = "Sending…"
        setPostToast(nil)
        var submitted = false
        defer {
            activePostTitle = nil
            busy = false
        }
        do {
            let cast = try candidate.pending ?? SignedCast.make(fid: fid, text: draft, key: candidate.signingKey)
            candidate.pending = cast
            try PostingKeychain.save(candidate)
            account = candidate
            try await node.submit(cast, checkingExisting: hadPendingCast)
            submitted = true
            latestPost = FeedCast(posted: cast)
            if draft == cast.text {
                try store?.save("")
                savedDraft = ""
                draft = ""
            }
            candidate.pending = nil
            try PostingKeychain.save(candidate)
            account = candidate
            notice = nil
            // Anything typed while it was sending, since closing the composer ends its save timer.
            if ready { saveDraft() }
            showComposer = false
            setPostToast(PostToast(detail: nil))
        } catch {
            if !submitted, await checkKey() {
                // This key can never send the cast, so stop offering Retry. The draft stays.
                candidate.pending = nil
                if (try? PostingKeychain.save(candidate)) != nil { account = candidate }
                notice = nil
                setPostToast(PostToast(detail: PostingError.inactiveKey.errorDescription))
                return
            }
            if !hadPendingCast, case PostingError.rejected = error {
                candidate.pending = nil
                if (try? PostingKeychain.save(candidate)) != nil { account = candidate }
            }
            notice = submitted ? error.localizedDescription : nil
            setPostToast(PostToast(detail: submitted ? nil : error.localizedDescription))
        }
    }

    func discardRetry() {
        guard var candidate = account else { return }
        do {
            candidate.pending = nil
            try PostingKeychain.save(candidate)
            account = candidate
            notice = nil
            setPostToast(nil)
        } catch { notice = error.localizedDescription }
    }

    func loadDraft() {
        do {
            guard let store else { return }
            draft = try store.load()
            savedDraft = draft
            ready = true
        } catch { ready = false }
    }

    func saveDraft() {
        guard draft != savedDraft || saveFailed else { return }
        do {
            try store?.save(draft)
            savedDraft = draft
            saveFailed = false
        } catch { saveFailed = true }
    }
}
