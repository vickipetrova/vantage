import XCTest
@testable import VantageCore

/// Metrics decide what the `↓` in the menu bar means, so the families have to partition Apple's
/// codes cleanly and the arithmetic has to reconcile against the report.
final class MetricTests: XCTestCase {
    /// The real 2026-07-13 shape that started this: 107 installs, 3 re-downloads, 1 in-app
    /// purchase, 2 subscription units — 113 units, and three defensible "download" figures.
    private let day = DaySales(
        date: ReportDate(year: 2026, month: 7, day: 13), origin: .observed, downloads: 107,
        proceeds: ["EUR": Decimal(string: "0.58")!], apps: [], fetchedAt: Date(),
        unitsByProductType: ["1": 107, "3": 3, "IA1": 1, "IAY": 2])

    func testInstallsMatchAppleAppAndBundleUnits() {
        XCTAssertEqual(Metric.installs.units(in: day), 107)
    }

    func testInAppPurchasesExcludeSubscriptions() {
        XCTAssertEqual(Metric.inAppPurchases.units(in: day), 1)
        XCTAssertEqual(Metric.subscriptions.units(in: day), 2)
    }

    func testRedownloadsAreTheirOwnMetric() {
        XCTAssertEqual(Metric.redownloads.units(in: day), 3)
        XCTAssertEqual(Metric.updates.units(in: day), 0)
    }

    /// The dashboard figure that disagreed with ours: installs plus in-app purchases.
    func testInstallsPlusInAppPurchasesReproducesTheDashboardFigure() {
        XCTAssertEqual(Metric.units(in: day, metrics: [.installs, .inAppPurchases]), 108)
    }

    func testEveryMetricTogetherIsEveryUnitInTheReport() {
        XCTAssertEqual(Metric.units(in: day, metrics: Set(Metric.allCases)), 113)
    }

    func testNoMetricsCountsNothing() {
        XCTAssertEqual(Metric.units(in: day, metrics: []), 0)
    }

    // MARK: - Families

    /// A code must belong to exactly one metric, or a total that enables two would double-count it.
    func testFamiliesDontOverlap() {
        for a in Metric.allCases {
            for b in Metric.allCases where a != b {
                XCTAssertTrue(a.productTypes.isDisjoint(with: b.productTypes),
                              "\(a) and \(b) share codes")
            }
        }
    }

    /// Every code in Apple's published table has a home, so nothing documented lands in "other".
    func testEveryDocumentedCodeIsClaimed() {
        let documented = ["1", "1-B", "F1-B", "1E", "1EP", "1EU", "1F", "1T", "3", "3F",
                          "7", "7F", "7T", "F1", "F7", "FI1", "IA1", "IA1-M", "IA9", "IA9-M",
                          "IAY", "IAY-M"]
        for code in documented {
            XCTAssertFalse(Metric.other.contains(code), "\(code) fell into .other")
        }
        // IA3 is a restored purchase, which Apple's own metric definition excludes from In-App
        // Purchases — so it belongs in .other rather than inflating a revenue count.
        XCTAssertTrue(Metric.other.contains("IA3"))
    }

    /// The point of the bucket: Apple's own sample report uses 1AY, which isn't in Apple's table.
    func testUnrecognizedCodesLandInOther() {
        let odd = DaySales(date: ReportDate(year: 2026, month: 8, day: 1), origin: .observed,
                           downloads: 0, proceeds: [:], apps: [], fetchedAt: Date(),
                           unitsByProductType: ["1AY": 4, "ZZ9": 1, "1F": 10])
        XCTAssertEqual(Metric.other.units(in: odd), 5)
        XCTAssertEqual(Metric.installs.units(in: odd), 10)
        XCTAssertEqual(Metric.units(in: odd, metrics: Set(Metric.allCases)), 15)
    }

    func testCodesAreMatchedCaseAndWhitespaceInsensitively() {
        XCTAssertTrue(Metric.installs.contains(" 1f "))
        XCTAssertTrue(Metric.subscriptions.contains("iay-m"))
    }

    func testInstallsAgreeWithTheParsersOwnDownloadFigure() {
        XCTAssertEqual(Metric.installs.units(in: day), day.downloads)
    }

    // MARK: - Across days

    func testUnitsSumAcrossDays() {
        let second = DaySales(date: ReportDate(year: 2026, month: 7, day: 14), origin: .observed,
                              downloads: 50, proceeds: [:], apps: [], fetchedAt: Date(),
                              unitsByProductType: ["1": 50, "IA1": 5])
        XCTAssertEqual(Metric.units(in: [day, second], metrics: [.installs]), 157)
        XCTAssertEqual(Metric.units(in: [day, second], metrics: [.installs, .inAppPurchases]), 163)
    }

    func testDefaultIsInstallsOnly() {
        XCTAssertEqual(Metric.defaultEnabled, [.installs])
    }

    func testDisplayOrderCoversEveryMetricExactlyOnce() {
        XCTAssertEqual(Set(Metric.displayOrder), Set(Metric.allCases))
        XCTAssertEqual(Metric.displayOrder.count, Metric.allCases.count)
    }
}
