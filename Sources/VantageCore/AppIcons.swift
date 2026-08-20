import Foundation

/// App icons, from Apple's public iTunes Lookup API.
///
/// **This is Vantage's third and fourth network destination**, and the reason the "two hosts" claim
/// in SECURITY.md had to change. The App Store Connect API exposes no icon URL for an app — there is
/// no field for it on `/v1/apps/{id}` — so the only source is the public storefront lookup, which
/// answers on `itunes.apple.com` and points at artwork on `*.mzstatic.com`.
///
/// What the request reveals: the Apple ID of an app you publish, to Apple, unauthenticated. No
/// token, no vendor number, no sales figures. It is the same request the App Store website makes,
/// and it carries nothing that identifies the caller.
///
/// Redirects are refused here exactly as they are everywhere else, so a lookup that tries to send
/// us somewhere unnamed fails and the row falls back to its placeholder.
public enum ITunesLookup {
    public static let host = "itunes.apple.com"

    /// Parses the artwork URL out of a lookup response.
    ///
    /// Separated from the request so the JSON handling is testable without a network — the same
    /// split `ASCClient.fetchTSV` uses, and for the same reason.
    ///
    /// Prefers the 100pt artwork: the rows draw at around 28pt, so 100 covers 2x and 3x without
    /// pulling a 512px image per app into memory for a list that may be twenty rows long.
    public static func artworkURL(from data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let first = results.first
        else { return nil }

        // Ordered by preference, not by size: 512 is the fallback only because an app missing the
        // smaller renditions is likelier than one missing all three.
        for key in ["artworkUrl100", "artworkUrl60", "artworkUrl512"] {
            if let string = first[key] as? String,
               let url = URL(string: string),
               url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    static func lookupURL(appleID: String) -> URL? {
        // `entity=software` keeps the answer to apps: a bare id lookup can match other kinds of
        // store item, and matching the wrong one would put a music cover on a sales row.
        URL(string: "https://\(host)/lookup?id=\(appleID)&entity=software")
    }
}

/// Where fetched icons live between launches.
///
/// Icons change rarely and cost two requests each, so they're cached indefinitely and refreshed
/// only when the file is missing. Nothing here holds a credential — these are public store images.
public struct AppIconStore {
    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL = ReportStore.defaultDirectory.appendingPathComponent(
        "icons", isDirectory: true)) {
        self.directory = directory
    }

    /// Apple IDs are digits, but they arrive from a parsed report, so the filename is built from a
    /// filtered copy rather than trusted — a `../` in that position would write outside the cache.
    private func url(for appleID: String) -> URL? {
        let safe = appleID.filter { $0.isNumber }
        guard !safe.isEmpty else { return nil }
        return directory.appendingPathComponent("\(safe).png")
    }

    public func load(_ appleID: String) -> Data? {
        guard let url = url(for: appleID) else { return nil }
        return try? Data(contentsOf: url)
    }

    @discardableResult
    public func save(_ data: Data, for appleID: String) -> Bool {
        guard let url = url(for: appleID) else { return false }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            // A cache that can't be written costs a refetch next launch, nothing more.
            return false
        }
    }
}

/// A source of app icons, so the panel doesn't learn where they come from.
public protocol AppIconProvider {
    /// `nil` means no icon is available — a free-standing fact, not an error. The row draws a
    /// placeholder and says nothing.
    func icon(for appleID: String, completion: @escaping (Data?) -> Void)
}

public final class ITunesIconClient: AppIconProvider {
    private let store: AppIconStore

    /// Ephemeral and redirect-refusing, like every other session in this app. No cookies, and no
    /// URL cache on disk — `AppIconStore` is the only thing that persists.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
    }()

    public init(store: AppIconStore = AppIconStore()) {
        self.store = store
    }

    public func icon(for appleID: String, completion: @escaping (Data?) -> Void) {
        if let cached = store.load(appleID) {
            completion(cached)
            return
        }
        guard let lookup = ITunesLookup.lookupURL(appleID: appleID) else {
            completion(nil)
            return
        }

        Self.session.dataTask(with: lookup) { [store] data, _, _ in
            guard let data, let artwork = ITunesLookup.artworkURL(from: data) else {
                completion(nil)
                return
            }
            Self.session.dataTask(with: artwork) { imageData, _, _ in
                guard let imageData, !imageData.isEmpty else {
                    completion(nil)
                    return
                }
                store.save(imageData, for: appleID)
                completion(imageData)
            }.resume()
        }.resume()
    }
}
