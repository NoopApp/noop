import Foundation
import WhoopProtocol

/// User-initiated "Check for updates": one call to GitHub's PUBLIC releases API, made ONLY when the
/// user taps the button. No background polling and no auto-update — it just reads the latest version
/// number and compares it to the installed one; nothing about the user is sent. (The distributed
/// build is unsandboxed, so no network entitlement is involved; sandboxed local dev builds block
/// this call. Networking is otherwise only the opt-in, off-by-default AI Coach.)
@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String, url: URL, notes: String)
        case failed
    }

    @Published var state: State = .idle

    private static let endpoint = URL(string: "https://api.github.com/repos/NoopApp/noop/releases/latest")!

    func check(currentVersion: String) {
        guard state != .checking else { return }
        state = .checking
        Task {
            do {
                var req = URLRequest(url: Self.endpoint, timeoutInterval: 12)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let urlString = json["html_url"] as? String,
                      let url = URL(string: urlString) else {
                    state = .failed
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let notes = Self.cleanNotes(json["body"] as? String ?? "")
                state = VersionCheck.isNewer(latest, than: currentVersion)
                    ? .available(version: latest, url: url, notes: notes)
                    : .upToDate(version: latest)
            } catch {
                state = .failed
            }
        }
    }

    /// Turn a GitHub release body into a short, readable "what's new" for an inline preview: drop the
    /// "Downloads"/footer boilerplate, strip the heaviest markdown markers, and cap the length.
    static func cleanNotes(_ body: String) -> String {
        var s = body.components(separatedBy: "Downloads").first ?? body
        for marker in ["**", "## ", "# "] { s = s.replacingOccurrences(of: marker, with: "") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 700 { s = String(s.prefix(700)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return s
    }
}
