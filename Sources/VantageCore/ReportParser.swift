import Foundation

/// Turns a Summary Sales report into a day's totals.
///
/// The one file in this repo where being subtly wrong is invisible: a broken menu looks broken, but
/// a parsing bug produces a number that looks exactly like a real one. So nothing here throws,
/// nothing crashes, and anything unreadable is counted rather than quietly dropped.
///
/// `docs/REPORT_FORMAT.md` is the reference for every rule below, with sources. Read it before
/// changing anything here.
public enum ReportParser {
    /// Product type identifiers that mean "someone acquired this app for the first time".
    ///
    /// Updates (`7`, `7F`, `7T`, `F7`) and re-downloads (`3`, `3F`) are units but not acquisitions.
    /// In-App Purchases and subscriptions are revenue but not installs. Anything unrecognized falls
    /// into the same bucket as an IAP: it counts toward proceeds, never toward downloads.
    ///
    /// Mac (`F1`, `F1-B`) is in here deliberately — a download counter that ignored Mac apps would
    /// be wrong in the least visible way possible.
    static let firstDownloadTypes: Set<String> = [
        "1", "1-B", "1E", "1EP", "1EU", "1F", "1T", "F1", "F1-B",
    ]

    public static func parse(_ tsv: String, date: ReportDate, fetchedAt: Date) -> DaySales {
        let lines = tsv
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        guard let headerLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else {
            return DaySales(date: date, origin: .observed, downloads: 0,
                            proceeds: [:], apps: [], fetchedAt: fetchedAt)
        }

        let columns = Columns(header: headerLine)
        var rows: [Row] = []
        var skipped = 0

        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let row = columns.row(from: fields) else {
                skipped += 1
                continue
            }
            rows.append(row)
        }

        // Two passes, because an In-App Purchase row names its parent app by SKU and the mapping
        // from SKU to Apple Identifier only exists on the app's own rows — which may come after it.
        var totals = Totals(parents: Self.parentIndex(rows))
        totals.skipped = skipped
        for row in rows { totals.add(row) }
        return totals.day(date: date, fetchedAt: fetchedAt)
    }

    // MARK: - Columns

    /// Header-name → index. Never positional.
    ///
    /// Apple has added columns to this report before, and its own documentation disagrees with its
    /// own reports about what the proceeds column is called — the field reference says "Developer
    /// Proceeds (per unit)" and every real report says "Developer Proceeds". Matching on a
    /// normalized name absorbs both, plus casing and whitespace drift.
    private struct Columns {
        let productType: Int?
        let units: Int?
        let proceeds: Int?
        let currency: Int?
        let title: Int?
        let appleID: Int?
        let sku: Int?
        let parentID: Int?

        init(header: Substring) {
            var indices: [String: Int] = [:]
            for (index, name) in header.split(separator: "\t", omittingEmptySubsequences: false)
                .enumerated() {
                indices[Columns.normalize(name)] = index
            }
            productType = indices["producttypeidentifier"]
            units = indices["units"]
            // The parenthetical is stripped by `normalize`, so both spellings land here.
            proceeds = indices["developerproceeds"]
            currency = indices["currencyofproceeds"]
            title = indices["title"]
            appleID = indices["appleidentifier"]
            sku = indices["sku"]
            parentID = indices["parentidentifier"]
        }

        /// Lowercased, with everything that isn't a letter or digit removed — so "Developer
        /// Proceeds", "developer proceeds" and "Developer Proceeds (per unit)" all collapse to one
        /// key.
        static func normalize(_ name: Substring) -> String {
            var result = ""
            for character in name.lowercased() where character.isLetter || character.isNumber {
                result.append(character)
            }
            // "developerproceedsperunit" → "developerproceeds"
            if result.hasSuffix("perunit") { result.removeLast("perunit".count) }
            return result
        }

        /// A row, or nil if it can't be read — too few fields, an unreadable number, or a report
        /// missing the columns that carry the numbers.
        func row(from fields: [Substring]) -> Row? {
            guard let productType, let units, let proceeds,
                  let value = Self.field(fields, productType),
                  let unitsText = Self.field(fields, units),
                  let proceedsText = Self.field(fields, proceeds),
                  let unitCount = Self.decimal(unitsText),
                  let perUnit = Self.decimal(proceedsText)
            else { return nil }

            return Row(
                productType: value.trimmingCharacters(in: .whitespaces).uppercased(),
                units: unitCount,
                perUnitProceeds: perUnit,
                currency: (currency.flatMap { Self.field(fields, $0) } ?? "")
                    .trimmingCharacters(in: .whitespaces).uppercased(),
                title: (title.flatMap { Self.field(fields, $0) } ?? "")
                    .trimmingCharacters(in: .whitespaces),
                appleID: (appleID.flatMap { Self.field(fields, $0) } ?? "")
                    .trimmingCharacters(in: .whitespaces),
                sku: (sku.flatMap { Self.field(fields, $0) } ?? "")
                    .trimmingCharacters(in: .whitespaces),
                parentID: (parentID.flatMap { Self.field(fields, $0) } ?? "")
                    .trimmingCharacters(in: .whitespaces))
        }

        private static func field(_ fields: [Substring], _ index: Int) -> String? {
            index < fields.count ? String(fields[index]) : nil
        }

        /// POSIX locale, always. Apple writes `0.70`; a machine set to a comma-decimal locale would
        /// otherwise read that as seventy.
        private static func decimal(_ text: String) -> Decimal? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    /// SKU → (Apple Identifier, Title) for every row that is an app rather than an In-App Purchase.
    ///
    /// An IAP row carries its own Apple Identifier — the purchase's, not the app's — and names its
    /// app only through `Parent Identifier`, which holds the app's **SKU**. Without this index the
    /// per-app breakdown lists every in-app purchase as though it were a separate app, and the
    /// app that actually earned the money shows nothing.
    private static func parentIndex(_ rows: [Row]) -> [String: (appleID: String, title: String)] {
        var index: [String: (appleID: String, title: String)] = [:]
        for row in rows where row.parentID.isEmpty && !row.sku.isEmpty && !row.appleID.isEmpty {
            // First writer wins: an app's own rows all agree, and a later IAP row can't overwrite.
            if index[row.sku] == nil { index[row.sku] = (row.appleID, row.title) }
        }
        return index
    }

    private struct Row {
        let productType: String
        let units: Decimal
        let perUnitProceeds: Decimal
        let currency: String
        let title: String
        let appleID: String
        let sku: String
        /// The SKU of the app this In-App Purchase belongs to. Empty for app rows.
        let parentID: String

        /// Refund rows carry negative units and positive per-unit proceeds, so this subtracts on
        /// its own. Never take an absolute value of either half.
        var proceeds: Decimal { units * perUnitProceeds }

        var isDownload: Bool { firstDownloadTypes.contains(productType) }
    }

    // MARK: - Accumulation

    private struct Totals {
        let parents: [String: (appleID: String, title: String)]
        var downloads: Decimal = 0
        var proceeds: [String: Decimal] = [:]
        var apps: [String: (title: String, downloads: Decimal, proceeds: [String: Decimal])] = [:]
        var unitsByType: [String: Decimal] = [:]
        var skipped = 0

        /// Which app a row's money belongs to.
        ///
        /// An In-App Purchase belongs to the app that sold it, not to itself — otherwise the
        /// breakdown lists purchase products where apps should be, and the app that earned the
        /// money reads as zero. When the parent isn't in the report at all (it earned nothing that
        /// day), the purchases still group together under the parent's SKU rather than scattering.
        private func owner(of row: Row) -> (key: String, title: String)? {
            if !row.parentID.isEmpty {
                if let parent = parents[row.parentID] {
                    return (parent.appleID, parent.title)
                }
                return (row.parentID, row.parentID)
            }
            let key = row.appleID.isEmpty ? row.title : row.appleID
            return key.isEmpty ? nil : (key, row.title)
        }

        mutating func add(_ row: Row) {
            let amount = row.proceeds

            if !row.productType.isEmpty { unitsByType[row.productType, default: 0] += row.units }
            if row.isDownload { downloads += row.units }

            // A blank Currency of Proceeds is normal, not damage: free-app rows carry units and no
            // currency at all. Bucketing those under "" would put a nameless currency in the menu.
            // Money with no currency attached would be a different problem, so it's counted.
            if amount != 0 {
                guard !row.currency.isEmpty else {
                    skipped += 1
                    return
                }
                proceeds[row.currency, default: 0] += amount
            }

            guard let owner = owner(of: row) else { return }
            var app = apps[owner.key] ?? (title: owner.title, downloads: 0, proceeds: [:])
            // Prefer the title from a download row: In-App Purchase rows put the product ID in the
            // Title column, which is not the app's name.
            if row.isDownload, !row.title.isEmpty { app.title = row.title }
            if row.isDownload { app.downloads += row.units }
            if amount != 0, !row.currency.isEmpty {
                app.proceeds[row.currency, default: 0] += amount
            }
            apps[owner.key] = app
        }

        func day(date: ReportDate, fetchedAt: Date) -> DaySales {
            let summaries = apps
                .map { AppSales(appleID: $0.key, title: $0.value.title,
                                downloads: $0.value.downloads, proceeds: $0.value.proceeds) }
                // Sorted by Apple ID rather than by money, because sorting by proceeds needs a
                // display currency and a rate table. The menu sorts; the parser just groups.
                .sorted { $0.appleID < $1.appleID }

            return DaySales(date: date, origin: .observed, downloads: downloads,
                            proceeds: proceeds, apps: summaries,
                            fetchedAt: fetchedAt, skippedRows: skipped,
                            unitsByProductType: unitsByType)
        }
    }
}
