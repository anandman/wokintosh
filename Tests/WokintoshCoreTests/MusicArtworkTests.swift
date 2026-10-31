import XCTest
@testable import WokintoshCore

final class MusicArtworkTests: XCTestCase {
    private let track = MusicArtworkTrack(title: "Night Train (Extended Mix)", artist: "Sample Artist", album: "Night & Day", duration: 321.5)
    private let cover = "https://is1-ssl.mzstatic.com/image/thumb/example/100x100bb.jpg"

    private func result(title: String = "Night Train (Extended Mix)", artist: String = "Sample Artist", album: String = "Night & Day", duration: Double = 321500, collection: Int = 123, url: String? = nil) -> [String: Any] {
        ["wrapperType":"track", "kind":"song", "trackName":title, "artistName":artist,
         "collectionName":album, "trackTimeMillis":duration, "collectionId":collection, "artworkUrl100":url ?? cover]
    }
    private func response(_ results: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["resultCount":results.count, "results":results])
    }

    func testSearchIncludesFullIdentityAndEncodesQuerySafely() throws {
        let url = try XCTUnwrap(MusicArtworkCatalog.searchURL(for: track))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "itunes.apple.com")
        XCTAssertEqual(parts.path, "/search")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["term"], "Sample Artist Night Train (Extended Mix) Night & Day")
        XCTAssertEqual(query["entity"], "song")
        XCTAssertEqual(query["media"], "music")
        XCTAssertEqual(query["country"], "US")
        XCTAssertEqual(query["limit"], "100")
        XCTAssertNil(MusicArtworkCatalog.searchURL(for: .init(title: "Song", artist: "Artist", album: "", duration: 20)))
        XCTAssertNil(MusicArtworkCatalog.searchURL(for: .init(title: "Song", artist: "Artist", album: "Album", duration: .nan)))
        XCTAssertNil(MusicArtworkCatalog.searchURL(for: .init(title: String(repeating: "x", count: 4097), artist: "Artist", album: "Album", duration: 20)))
    }

    func testSelectsExactReleaseAndKeepsVersionAndDurationGuards() throws {
        let data = try response([result(album: "Other Album"), result(title: "Night Train"), result(artist: "Other Artist"), result(duration: 290000), result()])
        XCTAssertEqual(try MusicArtworkCatalog.artworkURL(from: data, matching: track)?.absoluteString, cover)
        for wrong in [result(album: "Night & Day (Remastered)"), result(title: "Night Train (Radio Mix)"), result(artist: "Sample Artist & Guest"), result(duration: 323501)] {
            XCTAssertNil(try MusicArtworkCatalog.artworkURL(from: response([wrong]), matching: track))
        }
        XCTAssertEqual(try MusicArtworkCatalog.artworkURL(from: response([result(duration: 323500)]), matching: track)?.absoluteString, cover)
    }

    func testOnlyNormalizesUnicodeCaseAndWhitespaceWithoutRemovingVersions() throws {
        let result = result(title: "  NIGHT  TRAIN (Extended Mix)\n", artist: "sample artist", album: "Night & Day")
        XCTAssertNotNil(try MusicArtworkCatalog.artworkURL(from: response([result]), matching: track))
        XCTAssertNil(try MusicArtworkCatalog.artworkURL(from: response([self.result(title: "Night Train [Extended Mix]")]), matching: track))
    }

    func testRejectsAmbiguousAlbumIDsAndDifferentArtForSameAlbum() throws {
        XCTAssertNil(try MusicArtworkCatalog.artworkURL(from: response([result(),result(collection: 456, url: "https://is1-ssl.mzstatic.com/other-release.jpg")]), matching: track))
        XCTAssertNil(try MusicArtworkCatalog.artworkURL(from: response([result(),result(url:"https://is1-ssl.mzstatic.com/other.jpg")]), matching: track))
        XCTAssertNotNil(try MusicArtworkCatalog.artworkURL(from: response([result(),result()]), matching: track))
        XCTAssertNotNil(try MusicArtworkCatalog.artworkURL(from: response([result(),result(collection: 456)]), matching: track))
    }

    func testRejectsUntrustedOrInsecureArtworkURLsAndNonSongs() throws {
        for url in ["http://is1-ssl.mzstatic.com/a.jpg", "https://mzstatic.com.attacker.example/a.jpg", "https://user:secret@is1-ssl.mzstatic.com/a.jpg", "file:///private/tmp/a.jpg", "https://is1-ssl.mzstatic.com:8443/a.jpg", "https://is1-ssl.mzstatic.com/a.jpg#fragment"] {
            XCTAssertNil(try MusicArtworkCatalog.artworkURL(from: response([result(url: url)]), matching: track), url)
        }
        var video=result(); video["kind"]="music-video"
        XCTAssertNil(try MusicArtworkCatalog.artworkURL(from: response([video]), matching: track))
        var missingID=result();missingID.removeValue(forKey:"collectionId")
        XCTAssertNil(try MusicArtworkCatalog.artworkURL(from: response([missingID]), matching: track))
    }

    func testRejectsMalformedAndOversizedCatalogResponses() throws {
        XCTAssertThrowsError(try MusicArtworkCatalog.artworkURL(from: Data("[]".utf8), matching: track))
        XCTAssertThrowsError(try MusicArtworkCatalog.artworkURL(from: Data(repeating: 32, count: 512 * 1024 + 1), matching: track))
        XCTAssertThrowsError(try MusicArtworkCatalog.artworkURL(from: response(Array(repeating: result(), count: 101)), matching: track))
    }

    func testLookupUsesMatchedAppleArtworkAndEnforcesBothByteLimits() async throws {
        let catalog=try response([result()])
        let image=Data([1,2,3])
        let lookup=MusicArtworkLookup { url, limit in
            if url.host == "itunes.apple.com" {
                XCTAssertEqual(limit, 512 * 1024)
                return catalog
            }
            XCTAssertEqual(url.absoluteString, "https://is1-ssl.mzstatic.com/image/thumb/example/100x100bb.jpg")
            XCTAssertEqual(limit, 16 * 1024 * 1024)
            return image
        }
        let found=try await lookup.artwork(for: track)
        XCTAssertEqual(found,image)
        let noMatch=MusicArtworkLookup { url, _ in
            XCTAssertEqual(url.host,"itunes.apple.com", "An unmatched result must not download artwork")
            return Data(#"{"resultCount":0,"results":[]}"#.utf8)
        }
        let missing=try await noMatch.artwork(for: track)
        XCTAssertNil(missing)
        let oversized=MusicArtworkLookup { url, _ in url.host == "itunes.apple.com" ? catalog : Data(repeating: 1, count: 16 * 1024 * 1024 + 1) }
        do { _ = try await oversized.artwork(for:track); XCTFail("Oversized artwork accepted") } catch { }
    }
}

private actor SuspendedArtworkQuery {
    private var result: CheckedContinuation<Data, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var queryStarted = false
    private(set) var requestedImage = false
    func fetch(_ url: URL, limit: Int) async -> Data {
        if url.host == "itunes.apple.com" {
            queryStarted = true
            started?.resume(); started = nil
            return await withCheckedContinuation { result = $0 }
        }
        requestedImage = true
        return Data([1,2,3])
    }
    func waitForQuery() async {
        if !queryStarted { await withCheckedContinuation { started = $0 } }
    }
    func release(_ data: Data) { result?.resume(returning: data); result = nil }
}

extension MusicArtworkTests {
    func testCancelWhileQueryIsPendingPreventsArtworkRequest() async throws {
        let catalog = try response([result()])
        let suspended = SuspendedArtworkQuery()
        let lookup = MusicArtworkLookup { url, limit in await suspended.fetch(url, limit: limit) }
        let task = Task { try await lookup.artwork(for: track) }
        await suspended.waitForQuery()
        task.cancel()
        await suspended.release(catalog)
        do { _ = try await task.value; XCTFail("Canceled lookup continued") }
        catch is CancellationError { }
        let requestedImage = await suspended.requestedImage
        XCTAssertFalse(requestedImage)
    }

    func testUnicodeDashesSpacingAndQuotesKeepEquivalentReleaseIdentity() throws {
        let identity = MusicArtworkTrack(title: "I'm Here (Extended Mix)", artist: "Sample Artist", album: "1992–2012", duration: 321.5)
        let data = try response([result(title: "I’m Here (Extended Mix)", album: "1992 - 2012")])
        XCTAssertNotNil(try MusicArtworkCatalog.artworkURL(from: data, matching: identity))
    }
}
