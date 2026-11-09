import AppKit
import SwiftUI

/// The composer sheet on the feed window.
struct ComposerSheet: View {
    @Environment(AppState.self) private var state
    @State private var showDiscardRetry = false
    @FocusState private var focused: Bool

    private var session: PostingSession { state.session }

    var body: some View {
        VStack(spacing: 0) {
            editor
            failure
            FatlineDivider()
            footer
        }
        .frame(width: 400, height: 224)
        .foregroundStyle(FatlineStyle.ink)
        .background(FatlineStyle.paper)
        .tint(FatlineStyle.action)
        .alert("Stop retrying this cast?", isPresented: $showDiscardRetry) {
            // Claiming Return for Cancel, so the system can't give it to Stop Retrying.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Stop Retrying", role: .destructive, action: session.discardRetry)
        } message: {
            Text("Snapchain may already have received it. Your draft stays here.")
        }
        .task(id: session.draft) {
            // A change to the draft cancels this wait, so a save happens once typing pauses.
            // Cancel and leaving the app save right away.
            do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            if session.ready { session.saveDraft() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            if session.ready { session.saveDraft() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if session.ready { session.saveDraft() }
        }
    }

    private var editor: some View {
        TextEditor(text: Bindable(session).draft)
            .font(FatlineStyle.body)
            .lineSpacing(FatlineStyle.bodyLineSpacing)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .accessibilityLabel("Cast draft")
            .disabled(!session.ready)
            .overlay(alignment: .topLeading) {
                if session.ready && session.draft.isEmpty {
                    Text("Write a cast…")
                        .font(FatlineStyle.body)
                        .foregroundStyle(FatlineStyle.secondary)
                        .padding(.leading, 5)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .task(id: session.ready) { focused = session.ready }
            // The editor insets its text by 5, so the text itself sits on the 20-point margin.
            .padding(.horizontal, 15)
            .padding(.top, 18)
    }

    /// Why the last post failed. The sheet stays open after a failure, so this stays until the next attempt.
    @ViewBuilder private var failure: some View {
        let toast = session.postToast
        let canStopRetrying = session.account?.pending != nil && !session.busy
        if toast?.detail != nil || canStopRetrying {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let toast, let detail = toast.detail {
                    // One text, so a long reason wraps under the title. The cap keeps the editor usable.
                    Text("\(Text(toast.title).foregroundStyle(FatlineStyle.danger)) \(Text(detail).foregroundStyle(FatlineStyle.secondary))")
                        .lineLimit(4)
                }
                if canStopRetrying {
                    Button("Stop Retrying…") { showDiscardRetry = true }
                        .font(FatlineStyle.body)
                        .buttonStyle(.plain)
                        .foregroundStyle(FatlineStyle.ink)
                        .fixedSize()
                }
            }
            .font(FatlineStyle.meta)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            status
            Spacer(minLength: 8)
            Button("Cancel", action: session.cancelComposer)
                .font(FatlineStyle.body)
                .keyboardShortcut(.cancelAction)
                .disabled(session.busy)
            Button(session.activePostTitle ?? (session.account?.pending == nil ? "Post" : "Retry")) {
                Task { await session.send() }
            }
            .buttonStyle(FatlinePrimaryButton(compact: true, minWidth: 68, isWorking: session.activePostTitle != nil))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(session.sendDisabled)
        }
        .buttonStyle(.plain)
        .frame(height: 48)
        .padding(.leading, 20)
        .padding(.trailing, 10)
    }

    @ViewBuilder private var status: some View {
        if session.saveFailed {
            Button("Retry Save", action: session.saveDraft)
                .font(FatlineStyle.body)
                .foregroundStyle(FatlineStyle.action)
        } else if !session.ready {
            Button("Retry Draft", action: session.loadDraft)
                .font(FatlineStyle.body)
                .foregroundStyle(FatlineStyle.action)
        } else {
            HStack(spacing: 8) {
                if let notice = session.notice {
                    Text(notice)
                        .font(FatlineStyle.meta)
                        .foregroundStyle(FatlineStyle.secondary)
                        .lineLimit(2)
                }
                if session.draft.utf8.count >= 280 {
                    Text("\(session.draft.utf8.count) / 320")
                        .font(FatlineStyle.meta)
                        .monospacedDigit()
                        .foregroundStyle(session.draft.utf8.count > 320 ? FatlineStyle.danger : FatlineStyle.secondary)
                        .accessibilityLabel("\(session.draft.utf8.count) of 320 bytes")
                }
            }
        }
    }
}

/// Sent and Deleted, at the top of the feed. A failed post shows in the composer instead, which stays open.
struct FeedToastHost: View {
    @Environment(AppState.self) private var state

    private var session: PostingSession { state.session }

    var body: some View {
        if !session.showComposer, let toast = session.postToast {
            Group {
                if toast.detail == nil {
                    FeedConfirmationPill(title: toast.title)
                } else {
                    FeedToastView(toast: toast)
                        .padding(.horizontal, FatlineStyle.gutter)
                }
            }
                .allowsHitTesting(false)
                .transition(.opacity)
                .task(id: toast.id) {
                    do {
                        try await Task.sleep(for: .seconds(toast.detail == nil ? 4 : 6))
                        if session.postToast?.id == toast.id { session.setPostToast(nil) }
                    } catch { }
                }
        }
    }
}

/// Fits between the name and the time on the top row, so a cast that was just posted stays readable.
private struct FeedConfirmationPill: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FatlineStyle.action)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(FatlineStyle.bodyStrong)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(FatlineStyle.quiet, in: .capsule)
        .overlay { Capsule().strokeBorder(FatlineStyle.line) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("post-toast")
    }
}

/// The floating plus at the column's lower right.
struct ComposerPlus: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button(action: state.session.openComposer) {
            Image(systemName: "plus")
                .font(FatlineStyle.plusGlyph)
                .foregroundStyle(FatlineStyle.actionInk)
                .frame(width: 48, height: 48)
                .background(FatlineStyle.action, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Compose")
        .accessibilityIdentifier("compose")
        .disabled(state.model == nil || state.session.account?.fid == nil)
        .padding(.trailing, FatlineStyle.gutter)
        .padding(.bottom, FatlineStyle.gutter)
    }
}
