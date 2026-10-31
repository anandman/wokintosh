import Foundation

/// Catalog matching deliberately keeps every mix, version, collaborator and album qualifier.
public struct MusicArtworkTrack: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public init(title: String, artist: String, album: String, duration: Double) {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration
    }
}

public enum MusicArtworkCatalogError: Error { case invalidResponse }

public enum MusicArtworkCatalog {
    public static func searchURL(for track: MusicArtworkTrack) -> URL? {
        let fields = [track.artist, track.title, track.album].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              track.duration.isFinite, track.duration > 0 else { return nil }
        var url = URLComponents(string: "https://itunes.apple.com/search")!
        url.queryItems = [URLQueryItem(name: "term", value: fields.joined(separator: " ")),
                          URLQueryItem(name: "media", value: "music"), URLQueryItem(name: "entity", value: "song"),
                          URLQueryItem(name: "country", value: "US"), URLQueryItem(name: "limit", value: "100")]
        return url.url
    }

    public static func artworkURL(from data: Data, matching track: MusicArtworkTrack) throws -> URL? {
        guard data.count <= 512 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]], results.count <= 100 else {
            throw MusicArtworkCatalogError.invalidResponse
        }
        guard searchURL(for: track) != nil else { return nil }
        var matches = Set<URL>()
        for result in results {
            guard result["wrapperType"] as? String == "track", result["kind"] as? String == "song",
                  let title = result["trackName"] as? String, normalized(title) == normalized(track.title),
                  let artist = result["artistName"] as? String, normalized(artist) == normalized(track.artist),
                  let album = result["collectionName"] as? String, normalized(album) == normalized(track.album),
                  let duration = result["trackTimeMillis"] as? NSNumber, duration.doubleValue.isFinite,
                  duration.doubleValue > 0, abs(duration.doubleValue / 1000 - track.duration) <= 2,
                  let collection = result["collectionId"] as? NSNumber, collection.int64Value > 0,
                  let value = result["artworkUrl100"] as? String, let url = URL(string: value), isArtworkURL(url) else { continue }
            matches.insert(url)
        }
        // Identical catalog duplicates are harmless. Conflicting covers are never guessed.
        return matches.count == 1 ? matches.first : nil
    }

    public static func isArtworkURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), url.absoluteString.utf8.count <= 4096 else { return false }
        return host.hasSuffix(".mzstatic.com") || host.hasSuffix(".itunes.apple.com")
    }

    private static func normalized(_ value: String) -> String {
        let text = value.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "−", with: "-")
        return text.components(separatedBy: "-").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.joined(separator: "-")
    }
}

/// The fetch boundary is injected so matching and size guards can be exercised without a network.
public struct MusicArtworkLookup: Sendable {
    public typealias Fetch = @Sendable (URL, Int) async throws -> Data
    private let fetch: Fetch
    public init(fetch: @escaping Fetch) { self.fetch = fetch }
    public func artwork(for track: MusicArtworkTrack) async throws -> Data? {
        guard let query = MusicArtworkCatalog.searchURL(for: track) else { return nil }
        try Task.checkCancellation()
        let catalog = try await fetch(query, 512 * 1024)
        guard let url = try MusicArtworkCatalog.artworkURL(from: catalog, matching: track) else { return nil }
        try Task.checkCancellation()
        let image = try await fetch(url, 16 * 1024 * 1024)
        try Task.checkCancellation()
        guard !image.isEmpty, image.count <= 16 * 1024 * 1024 else { throw MusicArtworkCatalogError.invalidResponse }
        return image
    }
}
