import Foundation

/// The on-disk cache of parsed days, one JSON file per report date.
///
/// Daily reports are immutable once Apple publishes them, so an `.observed` day is fetched exactly
/// once and never again. That isn't only politeness toward Apple's servers: daily reports are
/// deleted after a year and never regenerated, so past that point this cache is the only copy.
///
/// Nothing here holds a credential. The files contain sales figures and app names — the same thing
/// the menu displays.
public struct ReportStore {
    private let directory: URL
    private let fileManager = FileManager.default

    /// Apple deletes daily reports after one year. The furthest back a fetch can reach — anything
    /// older exists only in this cache.
    public static let appleRetentionDays = 365

    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Vantage", isDirectory: true)
    }

    public init(directory: URL = ReportStore.defaultDirectory) {
        self.directory = directory
    }

    private func url(for date: ReportDate) -> URL {
        // The filename is the report date. Never the vendor number — a path can end up in an error
        // message, and the vendor number is a credential.
        directory.appendingPathComponent("\(date.apiString).json")
    }

    // MARK: - Reading

    /// The cached day, or nil if it isn't cached or the file is unusable.
    ///
    /// A corrupt file is treated as absent rather than as an error: the fix is to fetch that day
    /// again, which is exactly what "not cached" already causes.
    public func load(_ date: ReportDate) -> DaySales? {
        guard let data = try? Data(contentsOf: url(for: date)),
              let day = try? JSONDecoder().decode(DaySales.self, from: data)
        else { return nil }
        // A file whose name and contents disagree would silently attribute one day's money to
        // another. Trust neither over the other — refetch.
        guard day.date == date else { return nil }
        return day
    }

    public func loadAll(_ dates: [ReportDate]) -> [DaySales] {
        dates.compactMap { load($0) }
    }

    /// Every date with a file on disk, oldest first. Names only — a corrupt file is still listed,
    /// and `load` is what decides it's unusable.
    public func cachedDates() -> [ReportDate] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.compactMap { name in
            name.hasSuffix(".json") ? ReportDate(apiString: String(name.dropLast(5))) : nil
        }.sorted()
    }

    /// Everything cached, however old. For reads that aren't bounded by a display window — the
    /// CLI, and what Settings says is on disk.
    public func loadAllCached() -> [DaySales] {
        loadAll(cachedDates())
    }

    /// Bytes under the cache directory, subdirectories included — analytics, reviews and icons live
    /// there too, and the figure in Settings is what the whole cache costs.
    public func bytesOnDisk() -> Int64 {
        guard let walker = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Whether this date still needs fetching.
    ///
    /// `.observed` days never do. `.assumedZero` days do when the user explicitly asks — that's the
    /// escape hatch for a report that landed later than Apple's own published window, and the whole
    /// reason the two origins are distinguished. See `docs/REPORT_FORMAT.md`.
    public func needsFetch(_ date: ReportDate, userInitiated: Bool = false) -> Bool {
        guard let cached = load(date) else { return true }
        // A day read by an older parser holds less than the report did — gross sales, an app's SKU.
        // The *report* is still immutable; our reading of it was incomplete, and Apple keeps daily
        // reports for a year, so this refetches exactly those days once. See `ReportParser.version`.
        if cached.parserVersion < ReportParser.version { return true }
        switch cached.origin {
        case .observed: return false
        case .assumedZero: return userInitiated
        }
    }

    // MARK: - Writing

    @discardableResult
    public func save(_ day: DaySales) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Written atomically so a crash mid-write leaves the previous day's file intact rather
            // than a half-file that would decode as garbage.
            try encoder.encode(day).write(to: url(for: day.date), options: .atomic)
            return true
        } catch {
            // A cache that can't be written is a performance problem, not a correctness one — the
            // day was already parsed and is about to be displayed.
            return false
        }
    }

    public func forget(_ date: ReportDate) {
        try? fileManager.removeItem(at: url(for: date))
    }

    /// Deletes every day before `cutoff` and says how many went.
    ///
    /// Only ever called because the user asked. Apple keeps daily reports for one year, so past
    /// that a pruned day can never be fetched again — nothing in Vantage prunes on its own.
    @discardableResult
    public func prune(keepingSince cutoff: ReportDate) -> Int {
        let doomed = cachedDates().filter { $0 < cutoff }
        doomed.forEach(forget)
        return doomed.count
    }
}
