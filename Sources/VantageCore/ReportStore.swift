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

    /// Whether this date still needs fetching.
    ///
    /// `.observed` days never do. `.assumedZero` days do when the user explicitly asks — that's the
    /// escape hatch for a report that landed later than Apple's own published window, and the whole
    /// reason the two origins are distinguished. See `docs/REPORT_FORMAT.md`.
    public func needsFetch(_ date: ReportDate, userInitiated: Bool = false) -> Bool {
        guard let cached = load(date) else { return true }
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

    /// Apple keeps daily reports for one year. Anything older can never be re-fetched, so pruning
    /// past the window Vantage displays is safe but permanent — kept generous on purpose.
    public func prune(keepingSince cutoff: ReportDate) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".json") {
            guard let date = ReportDate(apiString: String(name.dropLast(5))), date < cutoff
            else { continue }
            forget(date)
        }
    }
}
