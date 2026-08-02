import Foundation

/// Fetches the days that aren't cached yet, one at a time.
///
/// Serial and unhurried on purpose. Thirty days is thirty requests against a rolling-hour limit of
/// several thousand, so this is nowhere near Apple's ceiling — but a burst of parallel requests from
/// a menu bar app on every launch is bad manners for no gain, and the results are only needed once
/// the whole window is in.
public final class Backfill {
    private let provider: SalesProvider
    private let store: ReportStore

    /// Gap between requests. Long enough to be visibly gentle, short enough that a cold start
    /// finishes while the user is still curious.
    public var delayBetweenRequests: TimeInterval = 0.4

    public init(provider: SalesProvider, store: ReportStore) {
        self.provider = provider
        self.store = store
    }

    /// Fetches every date in `dates` that needs it, newest first, and reports each day as it lands.
    ///
    /// Newest first because the menu bar shows yesterday: the number the user is actually waiting
    /// for should arrive in the first request, not the thirtieth.
    ///
    /// - Parameters:
    ///   - userInitiated: true when the user pressed Refresh Now, which is the only thing that
    ///     re-fetches a day previously written off as an assumed zero.
    ///   - now: injectable clock, so the "has this report given up on arriving" rule is testable.
    ///   - onDay: called on an arbitrary queue as each day resolves.
    ///   - completion: called once, after the last date.
    public func run(dates: [ReportDate], userInitiated: Bool = false, now: Date = Date(),
                    onDay: @escaping (DaySales) -> Void,
                    completion: @escaping (Error?) -> Void) {
        let queue = dates.sorted(by: >).filter { store.needsFetch($0, userInitiated: userInitiated) }
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
                if !date.mayStillArrive(now: now) {
                    let zero = DaySales.zero(on: date, fetchedAt: now)
                    self.store.save(zero)
                    onDay(zero)
                }

            case .failure(let error):
                // Keep going. One refused day shouldn't cost the other twenty-nine, and a
                // rate-limit or a blip partway through a backfill is common. The first error is
                // carried to the end so the menu can still say something went wrong.
                carriedError = carriedError ?? error
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
