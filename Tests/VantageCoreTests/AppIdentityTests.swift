import XCTest
@testable import VantageCore

/// Folding SKU-keyed phantom apps back into the apps they belong to.
///
/// Found in the wild: a row called `20250101_example_app` with no icon, sitting beside the real
/// "ExampleApp" it was part of. Names below are invented but the shape is the real one.
final class AppIdentityTests: XCTestCase {
    private func date(_ day: Int) -> ReportDate { ReportDate(year: 2026, month: 8, day: day) }

    private func app(_ appleID: String, _ title: String, sku: String = "",
                     units: Decimal = 1, usd: Decimal = 10) -> AppSales {
        AppSales(appleID: appleID, title: title, downloads: units, proceeds: ["USD": usd],
                 unitsByProductType: ["1": units], sku: sku)
    }

    private func day(_ d: Int, _ apps: [AppSales]) -> DaySales {
        DaySales(date: date(d), origin: .observed, downloads: 0, proceeds: [:], apps: apps,
                 fetchedAt: Date())
    }

    // MARK: - The real case

    /// A day where the app sold nothing and only its purchases earned produces a phantom keyed by
    /// SKU. A day where it did sell supplies the mapping, and the phantom folds in.
    func testAPhantomKeyedBySKUMergesIntoItsApp() {
        let days = [
            // Yesterday: only in-app purchases, grouped under the app's SKU.
            day(19, [app("example_sku", "example_sku", units: 0, usd: 30)]),
            // The day before: the app itself sold, so this report carries the SKU mapping.
            day(18, [app("1000000001", "ExampleApp", sku: "example_sku", units: 4, usd: 12)]),
        ]

        let resolved = AppIdentity.resolve(days)
        let yesterday = resolved.first { $0.date == date(19) }

        XCTAssertEqual(yesterday?.apps.count, 1)
        XCTAssertEqual(yesterday?.apps.first?.appleID, "1000000001")
        XCTAssertEqual(yesterday?.apps.first?.title, "ExampleApp",
                       "and it stops being labelled with its own SKU")
        XCTAssertEqual(yesterday?.apps.first?.proceeds["USD"], 30, "the money is unchanged")
    }

    /// When a day has both — some rows resolved, some not — both hold real money and must be added.
    func testAPhantomAndTheRealAppOnTheSameDayAreSummedNotReplaced() {
        let days = [day(19, [
            app("1000000001", "ExampleApp", sku: "example_sku", units: 4, usd: 12),
            app("example_sku", "example_sku", units: 0, usd: 30),
        ])]

        let apps = AppIdentity.resolve(days).first?.apps
        XCTAssertEqual(apps?.count, 1)
        XCTAssertEqual(apps?.first?.proceeds["USD"], 42)
        XCTAssertEqual(apps?.first?.downloads, 4)
        XCTAssertEqual(apps?.first?.unitsByProductType["1"], 4)
        XCTAssertEqual(apps?.first?.title, "ExampleApp")
    }

    // MARK: - Leaving things alone

    /// Without a mapping anywhere in the window there is nothing to resolve, and guessing would be
    /// worse than the phantom.
    func testAPhantomWithNoMappingAnywhereIsLeftAsItIs() {
        let days = [day(19, [app("example_sku", "example_sku", units: 0, usd: 30)])]
        let apps = AppIdentity.resolve(days).first?.apps
        XCTAssertEqual(apps?.count, 1)
        XCTAssertEqual(apps?.first?.appleID, "example_sku")
    }

    func testOrdinaryDaysArePassedThroughUnchanged() {
        let days = [day(19, [app("1000000001", "ExampleApp", sku: "example_sku"),
                             app("1000000002", "OtherApp", sku: "other_sku")])]
        XCTAssertEqual(AppIdentity.resolve(days), days)
    }

    /// A cache written before `AppSales` carried SKUs has none. Nothing should change, and nothing
    /// should crash — those days are never refetched, so this is the normal state for a while.
    func testDaysWithNoSKUsAtAllAreUntouched() {
        let days = [day(19, [app("1000000001", "ExampleApp"), app("example_sku", "example_sku")])]
        XCTAssertEqual(AppIdentity.resolve(days), days)
    }

    // MARK: - The index

    func testTheIndexPrefersTheMostRecentTitle() {
        let days = [day(19, [app("1000000001", "ExampleApp Pro", sku: "example_sku")]),
                    day(18, [app("1000000001", "ExampleApp", sku: "example_sku")])]
        XCTAssertEqual(AppIdentity.skuIndex(days)["example_sku"]?.title, "ExampleApp Pro")
    }

    /// A phantom can't teach anything — its own key is the SKU, so trusting it would map a SKU to
    /// itself and cement the bug.
    func testAPhantomIsNotTreatedAsASourceOfTruth() {
        let days = [day(19, [app("example_sku", "example_sku", sku: "example_sku")])]
        XCTAssertTrue(AppIdentity.skuIndex(days).isEmpty)
    }

    /// Every other figure on the day belongs to the report, not to any app, and must survive.
    func testDayLevelTotalsAreNotDisturbed() {
        let original = DaySales(
            date: date(19), origin: .observed, downloads: 7, proceeds: ["USD": 99],
            apps: [app("1000000001", "ExampleApp", sku: "example_sku"),
                   app("example_sku", "example_sku")],
            fetchedAt: Date(), skippedRows: 3, unitsByProductType: ["1": 7])

        let resolved = try! XCTUnwrap(AppIdentity.resolve([original]).first)
        XCTAssertEqual(resolved.downloads, 7)
        XCTAssertEqual(resolved.proceeds, ["USD": 99])
        XCTAssertEqual(resolved.skippedRows, 3)
        XCTAssertEqual(resolved.unitsByProductType, ["1": 7])
        XCTAssertEqual(resolved.origin, .observed)
    }
}
