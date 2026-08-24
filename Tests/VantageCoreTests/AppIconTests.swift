import XCTest
@testable import VantageCore

/// The lookup response is third-party JSON that Vantage doesn't control, so every shape it can
/// arrive in has to fail into "no icon" rather than into a crash or a wrong image.
final class AppIconTests: XCTestCase {
    private func json(_ string: String) -> Data { Data(string.utf8) }

    func testPrefersTheHundredPointArtwork() {
        let data = json("""
        {"resultCount":1,"results":[{
          "artworkUrl60":"https://is1-ssl.mzstatic.com/image/60x60bb.jpg",
          "artworkUrl100":"https://is1-ssl.mzstatic.com/image/100x100bb.jpg",
          "artworkUrl512":"https://is1-ssl.mzstatic.com/image/512x512bb.jpg"
        }]}
        """)
        XCTAssertEqual(ITunesLookup.artworkURL(from: data)?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/100x100bb.jpg")
    }

    func testFallsBackThroughTheOtherRenditions() {
        let data = json("""
        {"resultCount":1,"results":[
          {"artworkUrl512":"https://is1-ssl.mzstatic.com/image/512x512bb.jpg"}]}
        """)
        XCTAssertEqual(ITunesLookup.artworkURL(from: data)?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/512x512bb.jpg")
    }

    /// An empty `results` array is the normal answer for an app that isn't on the store — a
    /// TestFlight-only build, or one removed from sale. Not an error.
    func testNoResultsMeansNoIcon() {
        XCTAssertNil(ITunesLookup.artworkURL(from: json(#"{"resultCount":0,"results":[]}"#)))
    }

    func testMalformedJSONMeansNoIcon() {
        XCTAssertNil(ITunesLookup.artworkURL(from: json("not json at all")))
        XCTAssertNil(ITunesLookup.artworkURL(from: Data()))
        XCTAssertNil(ITunesLookup.artworkURL(from: json("[]")))
    }

    func testResultWithoutArtworkMeansNoIcon() {
        XCTAssertNil(ITunesLookup.artworkURL(from: json(#"{"results":[{"trackId":123}]}"#)))
    }

    /// The URL comes from a response body, so it decides where the *next* request goes. A non-HTTPS
    /// one is refused rather than followed — App Transport Security would block it anyway, but not
    /// making the request at all is the better failure.
    func testNonHTTPSArtworkIsRefused() {
        let data = json(#"{"results":[{"artworkUrl100":"http://example.com/icon.png"}]}"#)
        XCTAssertNil(ITunesLookup.artworkURL(from: data))
    }

    func testLookupURLIsScopedToApps() {
        let url = ITunesLookup.lookupURL(appleID: "6478")
        XCTAssertEqual(url?.host, "itunes.apple.com")
        XCTAssertTrue(url?.absoluteString.contains("id=6478") == true)
        // Without entity=software a bare id can match a different kind of store item, which would
        // put an album cover on a sales row.
        XCTAssertTrue(url?.absoluteString.contains("entity=software") == true)
    }

    // MARK: - Cache

    /// The Apple ID reaches this from a parsed TSV, so it is untrusted input that becomes a
    /// filename. A traversal attempt must not write outside the cache directory.
    func testCachePathRejectsAnythingThatIsNotDigits() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-icon-tests-\(UUID().uuidString)")
        let store = AppIconStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(store.save(Data([1, 2, 3]), for: "../../etc/passwd"))
        XCTAssertFalse(store.save(Data([1, 2, 3]), for: ""))
        XCTAssertNil(store.load("../../etc/passwd"))

        // Validated, not sanitized. Stripping non-digits from this would leave "123" — traversal
        // defeated, but now reading and writing another app's icon under its own name.
        XCTAssertFalse(store.save(Data([1, 2, 3]), for: "../../123/passwd"))
        XCTAssertNil(store.load("../../123/passwd"))
    }

    func testRoundTripsThroughTheCache() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-icon-tests-\(UUID().uuidString)")
        let store = AppIconStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(store.save(payload, for: "6478"))
        XCTAssertEqual(store.load("6478"), payload)
        XCTAssertNil(store.load("9999"), "An uncached app must read as absent, not as empty data")
    }
    // MARK: - Ratings

    /// The rating comes out of the same lookup response the icon does, which is why it costs no new
    /// request and no new host.
    func testAListingCarriesTheRatingAlongsideTheArtwork() {
        let payload = json("""
        {"resultCount":1,"results":[{
          "artworkUrl100":"https://is1-ssl.mzstatic.com/image/100x100bb.jpg",
          "averageUserRating":4.7,
          "userRatingCount":128}]}
        """)
        let listing = ITunesLookup.listing(from: payload, appleID: "6478")
        XCTAssertEqual(listing?.appleID, "6478")
        XCTAssertEqual(listing?.averageRating, Decimal(string: "4.7"))
        XCTAssertEqual(listing?.ratingCount, 128)
        XCTAssertEqual(listing?.artworkURL?.absoluteString,
                       "https://is1-ssl.mzstatic.com/image/100x100bb.jpg")
    }

    /// An unrated app has no rating — **not** zero, which would draw as unanimously terrible rather
    /// than as nobody having said anything yet.
    func testAnUnratedAppHasNoRatingRatherThanZero() {
        let payload = json(#"{"results":[{"averageUserRating":0,"userRatingCount":0}]}"#)
        XCTAssertNil(ITunesLookup.listing(from: payload, appleID: "6478")?.averageRating)
    }

    func testAListingWithNoRatingFieldsAtAllStillParses() {
        let payload = json(#"{"results":[{"artworkUrl100":"https://x.mzstatic.com/a.jpg"}]}"#)
        let listing = ITunesLookup.listing(from: payload, appleID: "6478")
        XCTAssertNotNil(listing)
        XCTAssertNil(listing?.averageRating)
        XCTAssertNil(listing?.ratingCount)
    }

    /// Apple sends these as JSON numbers, so they arrive as Double. 4.7 must not become
    /// 4.699999999999999 on the way through.
    func testTheRatingSurvivesTheJSONNumberIntact() {
        let payload = json(#"{"results":[{"averageUserRating":4.7}]}"#)
        let rating = try! XCTUnwrap(ITunesLookup.listing(from: payload, appleID: "1")?.averageRating)
        XCTAssertEqual(Fmt.rating(rating), Fmt.rating(Decimal(string: "4.7")!))
        XCTAssertFalse("\(rating)".hasPrefix("4.69"), "\(rating)")
    }

    /// An app that isn't on the store — TestFlight-only, or removed from sale — has no listing.
    func testAnAppWithNoStoreResultHasNoListing() {
        XCTAssertNil(ITunesLookup.listing(from: json(#"{"resultCount":0,"results":[]}"#),
                                          appleID: "6478"))
        XCTAssertNil(ITunesLookup.listing(from: json("not json"), appleID: "6478"))
    }

    // MARK: - The listing cache

    /// A TTL cache, unlike the icon bytes beside it: an icon is effectively permanent, a rating
    /// moves every day, and a stale one presented as current is a number nobody can act on.
    func testListingsGoStaleAndIconsDoNot() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-listing-tests-\(UUID().uuidString)")
        let store = AppListingStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(store.needsFetch("6478", now: now))

        store.save(AppListing(appleID: "6478", artworkURL: nil,
                              averageRating: Decimal(string: "4.7"), ratingCount: 128,
                              fetchedAt: now))
        XCTAssertFalse(store.needsFetch("6478", now: now.addingTimeInterval(3600)))
        XCTAssertTrue(store.needsFetch("6478",
                                       now: now.addingTimeInterval(AppListingStore.maxAge + 1)))
        // Stale is still readable — a rating from yesterday beats a blank while a request runs.
        XCTAssertEqual(store.load("6478")?.averageRating, Decimal(string: "4.7"))
    }

    func testListingCachePathsAreValidatedNotSanitized() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-listing-tests-\(UUID().uuidString)")
        let store = AppListingStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(store.save(AppListing(appleID: "../../123/x", artworkURL: nil,
                                             averageRating: nil, ratingCount: nil,
                                             fetchedAt: Date())))
        XCTAssertNil(store.load("../../123/x"))
    }

}
