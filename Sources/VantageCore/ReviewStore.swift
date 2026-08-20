import Foundation

/// The on-disk cache of reviews, one JSON file per app.
///
/// **Unlike `ReportStore`, this is a TTL cache rather than an archive.** A daily sales report is
/// immutable once Apple publishes it, so `ReportStore` fetches a day exactly once, ever. Reviews are
/// not: new ones arrive, and a response can be written, edited or deleted from App Store Connect's
/// own web UI while Vantage isn't looking. Treating them as immutable would show a reply that has
/// since been deleted, indefinitely.
///
/// Nothing here holds a credential. The files contain public review text and Apple's opaque IDs.
public struct ReviewStore {
    /// How long a cached page is trusted before it's refetched.
    ///
    /// Reviews arrive over hours, not seconds, and a portfolio-wide view already costs one request
    /// per app — so refetching on every glance would spend the hourly budget to redraw text that
    /// almost never changed. An hour is short enough that a reply published elsewhere shows up the
    /// same session, and Refresh is always there for the impatient case.
    public static let maxAge: TimeInterval = 60 * 60

    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL = ReportStore.defaultDirectory.appendingPathComponent(
        "reviews", isDirectory: true)) {
        self.directory = directory
    }

    /// What one app's cache file holds.
    struct Entry: Codable {
        let reviews: [CustomerReview]
        let fetchedAt: Date
    }

    /// Validated, not sanitized — same rule as `AppIconStore`, and for the same reason: an Apple ID
    /// arrives from a parsed report and is about to become a filename.
    private func url(for appleID: String) -> URL? {
        guard !appleID.isEmpty, appleID.allSatisfy({ $0.isNumber }) else { return nil }
        return directory.appendingPathComponent("\(appleID).json")
    }

    private func entry(_ appleID: String) -> Entry? {
        guard let url = url(for: appleID),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        return entry
    }

    // MARK: - Reading

    /// Whatever is cached, fresh or not.
    ///
    /// Stale reviews are still worth drawing while a refresh runs — the alternative is a blank
    /// panel every time the cache ages out, which is worse than text that's an hour old.
    public func load(_ appleID: String) -> [CustomerReview]? {
        entry(appleID)?.reviews
    }

    public func fetchedAt(_ appleID: String) -> Date? {
        entry(appleID)?.fetchedAt
    }

    public func needsFetch(_ appleID: String, now: Date = Date()) -> Bool {
        guard let fetchedAt = entry(appleID)?.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > Self.maxAge
    }

    // MARK: - Writing

    @discardableResult
    public func save(_ reviews: [CustomerReview], for appleID: String,
                     now: Date = Date()) -> Bool {
        guard let url = url(for: appleID) else { return false }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let entry = Entry(reviews: reviews, fetchedAt: now)
            // Atomic, so a crash mid-write leaves the previous page intact rather than a half-file
            // that decodes as nothing.
            try encoder.encode(entry).write(to: url, options: .atomic)
            return true
        } catch {
            // A cache that can't be written costs a refetch, not correctness.
            return false
        }
    }

    public func forget(_ appleID: String) {
        guard let url = url(for: appleID) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Called when the reviews key is removed. Reviews were readable only because that key existed,
    /// so taking the key back has to take the cached text with it.
    public func forgetAll() {
        try? fileManager.removeItem(at: directory)
    }
}
