import Foundation

/// Fetches the days that aren't cached yet, one at a time.
///
/// Serial and unhurried on purpose. A full year is 365 requests against a rolling-hour limit of
/// several thousand, so even a first run is nowhere near Apple's ceiling — but a burst of parallel
/// requests from a menu bar app is bad manners for no gain. Newest first means the days the panel
/// shows land in the first seconds; the rest of the year fills in behind them, once.
public final class Backfill {
    private let provider: SalesProvider
    private let store: ReportStore

    /// Gap between requests. Long enough to be visibly gentle, short enough that a cold start
    /// finishes while the user is still curious.
    public var delayBetweenRequests: TimeInterval = 0.4

    /// How far back Refresh Now re-asks about days recorded as assumed zeros.
    ///
    /// That re-ask exists for a report published later than Apple's own window — hours late, a day
    /// at most. It was thirty days when thirty days was all Vantage fetched; with a year of history,
    /// re-asking about every zero would make one click a few hundred requests for an app that often
    /// sells nothing.
    public static let lateReportWindowDays = 30

    public init(provider: SalesProvider, store: ReportStore) {
        self.provider = provider
        self.store = store
    }

    /// Whether a failure is about the credentials rather than the date, and so will repeat for
    /// every remaining request.
    ///
    /// Rate limiting is deliberately not fatal: it's temporary, and the days already fetched are
    /// worth keeping. Network failures aren't either — a flaky connection often recovers within
    /// the same run.
    static func isFatal(_ error: Error) -> Bool {
        switch error as? SalesError {
        case .noCredentials, .unauthorized, .forbidden: return true
        default: return false
        }
    }

    /// Fetches every date in `dates` that needs it, newest first, and reports each day as it lands.
    ///
    /// Newest first because the menu bar shows yesterday: the number the user is actually waiting
    /// for should arrive in the first request, not the thirtieth.
    ///
    /// - Parameters:
    ///   - userInitiated: true when the user pressed Refresh Now, which is the only thing that
    ///     re-fetches a day previously written off as an assumed zero — within
    ///     `lateReportWindowDays`.
    ///   - now: injectable clock, so the "has this report given up on arriving" rule is testable.
    ///   - onDay: called on an arbitrary queue as each day resolves.
    ///   - completion: called once, after the last date.
    public func run(dates: [ReportDate], userInitiated: Bool = false, now: Date = Date(),
                    onDay: @escaping (DaySales) -> Void,
                    completion: @escaping (Error?) -> Void) {
        let newest = ReportDate.yesterday(now: now)
        let queue = dates.sorted(by: >).filter { date in
            let recent = date.days(to: newest) < Self.lateReportWindowDays
            return store.needsFetch(date, userInitiated: userInitiated && recent)
        }
        next(queue, index: 0, now: now, firstError: nil, onDay: onDay, completion: completion)
    }

    private func next(_ dates: [ReportDate], index: Int, now: Date, firstError: Error?,
                      onDay: @escaping (DaySales) -> Void,
                      completion: @escaping (Error?) -> Void) {
        guard index < dates.count else {
            completion(firstError)
            return
        }
        let date = dates[index]

        provider.fetch(date) { result in
            var carriedError = firstError
            switch result {
            case .success(.some(let day)):
                self.store.save(day)
                onDay(day)

            case .success(.none):
                // No report. Either it hasn't been published yet, or the day genuinely had no
                // units — Apple only generates a report when at least one sold, and the status
                // code is identical either way. Resolved by the clock; see docs/REPORT_FORMAT.md.
                //
                // Except near the end of Apple's year, where a 404 may mean the report was deleted.
                // Left uncached, so it's asked about again rather than frozen as a zero.
                if !date.mayStillArrive(now: now), !date.isTooOldToAssumeZero(now: now) {
                    let zero = DaySales.zero(on: date, fetchedAt: now)
                    self.store.save(zero)
                    onDay(zero)
                }

            case .failure(let error):
                // Keep going. One refused day shouldn't cost the other twenty-nine, and a
                // rate-limit or a blip partway through a backfill is common. The first error is
                // carried to the end so the menu can still say something went wrong.
                carriedError = carriedError ?? error

                // Unless the failure is about the credentials rather than the date, in which case
                // every remaining request will fail the same way. Grinding through twenty-nine
                // more is a minute of the user staring at "Loading…" before being told their key
                // is wrong — and a minute of pointless traffic at Apple.
                if Backfill.isFatal(error) {
                    completion(carriedError)
                    return
                }
            }

            guard index + 1 < dates.count else {
                completion(carriedError)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + self.delayBetweenRequests) {
                self.next(dates, index: index + 1, now: now, firstError: carriedError,
                          onDay: onDay, completion: completion)
            }
        }
    }
}
