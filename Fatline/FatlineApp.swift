import AppKit
import SwiftUI

@main
struct FatlineApp: App {
    @NSApplicationDelegateAdaptor(FatlineAppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        // A Window scene, so there's only ever one feed window.
        Window("Fatline", id: "feed") {
            AppRoot()
                .environment(state)
                .frame(minWidth: 420, minHeight: 480 - FatlineStyle.headerHeight)
        }
        .defaultSize(width: 440, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { FatlineCommands(state: state) }

        // A plain window, because a Settings scene stacks People's back and refresh buttons under the title.
        Window("Settings", id: "settings") {
            SettingsWindow()
                .environment(state)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
    }
}

/// What the menus need to know, published through the focused scene as menu commands expect.
struct MenuFlags: Equatable {
    let signedIn: Bool
    let hasFeed: Bool
    let composing: Bool
}

extension FocusedValues {
    @Entry var menuFlags: MenuFlags?
}

extension View {
    func publishesMenuFlags(_ state: AppState) -> some View {
        let flags = MenuFlags(
            signedIn: state.session.account?.fid != nil,
            hasFeed: state.model != nil,
            composing: state.session.showComposer
        )
        return focusedSceneValue(\.menuFlags, flags)
            .onChange(of: flags) { MenuFlags.refreshMenusSoon() }
            // Flags that are already right at launch never change, and they only count once a window is key.
            .onAppear { MenuFlags.refreshMenusSoon() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                MenuFlags.refreshMenusSoon()
            }
    }
}

extension MenuFlags {
    /// SwiftUI only rebuilds its menu items when a menu opens, which would leave the keyboard
    /// shortcuts behind until then. This asks once new flags have had time to arrive.
    @MainActor
    static func refreshMenusSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            for item in NSApp.mainMenu?.items ?? [] {
                if let menu = item.submenu { menu.delegate?.menuNeedsUpdate?(menu) }
            }
        }
    }
}

private struct FatlineCommands: Commands {
    let state: AppState
    @FocusedValue(\.menuFlags) private var flags
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",")
                .disabled(flags?.hasFeed != true)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Cast", action: state.session.openComposer)
                .keyboardShortcut("n")
                .disabled(flags?.signedIn != true || flags?.composing == true)
        }
        CommandGroup(before: .toolbar) {
            Button("Refresh") {
                Task { await state.model?.refresh(reason: "pull") }
            }
            .keyboardShortcut("r")
            .disabled(flags?.hasFeed != true || flags?.composing == true)
            Divider()
        }
        CommandMenu("Debug") {
            Button("Copy Diagnostics", action: state.copyDiagnostics)
                .disabled(flags?.hasFeed != true || flags?.composing == true)
        }
        CommandGroup(replacing: .help) {}
    }
}

/// A change of account or connection replaces the feed, so nothing keeps reading through the old one.
private struct FeedOwner: Equatable {
    let fid: UInt64
    let connection: Connection
}

/// What the app's windows and menus share.
@MainActor
@Observable
final class AppState {
    let session = PostingSession()
    private(set) var model: FeedModel?
    private var modelOwner: FeedOwner?
    /// Casts being deleted, which stay dimmed in the feed until the network answers.
    var deleting: Set<String> = []
    var confirmingDelete: FeedCast?
    var deleteError: String?
    var showDeleteHelp = false

    init() {
        session.loadSavedAccount()
        openFeed()
    }

    var fid: UInt64? { session.account?.fid ?? Self.readOnlyFID }
    var username: String? { session.account?.username }

    /// Keeps the feed matched to whoever is signed in.
    func openFeed() {
        let owner = fid.map { FeedOwner(fid: $0, connection: session.connection) }
        guard owner != modelOwner else { return }
        modelOwner = owner
        confirmingDelete = nil
        deleteError = nil
        showDeleteHelp = false
        model = owner.map { FeedModel(directory: Self.accountFolder($0.fid), ownFID: $0.fid, ownHandle: username) }
    }

    func copyDiagnostics() {
        guard let model else { return }
        AppSupport.copyToClipboard(model.diagnostics)
        session.setPostToast(PostToast(detail: nil, confirmation: "Diagnostics copied"))
    }

    /// True until someone has chosen how this app reaches Farcaster.
    var needsConnection: Bool {
        session.savedConnection == nil && !Connection.isSetByLaunch
    }

    static func accountFolder(_ fid: UInt64) -> URL {
        PostingSession.accountFolder(fid)
    }

    /// `-FatlineFID 3` opens that account's public feed, read-only and with no sign-in.
    private static var readOnlyFID: UInt64? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "FatlineFID").flatMap(UInt64.init)
        #else
        nil
        #endif
    }
}

private struct AppRoot: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.needsConnection, state.model != nil {
                ConnectionSetup(finish: state.session.useConnection)
            } else if let model = state.model {
                FeedWindow(model: model)
                    .id(ObjectIdentifier(model))
            } else {
                WelcomeFlow(session: state.session) { SignInView() }
            }
        }
        .publishesMenuFlags(state)
        .feedTitleBar(showsPortal: state.model != nil && !state.needsConnection)
        // Closing the feed quits even with Settings open, so no window outlives the account it shows.
        .onDisappear { NSApp.terminate(nil) }
        .onChange(of: state.session.account?.fid) { state.openFeed() }
        .onChange(of: state.session.connection) { state.openFeed() }
        .task(id: state.session.account?.fid) { await state.session.checkKey() }
        .task { UpdateCheck.runIfDue() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.session.checkKeyIfDue()
            UpdateCheck.runIfDue()
        }
    }
}

/// Nothing needs to keep running once the feed window is gone.
final class FatlineAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // There's one feed window, so the tab commands would have nothing to do.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
