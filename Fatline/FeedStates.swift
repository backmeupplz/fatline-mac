import SwiftUI

struct FeedEmptyMessage: View {
    let model: FeedModel

    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 4) {
            if followsNoOne {
                if let username = state.username {
                    Text("Signed in as \(Text(verbatim: username).font(FatlineStyle.bodyStrong).foregroundStyle(FatlineStyle.ink))")
                }
                Text("Not following anyone")
            } else {
                Text(message)
            }
        }
        .font(FatlineStyle.body)
        .foregroundStyle(FatlineStyle.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, FatlineStyle.gutter)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    /// Ignores `loading`, so rechecking the list doesn't flash Loading.
    private var followsNoOne: Bool {
        model.status == nil && model.problem == nil && model.hasLoadedFeed && model.people.isEmpty
    }

    private var message: String {
        if let status = model.status { return status }
        if model.loading { return "Loading…" }
        if model.problem != nil { return "Couldn’t load the feed. Press ⌘R to try again." }
        if model.hasLoadedFeed, model.names.isEmpty { return "Everyone is hidden." }
        return "No recent casts."
    }
}

/// Only for casts that may be out of date. With no casts, `FeedEmptyMessage` says what went wrong.
struct FeedBanner: View {
    let model: FeedModel
    let casts: [FeedCast]

    var body: some View {
        if let problem = model.problem, !casts.isEmpty {
            FeedProblemBanner(problem: problem, lastChecked: model.lastChecked, checking: model.loading) {
                Task { await model.refresh(reason: "pull") }
            }
            .frame(maxWidth: FatlineStyle.columnMaxWidth)
            FatlineDivider()
        }
    }
}

struct FeedStatusRow: View {
    let model: FeedModel
    let casts: [FeedCast]

    @Environment(AppState.self) private var state

    var body: some View {
        if state.session.keyInactive {
            FeedMessage(text: PostingError.inactiveKey.errorDescription ?? "")
            CastDivider()
        }
        if let status = model.status, !casts.isEmpty {
            FeedMessage(text: status)
            CastDivider()
        }
    }
}
