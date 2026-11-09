import SwiftUI

/// The Settings window: the account, the people it follows, and how it connects.
struct SettingsWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let model = state.model {
                SettingsStack(model: model, username: state.username)
            } else {
                FatlineStyle.paper.settingsTitleBar()
            }
        }
        .frame(width: 360, height: 560 - FatlineStyle.headerHeight)
        .publishesMenuFlags(state)
        // After signing out there's nothing left to show here.
        .onChange(of: state.model == nil) { _, signedOut in
            if signedOut { dismissWindow(id: "settings") }
        }
    }
}

private struct SettingsStack: View {
    let model: FeedModel
    let username: String?

    @Environment(AppState.self) private var state
    @State private var confirmingSignOut = false
    @State private var signOutError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FatlineDivider()
                ScrollView {
                    VStack(spacing: 0) {
                        if let username {
                            account(username)
                            CastDivider()
                        }
                        NavigationLink { PeopleView(model: model) } label: { settingsRow("People") }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings-people")
                        CastDivider()
                        if !Connection.isSetByLaunch {
                            NavigationLink { ConnectionSettings() } label: {
                                settingsRow("Connection", value: state.session.connection.name)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings-connection")
                            CastDivider()
                        }
                        version
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if state.session.account?.fid != nil { signOutSection }
                }
            }
            .background(FatlineStyle.paper)
            .navigationTitle("Settings")
            .settingsTitleBar()
            .toolbar {
                // A toolbar item keeps this bar as tall as People's, so the window doesn't jump between them.
                ToolbarItem(placement: .primaryAction) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .foregroundStyle(FatlineStyle.ink)
        .tint(FatlineStyle.action)
        .alert("Couldn’t sign out", isPresented: Binding(get: { signOutError != nil }, set: { if !$0 { signOutError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(signOutError ?? "")
        }
    }

    private func account(_ username: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: username)
                .font(FatlineStyle.bodyStrong)
            Spacer(minLength: 8)
            Text("Signed in")
                .font(FatlineStyle.meta)
                .foregroundStyle(FatlineStyle.secondary)
        }
        .frame(minHeight: FatlineStyle.regularButtonHeight)
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func settingsRow(_ title: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(FatlineStyle.body)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
            }
            Image(systemName: "chevron.right")
                .font(FatlineStyle.metaStrong)
                .foregroundStyle(FatlineStyle.secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: FatlineStyle.regularButtonHeight)
        .padding(.horizontal, FatlineStyle.gutter)
        .padding(.vertical, 6)
        .contentShape(.rect)
    }

    private var version: some View {
        Text(verbatim: FeedModel.versionLine)
            .font(FatlineStyle.meta)
            .foregroundStyle(FatlineStyle.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FatlineStyle.gutter)
            .padding(.top, 16)
    }

    private var signOutSection: some View {
        let block = state.session.signOutBlock
        return VStack(alignment: .leading, spacing: 0) {
            CastDivider()
            Button { confirmingSignOut = true } label: {
                Text("Sign Out")
                    .font(FatlineStyle.body)
                    .foregroundStyle(block == nil ? FatlineStyle.danger : FatlineStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: FatlineStyle.regularButtonHeight, alignment: .leading)
                    .padding(.horizontal, FatlineStyle.gutter)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(block != nil)
            .accessibilityIdentifier("sign-out")
            .alert("Sign out of Fatline?", isPresented: $confirmingSignOut) {
                // Claiming Return for Cancel, so the system can't give it to Sign Out.
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
                Button("Sign Out", role: .destructive, action: signOut)
            } message: {
                Text("This removes the posting key from this Mac and keeps this account’s draft.")
            }
            if let block {
                Text(block)
                    .font(FatlineStyle.meta)
                    .foregroundStyle(FatlineStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FatlineStyle.gutter)
            }
        }
        .padding(.bottom, 8)
        .background(FatlineStyle.paper)
    }

    private func signOut() {
        do {
            try state.session.signOut()
        } catch {
            signOutError = error.localizedDescription
        }
    }
}

/// Changing how the app reaches Farcaster, from Settings. Saving goes back to Settings.
private struct ConnectionSettings: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ConnectionForm(settings: state.session.savedConnection) { choice in
            try state.session.useConnection(choice)
            dismiss()
        }
    }
}

extension View {
    /// Paper runs under the title bar, as it does in the feed window.
    func settingsTitleBar() -> some View {
        toolbarBackground(FatlineStyle.paper, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }
}
