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
        /// Snapshot instances already imported, so a history import resumes rather than restarts.
        /// Absent in files written before history import existed, which is what makes those
        /// installs ask for their history on the next refresh.
        var historyInstanceIDs: [String]?
        /// Set once every snapshot instance has been imported. Nothing re-reads a snapshot after
        /// this: it is generated once, and Apple expires its instances.
        var historyImportedAt: Date?
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
    /// **This used to be a fixed 7**, which quietly meant that not opening Vantage for a fortnight
    /// left days 8–14 missing forever: every later refresh asked for the newest
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

    // MARK: - History, imported once per app

    /// How many snapshot instances one refresh imports.
    ///
    /// A snapshot can hold years, and each instance costs a segments call plus a download. A
    /// bounded bite per refresh keeps a first run from turning into hundreds of requests; the next
    /// refresh continues where this one stopped.
    public static let historyInstanceCap = 50

    public func needsHistory(_ appleID: String) -> Bool {
        entry(appleID)?.historyImportedAt == nil
    }

    /// Instances not yet imported for this app, capped, **in the order given**.
    ///
    /// Instance IDs are opaque, so the caller orders them — oldest processing date first, because
    /// the point of the import is the past: a run that stops at the cap should have extended the
    /// history rather than re-fetched days the ongoing request already covers.
    public func pendingHistoryInstances(_ available: [String], for appleID: String) -> [String] {
        let done = Set(entry(appleID)?.historyInstanceIDs ?? [])
        return Array(available.filter { !done.contains($0) }.prefix(Self.historyInstanceCap))
    }

    public func recordHistoryInstances(_ ids: [String], for appleID: String) {
        update(appleID) { entry in
            entry.historyInstanceIDs = Array(Set(entry.historyInstanceIDs ?? []).union(ids)).sorted()
        }
    }

    public func markHistoryImported(_ appleID: String, now: Date = Date()) {
        update(appleID) { entry in entry.historyImportedAt = now }
    }

    /// Reads, changes and writes one app's entry, creating an empty one if this app has no file
    /// yet — the history flags have to survive an app whose engagement hasn't arrived.
    private func update(_ appleID: String, _ change: (inout Entry) -> Void) {
        guard let url = url(for: appleID) else { return }
        var entry = self.entry(appleID) ?? Entry(days: [], fetchedAt: .distantPast)
        change(&entry)
        write(entry, to: url)
    }

    private func write(_ entry: Entry, to url: URL) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entry).write(to: url, options: .atomic)
        } catch {
            // Same bargain as `save`: a cache that can't be written is a slower app, not a wrong one.
        }
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
            // History flags are carried over: a merge is not an import, and dropping them here
            // would re-import an app's whole history on every refresh.
            let existing = entry(appleID)
            try encoder.encode(Entry(days: days, fetchedAt: now,
                                     historyInstanceIDs: existing?.historyInstanceIDs,
                                     historyImportedAt: existing?.historyImportedAt))
                .write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Apps with an archive on disk.
    private func appleIDs() -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            .filter { url(for: $0) != nil }
    }

    /// Every date any app has figures for. A date is one day of analytics however many apps
    /// share it — that's the unit Settings counts in.
    public func cachedDates() -> Set<ReportDate> {
        Set(appleIDs().flatMap { load($0)?.map(\.date) ?? [] })
    }

    /// Drops days before `cutoff` from every app's archive and says how many distinct dates went.
    ///
    /// **`fetchedAt` is kept, not reset.** Pruning is not a fetch: stamping the file as fresh would
    /// tell `needsFetch` and `instancesNeeded` that nothing is missing and skip the next real one.
    /// Apple keeps instances for 35 days, so days pruned past that are gone for good.
    @discardableResult
    public func prune(keepingSince cutoff: ReportDate) -> Int {
        var removed: Set<ReportDate> = []
        for id in appleIDs() {
            guard let entry = entry(id) else { continue }
            let kept = entry.days.filter { $0.date >= cutoff }
            guard kept.count != entry.days.count else { continue }
            entry.days.filter { $0.date < cutoff }.forEach { removed.insert($0.date) }
            save(kept, for: id, now: entry.fetchedAt)
        }
        return removed.count
    }

    /// Called when the reviews key goes away — analytics was readable only because it existed.
    public func forgetAll() {
        try? fileManager.removeItem(at: directory)
    }
}
