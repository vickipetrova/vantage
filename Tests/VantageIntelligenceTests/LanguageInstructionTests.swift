import XCTest
import VantageCore
@testable import VantageIntelligence
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The language line `AppleIntelligenceDrafter.instructions(for:)` adds on top of `ReplyPrompt`'s
/// own instructions — added because "in the same language as the review" alone wasn't reliable
/// enough: German and Japanese reviews came back in English in live evaluation. Detection runs on
/// the review's own text (`languageSample`), never on the instructions themselves.
final class LanguageInstructionTests: XCTestCase {
    private func request(title: String, body: String, rating: Int = 2) -> DraftRequest {
        let review = CustomerReview(id: "r1", appleID: "1", rating: rating, title: title, body: body,
                                    reviewerNickname: "", createdDate: Date(), territory: "",
                                    response: nil)
        return ReplyPrompt.request(for: review, appName: "Vantage")
    }

    func testGermanReviewAddsAGermanInstruction() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("Needs macOS 26") }
        let req = request(title: "Stürzt ab",
                          body: "Die App stürzt jedes Mal ab, wenn ich einen Bericht exportiere. "
                              + "Das passiert bei jedem einzelnen Versuch und ist sehr ärgerlich.")
        XCTAssertTrue(AppleIntelligenceDrafter.instructions(for: req).hasSuffix("Write the reply in German."))
        #else
        throw XCTSkip("Built without FoundationModels")
        #endif
    }

    func testJapaneseReviewAddsAJapaneseInstruction() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("Needs macOS 26") }
        let req = request(title: "とても便利",
                          body: "売上がすぐに確認できて、毎朝使っています。とても助かっています。")
        XCTAssertTrue(AppleIntelligenceDrafter.instructions(for: req).hasSuffix("Write the reply in Japanese."))
        #else
        throw XCTSkip("Built without FoundationModels")
        #endif
    }

    /// Detected on the whole templated prompt, a title-only review read as English: the prompt's own
    /// "Rating", "Title" and "Review" labels outweighed five characters of Japanese.
    func testTitleOnlyJapaneseReviewAddsAJapaneseInstruction() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("Needs macOS 26") }
        let req = request(title: "とても便利", body: "", rating: 5)
        XCTAssertTrue(AppleIntelligenceDrafter.instructions(for: req).hasSuffix("Write the reply in Japanese."))
        #else
        throw XCTSkip("Built without FoundationModels")
        #endif
    }

    func testEnglishReviewLeavesInstructionsUnchanged() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("Needs macOS 26") }
        let req = request(title: "Crashes on export",
                          body: "Every time I export a report to PDF on my MacBook the app quits.")
        XCTAssertEqual(AppleIntelligenceDrafter.instructions(for: req), req.instructions)
        #else
        throw XCTSkip("Built without FoundationModels")
        #endif
    }
}
