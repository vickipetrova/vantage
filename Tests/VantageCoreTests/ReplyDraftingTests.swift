import XCTest
@testable import VantageCore

/// Everything between "Draft was clicked" and "text or a reason", without a model.
final class ReplyDraftingTests: XCTestCase {
    private final class StubDrafter: ReplyDrafter {
        var availability: DraftAvailability = .available
        var outcome: () throws -> String = { "Thanks for the kind words!" }
        private(set) var draftCalls = 0

        func prewarm(_ request: DraftRequest) {}
        func observeAvailability(_ onChange: @escaping () -> Void) {}
        func draft(_ request: DraftRequest) async throws -> String {
            draftCalls += 1
            return try outcome()
        }
    }

    private let request = DraftRequest(instructions: "i", prompt: "p")

    func testSuccessIsCleaned() async {
        let drafter = StubDrafter()
        drafter.outcome = { "Reply: \"Thanks for the kind words!\"" }
        let result = await ReplyDrafting.run(request, with: drafter)
        XCTAssertEqual(result, .success("Thanks for the kind words!"))
    }

    func testCleanupFailuresComeThrough() async {
        let drafter = StubDrafter()
        drafter.outcome = { "Thanks! See https://example.com" }
        let result = await ReplyDrafting.run(request, with: drafter)
        XCTAssertEqual(result, .failure(.rejected))
    }

    func testDrafterErrorsPassThrough() async {
        for error in [DraftError.declined, .unsupportedLanguage, .failed, .unavailable(.preparing)] {
            let drafter = StubDrafter()
            drafter.outcome = { throw error }
            let result = await ReplyDrafting.run(request, with: drafter)
            XCTAssertEqual(result, .failure(error))
        }
    }

    func testUnknownErrorsBecomeFailed() async {
        struct Unexpected: Error {}
        let drafter = StubDrafter()
        drafter.outcome = { throw Unexpected() }
        let result = await ReplyDrafting.run(request, with: drafter)
        XCTAssertEqual(result, .failure(.failed))
    }

    /// Cancelling means the composer closed. There's nobody to tell.
    func testCancellationProducesNothing() async {
        let drafter = StubDrafter()
        drafter.outcome = { throw CancellationError() }
        let result = await ReplyDrafting.run(request, with: drafter)
        XCTAssertNil(result)
    }

    /// Availability can change between opening the composer and clicking Draft. Asking the model
    /// anyway would turn "switched off" into a vague failure.
    func testUnavailableDrafterIsNotAsked() async {
        let drafter = StubDrafter()
        drafter.availability = .turnedOff
        let result = await ReplyDrafting.run(request, with: drafter)
        XCTAssertEqual(result, .failure(.unavailable(.turnedOff)))
        XCTAssertEqual(drafter.draftCalls, 0)
    }
}
