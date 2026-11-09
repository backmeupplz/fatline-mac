import AppKit
import Security

/// Offers each newer GitHub release once. Saying yes downloads it, checks its signature, and replaces this copy.
@MainActor
enum UpdateCheck {
    private static let latestRelease = URL(string: "https://api.github.com/repos/danromero/fatline-mac/releases/latest")!
    private static let download = URL(string: "https://github.com/danromero/fatline-mac/releases/latest/download/Fatline.dmg")!
    private static let announcedKey = "announcedUpdate"
    private static var lastCheck = Date.distantPast

    private struct Release: Decodable {
        let tag_name: String
    }

    private struct UpdateFailed: Error {}

    /// Called whenever the app comes forward as well as at launch, because people leave it open for days.
    static func runIfDue() {
        // Tests launch the app, and an alert would stop them.
        #if !DEBUG
        guard Date.now.timeIntervalSince(lastCheck) >= 24 * 60 * 60 else { return }
        lastCheck = .now
        Task { await run() }
        #endif
    }

    private static func run() async {
        guard let (data, _) = try? await URLSession.shared.data(from: latestRelease),
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return }

        let latest = String(release.tag_name.trimmingPrefix("v"))
        guard isNewer(latest, than: current),
              UserDefaults.standard.string(forKey: announcedKey) != latest
        else { return }
        UserDefaults.standard.set(latest, forKey: announcedKey)

        let alert = NSAlert()
        alert.messageText = "Fatline \(latest) is available"
        alert.informativeText = "You have version \(current). Fatline will restart to update."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let app = Bundle.main.bundleURL
            try await install(over: app, current: current)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            NSApp.terminate(nil)
        } catch {
            // A copy that can't be replaced, like one running from the disk image, can still be updated by hand.
            NSWorkspace.shared.open(download)
        }
    }

    nonisolated static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    @concurrent
    nonisolated private static func install(over app: URL, current: String) async throws {
        let (dmg, _) = try await URLSession.shared.download(from: download)
        let files = FileManager.default
        // On the app's own volume, so the final swap is a rename.
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer {
            try? files.removeItem(at: work)
            try? files.removeItem(at: dmg)
        }

        let mount = work.appending(path: "mount")
        let staged = work.appending(path: "Fatline.app")
        try runTool("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path)
        defer { try? runTool("/usr/bin/hdiutil", "detach", mount.path, "-force") }
        try runTool("/usr/bin/ditto", mount.appending(path: "Fatline.app").path, staged.path)

        try requireSameSigner(staged)
        guard let version = Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              isNewer(version, than: current)
        else { throw UpdateFailed() }

        _ = try files.replaceItemAt(app, withItemAt: staged)
    }

    /// The real check on what was downloaded: it has to satisfy the signing requirement of the running app.
    nonisolated private static func requireSameSigner(_ candidate: URL) throws {
        var running: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        else { throw UpdateFailed() }
    }

    nonisolated private static func runTool(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailed() }
    }
}
