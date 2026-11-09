import SwiftUI

/// The right-click menu on a cast.
struct CastMenu: View {
    let cast: FeedCast
    let handle: String
    let model: FeedModel

    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !cast.text.isEmpty {
            Button("Copy Text") { AppSupport.copyToClipboard(cast.text) }
        }
        if let url = cast.farcasterURL(handle: handle) {
            Button("Copy Link") { AppSupport.copyToClipboard(url.absoluteString) }
            Button("Open in Farcaster") { openURL(url) }
        }
        if model.isOwn(cast), !state.deleting.contains(cast.hash) {
            Divider()
            Button("Delete…", role: .destructive) {
                if state.session.keyCanDelete != false { state.confirmingDelete = cast } else { state.showDeleteHelp = true }
            }
        }
    }
}

/// The alerts that go with deleting a cast.
struct CastDeleteAlerts: ViewModifier {
    let model: FeedModel

    @Environment(AppState.self) private var state

    func body(content: Content) -> some View {
        content
            .alert(
                "Delete this cast?",
                isPresented: Binding(get: { state.confirmingDelete != nil }, set: { if !$0 { state.confirmingDelete = nil } }),
                presenting: state.confirmingDelete
            ) { cast in
                // Claiming Return for Cancel, so the system can't give it to Delete.
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
                Button("Delete", role: .destructive) { Task { await delete(cast) } }
            } message: { _ in
                Text("Farcaster apps will stop showing it. This can’t be undone.")
            }
            .alert("Couldn’t delete the cast", isPresented: Binding(get: { state.deleteError != nil }, set: { if !$0 { state.deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.deleteError ?? "")
            }
            .alert("Sign in again to delete", isPresented: Bindable(state).showDeleteHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(PostingError.postOnlyKey.errorDescription ?? "")
            }
    }

    private func delete(_ cast: FeedCast) async {
        state.deleting.insert(cast.hash)
        defer { state.deleting.remove(cast.hash) }
        do {
            try await state.session.deleteCast(cast)
            model.removeDeleted(cast)
        } catch PostingError.postOnlyKey {
            state.showDeleteHelp = true
        } catch {
            state.deleteError = error.localizedDescription
        }
    }
}
