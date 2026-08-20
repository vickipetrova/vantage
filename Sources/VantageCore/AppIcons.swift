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
               isPermittedArtworkHost(url) {
                return url
            }
        }
        return nil
    }

    /// Whether a body-supplied artwork URL may be fetched.
    ///
    /// **Host, not just scheme.** Refusing redirects does nothing here: this isn't a redirect, it's
    /// a fresh request the code elects to make from a URL a response body chose. Without a host
    /// check, any reply from the lookup endpoint could direct Vantage to fetch from anywhere, which
    /// would make SECURITY.md's list of destinations a description rather than a guarantee.
    ///
    /// The leading dot on the suffix matters — without it `evilmzstatic.com` passes.
    static func isPermittedArtworkHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == host_itunes || host.hasSuffix(".mzstatic.com") || host == "mzstatic.com"
    }

    static let host_itunes = "itunes.apple.com"

    /// A cap on artwork. A 100pt icon is a few tens of kilobytes; anything past this is not an icon,
    /// and without a limit a hostile or broken response could write until the disk filled.
    static let maxArtworkBytes = 4 * 1024 * 1024

    static func lookupURL(appleID: String) -> URL? {
        // Validated all-digits, like every other place an Apple ID leaves this app — here it can't
        // reach the host or path, but an unvalidated value can inject query parameters and
        // desynchronize the requested app from the cache filename, which would re-fetch that row's
        // icon on every launch forever.
        guard !appleID.isEmpty, appleID.allSatisfy({ $0.isNumber }) else { return nil }
        // `entity=software` keeps the answer to apps: a bare id lookup can match other kinds of
        // store item, and matching the wrong one would put a music cover on a sales row.
        return URL(string: "https://\(host)/lookup?id=\(appleID)&entity=software")
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

    /// Apple IDs are digits, but they arrive from a parsed report, so the value is **validated,
    /// not sanitized**, before it becomes a filename.
    ///
    /// Filtering non-digits out would defeat a `../` while quietly turning "../../123/x" into the
    /// cache entry for app 123 — one app's icon served for another. Refusing anything that isn't
    /// wholly digits is the only answer with no wrong outcome.
    private func url(for appleID: String) -> URL? {
        guard !appleID.isEmpty, appleID.allSatisfy({ $0.isNumber }) else { return nil }
        return directory.appendingPathComponent("\(appleID).png")
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

    /// Magic-number check, so only something that is actually an image is cached.
    ///
    /// Cheap and in `VantageCore`, which imports Foundation only and so cannot ask `NSImage`.
    static func looksLikeAnImage(_ data: Data) -> Bool {
        let prefixes: [[UInt8]] = [
            [0x89, 0x50, 0x4E, 0x47],  // PNG
            [0xFF, 0xD8, 0xFF],        // JPEG
            [0x47, 0x49, 0x46, 0x38],  // GIF
        ]
        // "RIFF????WEBP"
        if data.count >= 12, Array(data.prefix(4)) == Array("RIFF".utf8),
           Array(data[8..<12]) == Array("WEBP".utf8) {
            return true
        }
        return prefixes.contains { data.count >= $0.count && Array(data.prefix($0.count)) == $0 }
    }

    /// Reads never happen on the caller's thread.
    ///
    /// The cached path used to hit the disk and call back inline, so a panel opening with N cached
    /// apps performed N blocking reads — and N PNG decodes in the caller — inside one render pass.
    private static let queue = DispatchQueue(label: "com.vickipetrova.vantage.icons",
                                             qos: .utility)

    public func icon(for appleID: String, completion: @escaping (Data?) -> Void) {
        Self.queue.async { [store] in
            if let cached = store.load(appleID) {
                completion(cached)
                return
            }
            self.fetch(appleID, completion: completion)
        }
    }

    private func fetch(_ appleID: String, completion: @escaping (Data?) -> Void) {
        guard let lookup = ITunesLookup.lookupURL(appleID: appleID) else {
            completion(nil)
            return
        }

        Self.session.dataTask(with: lookup) { [store] data, _, _ in
            guard let data, let artwork = ITunesLookup.artworkURL(from: data) else {
                completion(nil)
                return
            }
            Self.session.dataTask(with: artwork) { imageData, response, _ in
                // Status is checked, unlike an earlier version that cached any non-empty body.
                // A 404's HTML — or the redirect body `NoRedirects` deliberately hands back — would
                // otherwise be written as `<appleID>.png` and kept forever, since the cache only
                // refetches when the file is missing. One transient error, one permanently broken
                // icon.
                guard let imageData, !imageData.isEmpty,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      imageData.count <= ITunesLookup.maxArtworkBytes,
                      Self.looksLikeAnImage(imageData)
                else {
                    completion(nil)
                    return
                }
                store.save(imageData, for: appleID)
                completion(imageData)
            }.resume()
        }.resume()
    }
}
