import AppKit
import Security

/// Updates from GitHub releases: on launch and every 6 hours, if the newest release is newer than this build, it
/// downloads the release's zip, checks the new app is signed by the same certificate as this one (so a tampered or
/// foreign build is never installed, and macOS keeps the permissions), swaps it in and opens it. The new copy
/// force-quits this one on launch (see AppDelegate), so the system Dock never flashes back.
enum Updater {
    static let repo = "AyanaayaW/Chaval"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private static var busy = false

    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if Store.shared.settings.autoUpdate { check() } }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in if Store.shared.settings.autoUpdate { check() } }
    }

    /// `done` gets a line for Settings: what happened.
    static func check(done: @escaping (String) -> Void = { _ in }) {
        guard !busy else { return done("Already checking…") }
        busy = true
        let finish = { (s: String) in DispatchQueue.main.async { busy = false; done(s) } }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=1")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let r = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first,
                  let tag = r["tag_name"] as? String else { return finish("Couldn't reach GitHub.") }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard newer(latest, than: version) else { return finish("Up to date (\(version)).") }
            guard let assets = r["assets"] as? [[String: Any]],
                  let link = assets.lazy.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix(".zip") }),
                  let url = URL(string: link) else { return finish("\(latest) has no download yet.") }
            URLSession.shared.downloadTask(with: url) { file, _, _ in
                guard let file else { return finish("Download failed.") }
                finish(install(zip: file) ?? "Installing \(latest)…")
            }.resume()
        }.resume()
    }

    /// "0.2-beta" > "0.1-beta"; same numbers: a plain release beats its beta.
    static func newer(_ a: String, than b: String) -> Bool {
        let (na, nb) = (a.split(separator: "-").first.map(String.init) ?? a, b.split(separator: "-").first.map(String.init) ?? b)
        switch na.compare(nb, options: .numeric) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame: return !a.contains("-") && b.contains("-")
        }
    }

    /// Returns an error line, or nil once the new copy is opening.
    private static func install(zip: URL) -> String? {
        let fm = FileManager.default, here = Bundle.main.bundleURL
        let dir = fm.temporaryDirectory.appendingPathComponent("chaval-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Script.shell("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let new = dir.appendingPathComponent(here.lastPathComponent)
        guard fm.fileExists(atPath: new.path) else { return "The download didn't contain \(here.lastPathComponent)." }
        guard sameSigner(new) else { return "The update isn't signed like this copy, so it wasn't installed." }
        let old = dir.appendingPathComponent("old.app")
        do {
            try fm.moveItem(at: here, to: old)
            do { try fm.moveItem(at: new, to: here) } catch { try? fm.moveItem(at: old, to: here); throw error }
        } catch { return "Couldn't replace the app: \(error.localizedDescription)" }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: here, configuration: cfg) }
        return nil
    }

    /// The new app must satisfy this app's designated requirement (same signing certificate and bundle id).
    /// A build signed ad hoc (from source) has a per-build requirement, so it never auto-updates: use git there.
    static func sameSigner(_ app: URL) -> Bool {
        var me: SecCode?, meStatic: SecStaticCode?, req: SecRequirement?, new: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new else { return false }
        return SecStaticCodeCheckValidity(new, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), req) == errSecSuccess
    }
}
