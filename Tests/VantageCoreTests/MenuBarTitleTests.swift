import XCTest
@testable import VantageCore

/// What the menu bar shows, per style. The menu bar is the one surface that's always on screen, so
/// the rule that matters most is that choosing the icon never hides a problem.
final class MenuBarTitleTests: XCTestCase {
    private let figures = "$1,204 · 89↓"

    // MARK: - Numbers: exactly what it was before styles existed

    func testNumbersIsUnchanged() {
        XCTAssertEqual(MenuBarTitle.make(.loading, style: .numbers),
                       MenuBarTitle(showsIcon: false, text: "…", isDimmed: false))
        XCTAssertEqual(MenuBarTitle.make(.failed, style: .numbers).text, "!")
        XCTAssertEqual(MenuBarTitle.make(.noCredentials, style: .numbers).text, "–")
        XCTAssertEqual(MenuBarTitle.make(.figures(figures, behind: false), style: .numbers).text,
                       figures)
        XCTAssertEqual(MenuBarTitle.make(.figures(figures, behind: true), style: .numbers).text,
                       "⚠︎ " + figures)
    }

    // MARK: - Icon

    func testIconAloneWhenAllIsWell() {
        XCTAssertEqual(MenuBarTitle.make(.figures(figures, behind: false), style: .icon),
                       MenuBarTitle(showsIcon: true, text: "", isDimmed: false))
    }

    /// Loading is the one state with nothing to say, so the icon dims instead of adding text.
    func testIconDimsWhileLoading() {
        XCTAssertEqual(MenuBarTitle.make(.loading, style: .icon),
                       MenuBarTitle(showsIcon: true, text: "", isDimmed: true))
    }

    /// A broken key or stale figures must stay visible with the numbers turned off.
    func testIconStillSaysWhenSomethingIsWrong() {
        XCTAssertEqual(MenuBarTitle.make(.failed, style: .icon).text, "!")
        XCTAssertEqual(MenuBarTitle.make(.noCredentials, style: .icon).text, "!")
        XCTAssertEqual(MenuBarTitle.make(.figures(figures, behind: true), style: .icon).text, "⚠︎")
        XCTAssertTrue(MenuBarTitle.make(.noCredentials, style: .icon).isDimmed,
                      "and nothing set up yet reads as inactive, not as working")
    }

    // MARK: - Icon and numbers

    func testIconAndNumbers() {
        XCTAssertEqual(MenuBarTitle.make(.figures(figures, behind: false), style: .iconAndNumbers),
                       MenuBarTitle(showsIcon: true, text: figures, isDimmed: false))
        XCTAssertEqual(MenuBarTitle.make(.figures(figures, behind: true), style: .iconAndNumbers)
            .text, "⚠︎ " + figures)
        XCTAssertEqual(MenuBarTitle.make(.loading, style: .iconAndNumbers),
                       MenuBarTitle(showsIcon: true, text: "", isDimmed: true))
        XCTAssertEqual(MenuBarTitle.make(.failed, style: .iconAndNumbers).text, "!")
    }

    // MARK: - Storage

    func testStylesRoundTripAndDefaultToNumbers() {
        for style in MenuBarStyle.allCases {
            XCTAssertEqual(MenuBarStyle(rawValue: style.rawValue), style)
            XCTAssertFalse(style.label.isEmpty)
        }
        XCTAssertEqual(Prefs.menuBarStyle(from: nil), .numbers)
        XCTAssertEqual(Prefs.menuBarStyle(from: "something-from-a-future-build"), .numbers)
        XCTAssertEqual(Prefs.menuBarStyle(from: "icon"), .icon)
    }
}
