import Foundation

/// The on-disk cache of engagement days, one file per app.
///
/// **A merging archive**, which is a third thing again from `ReportStore`'s immutable archive and
/// `ReviewStore`'s TTL cache. Each refresh fetches only the newest handful of instances, so history
/// accumulates here across refreshes rather than being re-downloaded — analytics instances are
/// retained by Apple for 35 days, so anything older than that exists only in this file.
///
/// Later data for a date **replaces** earlier data for that date rather than adding to it: Apple
/// revises a day as late events land, and a day is only complete two days after the fact.
public struct AnalyticsStore {
    /// How long before a refresh is worth making. Analytics moves on a daily cadence and a day's
    /// figures aren't final for two days, so anything shorter spends requests to redraw the same
    /// numbers.
    public static let maxAge: TimeInterval = 6 * 60 * 60

    /// How many daily instances a first refresh takes.
    ///
    /// Not the full retention window: a first refresh already costs a segments call and a download
    /// per instance **per app**, and history grows from here on its own.
    public static let openingInstances = 7

    /// Days always re-fetched, however fresh the cache.
    ///
    /// Apple revises a day as late events land and a day isn't final until two days after it, so a
    /// refresh that only took new days would permanently keep the first, provisional figures.
    public static let revisionOverlap = 3

    /// Apple keeps daily instances for **35 days**. Asking for more isn't wrong, it's pointless —
    /// and it's the one limit no amount of code routes around. Past this the data exists only here.
    public static let retentionInstances = 35

    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL = ReportStore.defaultDirectory.appendingPathComponent(
        "analytics", isDirectory: true)) {
        self.directory = directory
    }

    struct Entry: Codable {
        let days: [EngagementDay]
        let fetchedAt: Date
    }

    /// Validated, not sanitized — the same rule every other store in this app follows.
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

    public func load(_ appleID: String) -> [EngagementDay]? { entry(appleID)?.days }

    public func needsFetch(_ appleID: String, now: Date = Date()) -> Bool {
        guard let fetchedAt = entry(appleID)?.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > Self.maxAge
    }

    /// How many of the newest daily instances this app needs, given how long it's been.
    ///
    /// **This used to be a fixed 7**, which quietly meant that not opening the Analytics section
    /// for a fortnight left days 8–14 missing forever: every later refresh asked for the newest
    /// seven again, and nothing ever went back for the rest. Apple still had them — it keeps
    /// instances for 35 days — so the data was reachable the whole time and simply never requested.
    ///
    /// Covering the gap instead means any absence shorter than Apple's retention window repairs
    /// itself on the next look. Longer than that, the days are gone from Apple and no client can
    /// get them back.
    public func instancesNeeded(_ appleID: String, now: Date = Date()) -> Int {
        guard let fetchedAt = entry(appleID)?.fetchedAt else { return Self.openingInstances }
        let elapsed = now.timeIntervalSince(fetchedAt)
        // Rounded down: a gap of 1.5 days is one whole missing day, and `revisionOverlap` covers
        // the partial one either way.
        let missed = max(0, Int(elapsed / (24 * 60 * 60)))
        return min(missed + Self.revisionOverlap, Self.retentionInstances)
    }

    /// Merges fresh days into whatever is already cached, newest data winning per date.
    @discardableResult
    public func merge(_ fresh: [EngagementDay], for appleID: String,
                      now: Date = Date()) -> [EngagementDay] {
        var byDate: [ReportDate: EngagementDay] = [:]
        for day in load(appleID) ?? [] { byDate[day.date] = day }
        // Fresh second, so it overwrites. Apple revises a day as late events land, and a stale
        // count for a date is worse than no count — it looks settled.
        for day in fresh { byDate[day.date] = day }

        let merged = byDate.keys.sorted().map { byDate[$0]! }
        save(merged, for: appleID, now: now)
        return merged
    }

    @discardableResult
    func save(_ days: [EngagementDay], for appleID: String, now: Date = Date()) -> Bool {
        guard let url = url(for: appleID) else { return false }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Entry(days: days, fetchedAt: now)).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Called when the reviews key goes away — analytics was readable only because it existed.
    public func forgetAll() {
        try? fileManager.removeItem(at: directory)
    }
}
