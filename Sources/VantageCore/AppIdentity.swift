import Foundation

/// Folds SKU-keyed phantom apps back into the apps they belong to.
///
/// **The problem.** An In-App Purchase row carries its own Apple Identifier — the purchase's, not
/// the app's — and names its app only through `Parent Identifier`, which holds the app's **SKU**.
/// `ReportParser` resolves that against the app's own row in the same report. But on a day when an
/// app sold no units of its own and only its purchases earned, there is no such row, so the
/// purchases group under the raw SKU. The panel then shows a row called `20251209_headshot_ai` with
/// no icon — because a SKU is not an Apple ID, and nothing can look one up.
///
/// **The fix.** That mapping does exist, just in a different day's report. `AppSales` records its
/// SKU, so any day where the app did sell teaches the whole window who `20251209_headshot_ai` is,
/// and the phantom merges into the real app.
///
/// **It heals itself.** A cache written before `AppSales` carried SKUs has none, and `.observed`
/// days are never refetched — so the phantom persists until the next day whose report happens to
/// include an app row for it. That's usually tomorrow, and no worse in the meantime than today.
public enum AppIdentity {
    /// SKU → the Apple ID and title of the app that owns it, learned from every day given.
    public static func skuIndex(_ days: [DaySales]) -> [String: (appleID: String, title: String)] {
        var index: [String: (appleID: String, title: String)] = [:]
        // Newest first, so the most recent title wins — apps get renamed.
        for day in days.sorted(by: { $0.date > $1.date }) {
            for app in day.apps where !app.sku.isEmpty && !app.appleID.isEmpty {
                // An entry whose own key is a SKU is a phantom and can't teach anything.
                guard index[app.sku] == nil, app.appleID != app.sku else { continue }
                index[app.sku] = (app.appleID, app.title)
            }
        }
        return index
    }

    /// Rewrites every day so phantom entries are merged into their real app.
    ///
    /// Sums rather than replaces: on a day with both a phantom *and* a real entry — which happens
    /// when the parser resolved some rows and not others — both hold real money.
    public static func resolve(_ days: [DaySales]) -> [DaySales] {
        let index = skuIndex(days)
        guard !index.isEmpty else { return days }

        return days.map { day in
            // Nothing to do unless this day actually has an entry keyed by a known SKU.
            guard day.apps.contains(where: { index[$0.appleID] != nil }) else { return day }

            var merged: [String: AppSales] = [:]
            var order: [String] = []
            for app in day.apps {
                let owner = index[app.appleID]
                let key = owner?.appleID ?? app.appleID
                if let existing = merged[key] {
                    merged[key] = AppSales(
                        appleID: key,
                        // Prefer a real app's title over a SKU used as one.
                        title: existing.appleID == existing.title ? app.title : existing.title,
                        downloads: existing.downloads + app.downloads,
                        proceeds: existing.proceeds.merging(app.proceeds, uniquingKeysWith: +),
                        unitsByProductType: existing.unitsByProductType
                            .merging(app.unitsByProductType, uniquingKeysWith: +),
                        sku: existing.sku.isEmpty ? app.sku : existing.sku)
                } else {
                    merged[key] = AppSales(
                        appleID: key,
                        title: owner?.title ?? app.title,
                        downloads: app.downloads,
                        proceeds: app.proceeds,
                        unitsByProductType: app.unitsByProductType,
                        sku: app.sku)
                    order.append(key)
                }
            }

            return DaySales(date: day.date, origin: day.origin, downloads: day.downloads,
                            proceeds: day.proceeds, apps: order.compactMap { merged[$0] },
                            fetchedAt: day.fetchedAt, skippedRows: day.skippedRows,
                            unitsByProductType: day.unitsByProductType)
        }
    }
}
