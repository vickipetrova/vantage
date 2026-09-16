import XCTest
@testable import VantageCore

/// Apple's JSON:API payloads, decoded.
///
/// Every reviewer nickname and body in this file is invented. Real ones are other people's data and
/// this repository is public — see `docs/REVIEWS_API.md`.
final class ReviewDecodingTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    private let fullPage = """
    {
      "data": [
        {
          "type": "customerReviews",
          "id": "review-1",
          "attributes": {
            "rating": 5,
            "title": "Does exactly what it says",
            "body": "Menu bar app that stays out of the way.",
            "reviewerNickname": "Testerly",
            "createdDate": "2026-08-18T09:12:44.000+0000",
            "territory": "GBR"
          },
          "relationships": {
            "response": { "data": { "type": "customerReviewResponses", "id": "response-1" } }
          }
        },
        {
          "type": "customerReviews",
          "id": "review-2",
          "attributes": {
            "rating": 2,
            "title": "Needs onboarding",
            "body": "Took me a while to find the Issuer ID.",
            "reviewerNickname": "Anonymous Tester",
            "createdDate": "2026-08-17T22:01:00Z",
            "territory": "USA"
          }
        }
      ],
      "included": [
        {
          "type": "customerReviewResponses",
          "id": "response-1",
          "attributes": {
            "responseBody": "Thanks — glad it's useful.",
            "state": "PUBLISHED",
            "lastModifiedDate": "2026-08-19T10:00:00.000+0000"
          }
        }
      ],
      "links": {
        "self": "https://api.appstoreconnect.apple.com/v1/apps/1/customerReviews",
        "next": "https://api.appstoreconnect.apple.com/v1/apps/1/customerReviews?cursor=abc"
      }
    }
    """

    // MARK: - The happy path

    func testDecodesReviewsInOrder() {
        let page = ReviewDecoder.page(from: data(fullPage), appleID: "6478")
        XCTAssertEqual(page?.reviews.count, 2)
        XCTAssertEqual(page?.reviews.first?.id, "review-1")
        XCTAssertEqual(page?.reviews.first?.rating, 5)
        XCTAssertEqual(page?.reviews.first?.title, "Does exactly what it says")
        XCTAssertEqual(page?.reviews.first?.territory, "GBR")
        XCTAssertEqual(page?.skipped, 0)
    }

    /// The app isn't in the payload — reviews are fetched per app, so it comes from the request.
    func testStampsTheAppleIDFromTheRequest() {
        let page = ReviewDecoder.page(from: data(fullPage), appleID: "6478")
        XCTAssertTrue(page?.reviews.allSatisfy { $0.appleID == "6478" } == true)
    }

    /// The response is sideloaded in `included` and linked by relationship, not embedded.
    func testAttachesTheSideloadedResponseToTheRightReview() {
        let page = ReviewDecoder.page(from: data(fullPage), appleID: "6478")
        XCTAssertEqual(page?.reviews.first?.response?.body, "Thanks — glad it's useful.")
        XCTAssertEqual(page?.reviews.first?.response?.state, .published)
        XCTAssertNil(page?.reviews.last?.response, "A review with no reply has no relationship")
    }

    /// Apple sends fractional seconds on some fields and not others, in the same payload.
    func testDecodesBothISO8601FormsApplesends() {
        let page = ReviewDecoder.page(from: data(fullPage), appleID: "6478")
        XCTAssertNotNil(page?.reviews.first?.createdDate)
        XCTAssertNotNil(page?.reviews.last?.createdDate)
        XCTAssertNotEqual(page?.reviews.first?.createdDate, page?.reviews.last?.createdDate)
    }

    // MARK: - Pagination

    func testFollowsNextOnApplesOwnHost() {
        let page = ReviewDecoder.page(from: data(fullPage), appleID: "6478")
        XCTAssertEqual(page?.next?.host, "api.appstoreconnect.apple.com")
    }

    /// `links.next` is a response body deciding where the next *authenticated* request goes. A
    /// next-page URL pointing anywhere else would carry the bearer token off Apple's host.
    func testRefusesANextLinkOnAnotherHost() {
        let hostile = fullPage.replacingOccurrences(
            of: "https://api.appstoreconnect.apple.com/v1/apps/1/customerReviews?cursor=abc",
            with: "https://evil.example.com/collect?token=1")
        XCTAssertNil(ReviewDecoder.page(from: data(hostile), appleID: "6478")?.next)
    }

    func testRefusesANonHTTPSNextLink() {
        let plain = fullPage.replacingOccurrences(
            of: "https://api.appstoreconnect.apple.com/v1/apps/1/customerReviews?cursor=abc",
            with: "http://api.appstoreconnect.apple.com/v1/apps/1/customerReviews?cursor=abc")
        XCTAssertNil(ReviewDecoder.page(from: data(plain), appleID: "6478")?.next)
    }

    func testNoNextLinkOnTheLastPage() {
        let last = #"{"data":[],"links":{"self":"https://api.appstoreconnect.apple.com/x"}}"#
        XCTAssertNil(ReviewDecoder.page(from: data(last), appleID: "6478")?.next)
    }

    // MARK: - Response routing

    /// The single-response fixture above can't tell relationship-ID routing from "take the first
    /// one" — mutation testing confirmed `responses.values.first` passed the whole suite. Two of
    /// each is what makes a reply appearing under the wrong customer's review a test failure.
    func testEachReplyLandsOnTheReviewItAnswers() {
        let twoOfEach = """
        {"data":[
          {"type":"customerReviews","id":"review-a","attributes":
            {"rating":5,"createdDate":"2026-08-18T09:00:00Z"},
           "relationships":{"response":{"data":
            {"type":"customerReviewResponses","id":"response-a"}}}},
          {"type":"customerReviews","id":"review-b","attributes":
            {"rating":1,"createdDate":"2026-08-17T09:00:00Z"},
           "relationships":{"response":{"data":
            {"type":"customerReviewResponses","id":"response-b"}}}}
        ],
        "included":[
          {"type":"customerReviewResponses","id":"response-b","attributes":
            {"responseBody":"Reply to B","state":"PUBLISHED",
             "lastModifiedDate":"2026-08-19T10:00:00Z"}},
          {"type":"customerReviewResponses","id":"response-a","attributes":
            {"responseBody":"Reply to A","state":"PUBLISHED",
             "lastModifiedDate":"2026-08-19T10:00:00Z"}}
        ]}
        """
        let reviews = ReviewDecoder.page(from: data(twoOfEach), appleID: "1")?.reviews
        XCTAssertEqual(reviews?.count, 2)
        // `included` is deliberately in the opposite order to `data`.
        XCTAssertEqual(reviews?.first?.response?.body, "Reply to A")
        XCTAssertEqual(reviews?.last?.response?.body, "Reply to B")
    }

    /// One review answered, one not, in the same page.
    func testAnUnansweredReviewGetsNoReplyEvenWhenOthersHaveOne() {
        let mixed = """
        {"data":[
          {"type":"customerReviews","id":"answered","attributes":
            {"rating":5,"createdDate":"2026-08-18T09:00:00Z"},
           "relationships":{"response":{"data":
            {"type":"customerReviewResponses","id":"r1"}}}},
          {"type":"customerReviews","id":"unanswered","attributes":
            {"rating":3,"createdDate":"2026-08-17T09:00:00Z"}}
        ],
        "included":[
          {"type":"customerReviewResponses","id":"r1","attributes":
            {"responseBody":"Thanks","state":"PUBLISHED",
             "lastModifiedDate":"2026-08-19T10:00:00Z"}}
        ]}
        """
        let reviews = ReviewDecoder.page(from: data(mixed), appleID: "1")?.reviews
        XCTAssertNotNil(reviews?.first?.response)
        XCTAssertNil(reviews?.last?.response)
    }

    /// A row of the wrong resource type means the payload isn't what we think it is.
    func testARowOfTheWrongTypeIsSkipped() {
        let wrong = """
        {"data":[{"type":"apps","id":"x","attributes":
          {"rating":5,"createdDate":"2026-08-18T09:00:00Z"}}]}
        """
        let page = ReviewDecoder.page(from: data(wrong), appleID: "1")
        XCTAssertEqual(page?.reviews.count, 0)
        XCTAssertEqual(page?.skipped, 1)
    }

    /// An `included` entry that isn't a response must not be adopted as one.
    func testIncludedEntriesOfOtherTypesAreIgnored() {
        let noisy = """
        {"data":[{"type":"customerReviews","id":"a","attributes":
          {"rating":5,"createdDate":"2026-08-18T09:00:00Z"},
          "relationships":{"response":{"data":
            {"type":"customerReviewResponses","id":"t1"}}}}],
         "included":[{"type":"territories","id":"t1","attributes":{"currency":"GBP"}}]}
        """
        XCTAssertNil(ReviewDecoder.page(from: data(noisy), appleID: "1")?.reviews.first?.response)
    }

    /// Exact host match, not a suffix — `api.appstoreconnect.apple.com.evil.test` must not pass.
    func testTheNextLinkHostIsMatchedExactly() {
        let lookalike = fullPage.replacingOccurrences(
            of: "https://api.appstoreconnect.apple.com/v1/apps/1/customerReviews?cursor=abc",
            with: "https://api.appstoreconnect.apple.com.evil.test/v1/apps/1/customerReviews")
        XCTAssertNil(ReviewDecoder.page(from: data(lookalike), appleID: "1")?.next)
    }

    // MARK: - Degrading

    /// Same bargain the TSV parser makes: a malformed row costs one row, not the fetch.
    func testAMalformedRowIsSkippedAndCounted() {
        let mixed = """
        {"data":[
          {"type":"customerReviews","id":"ok","attributes":
            {"rating":4,"createdDate":"2026-08-18T09:12:44Z"}},
          {"type":"customerReviews","id":"no-rating","attributes":
            {"createdDate":"2026-08-18T09:12:44Z"}},
          {"type":"customerReviews","attributes":
            {"rating":4,"createdDate":"2026-08-18T09:12:44Z"}}
        ]}
        """
        let page = ReviewDecoder.page(from: data(mixed), appleID: "1")
        XCTAssertEqual(page?.reviews.count, 1)
        XCTAssertEqual(page?.skipped, 2)
    }

    /// Apple documents 1…5 and nothing else. A row of zero stars would be a confident lie about
    /// what a customer said.
    func testARatingOutsideOneToFiveIsRejected() {
        for rating in ["0", "6", "-1"] {
            let row = """
            {"data":[{"type":"customerReviews","id":"x","attributes":
              {"rating":\(rating),"createdDate":"2026-08-18T09:12:44Z"}}]}
            """
            XCTAssertEqual(ReviewDecoder.page(from: data(row), appleID: "1")?.reviews.count, 0,
                           "rating \(rating) must not decode")
        }
    }

    /// A review Apple sends with no body is still a review worth showing — plenty are title-only.
    func testMissingOptionalTextFieldsBecomeEmptyNotSkipped() {
        let sparse = """
        {"data":[{"type":"customerReviews","id":"x","attributes":
          {"rating":3,"createdDate":"2026-08-18T09:12:44Z"}}]}
        """
        let review = ReviewDecoder.page(from: data(sparse), appleID: "1")?.reviews.first
        XCTAssertEqual(review?.title, "")
        XCTAssertEqual(review?.body, "")
        XCTAssertEqual(review?.reviewerNickname, "")
        XCTAssertEqual(review?.territory, "")
    }

    func testMalformedJSONYieldsNoPageRatherThanAnEmptyOne() {
        XCTAssertNil(ReviewDecoder.page(from: data("not json"), appleID: "1"))
        XCTAssertNil(ReviewDecoder.page(from: Data(), appleID: "1"))
        XCTAssertNil(ReviewDecoder.page(from: data("{}"), appleID: "1"),
                     "No data array means the payload isn't what we think it is")
    }

    // MARK: - Response state

    /// `PENDING_PUBLISH` is the normal state right after replying — Apple says responses don't
    /// appear instantly. Treating it as a failure would report every success as an error.
    func testPendingPublishDecodes() {
        let entry: [String: Any] = ["id": "r", "attributes": [
            "responseBody": "Thanks!", "state": "PENDING_PUBLISH",
            "lastModifiedDate": "2026-08-19T10:00:00Z"]]
        XCTAssertEqual(ReviewDecoder.response(from: entry)?.state, .pendingPublish)
    }

    /// If Apple adds a third state, claiming a reply is live when it isn't is the worse mistake.
    func testAnUnknownStateIsTreatedAsNotYetPublished() {
        let entry: [String: Any] = ["id": "r", "attributes": [
            "responseBody": "Thanks!", "state": "SOMETHING_NEW",
            "lastModifiedDate": "2026-08-19T10:00:00Z"]]
        XCTAssertEqual(ReviewDecoder.response(from: entry)?.state, .pendingPublish)
    }

    // MARK: - The write path's response

    /// A successful POST returns a single resource under `data`, not the array-plus-`included`
    /// shape a listing returns. Decoding it wrong would report a published reply as a failure.
    func testDecodesTheResponseToASuccessfulPost() {
        let created = """
        {"data":{"type":"customerReviewResponses","id":"resp-9","attributes":{
          "responseBody":"Thanks — fixed in 1.2.",
          "state":"PENDING_PUBLISH",
          "lastModifiedDate":"2026-08-20T11:30:00.000+0000"}}}
        """
        let response = ReviewDecoder.singleResponse(from: data(created))
        XCTAssertEqual(response?.id, "resp-9")
        XCTAssertEqual(response?.body, "Thanks — fixed in 1.2.")
        XCTAssertEqual(response?.state, .pendingPublish)
    }

    /// Apple returning the wrong resource type means the payload isn't what we think it is.
    func testRefusesAPostResponseOfTheWrongType() {
        let wrong = #"{"data":{"type":"customerReviews","id":"x","attributes":{}}}"#
        XCTAssertNil(ReviewDecoder.singleResponse(from: data(wrong)))
    }

    func testMalformedPostResponseDecodesToNothing() {
        XCTAssertNil(ReviewDecoder.singleResponse(from: data("not json")))
        XCTAssertNil(ReviewDecoder.singleResponse(from: data("{}")))
    }

    // MARK: - Request building


    func testFirstPageURLAsksForWhatThePanelNeeds() {
        let url = ASCReviewsClient.firstPageURL(appleID: "6478", limit: 50)
        let string = try! XCTUnwrap(url?.absoluteString)
        XCTAssertTrue(string.hasPrefix(
            "https://api.appstoreconnect.apple.com/v1/apps/6478/customerReviews?"), string)
        XCTAssertTrue(string.contains("sort=-createdDate"), "Newest first")
        XCTAssertTrue(string.contains("include=response"), "Sideload replies, don't refetch them")
        XCTAssertTrue(string.contains("limit=50"))
    }

    func testPageLimitIsCappedAtApplesMaximum() {
        let url = ASCReviewsClient.firstPageURL(appleID: "6478", limit: 5000)
        XCTAssertTrue(url?.absoluteString.contains("limit=200") == true, "\(url as Any)")
    }

    /// The Apple ID arrives from a parsed TSV and becomes part of a URL path.
    func testNonNumericAppleIDIsRefused() {
        XCTAssertNil(ASCReviewsClient.firstPageURL(appleID: "../../v1/users", limit: 10))
        XCTAssertNil(ASCReviewsClient.firstPageURL(appleID: "", limit: 10))
    }
}
