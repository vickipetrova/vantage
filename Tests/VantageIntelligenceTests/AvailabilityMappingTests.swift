import XCTest
import VantageCore
@testable import VantageIntelligence
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's reasons → what the composer shows. Runs anywhere the SDK has the framework, model or not.
final class AvailabilityMappingTests: XCTestCase {
    func testEachUnavailableReasonMapsToWhatTheUserCanDo() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("Needs macOS 26") }
        XCTAssertEqual(AppleIntelligenceDrafter.map(.available), .available)
        XCTAssertEqual(AppleIntelligenceDrafter.map(.unavailable(.appleIntelligenceNotEnabled)), .turnedOff)
        XCTAssertEqual(AppleIntelligenceDrafter.map(.unavailable(.modelNotReady)), .preparing)
        XCTAssertEqual(AppleIntelligenceDrafter.map(.unavailable(.deviceNotEligible)), .hidden)
        #else
        throw XCTSkip("Built without FoundationModels")
        #endif
    }

    func testGenerationErrorsMapToDraftErrors() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("Needs macOS 26") }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
        typealias E = LanguageModelSession.GenerationError
        XCTAssertEqual(AppleIntelligenceDrafter.map(E.guardrailViolation(context)), .declined)
        XCTAssertEqual(AppleIntelligenceDrafter.map(E.unsupportedLanguageOrLocale(context)), .unsupportedLanguage)
        XCTAssertEqual(AppleIntelligenceDrafter.map(E.assetsUnavailable(context)), .unavailable(.preparing))
        XCTAssertEqual(AppleIntelligenceDrafter.map(E.rateLimited(context)), .failed)
        XCTAssertEqual(AppleIntelligenceDrafter.map(E.exceededContextWindowSize(context)), .failed)
        XCTAssertEqual(AppleIntelligenceDrafter.map(E.concurrentRequests(context)), .failed)
        #else
        throw XCTSkip("Built without FoundationModels")
        #endif
    }
}
