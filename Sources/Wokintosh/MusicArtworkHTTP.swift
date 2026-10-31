import Foundation
import WokintoshCore

/// Only Apple's search endpoint and artwork CDNs receive requests; redirects keep that boundary.
private final class MusicArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allows(_ url: URL, catalog: Bool) -> Bool {
        if catalog {
            return url.scheme == "https" && url.host == "itunes.apple.com" && url.path == "/search" &&
                url.user == nil && url.password == nil && url.fragment == nil && (url.port == nil || url.port == 443)
        }
        return MusicArtworkCatalog.isArtworkURL(url)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let catalog = task.originalRequest?.url?.host == "itunes.apple.com"
        completionHandler(request.url.map { Self.allows($0, catalog: catalog) } == true ? request : nil)
    }
}

actor MusicArtworkHTTPClient {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: MusicArtworkRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        let catalog = url.host == "itunes.apple.com"
        guard MusicArtworkRedirectPolicy.allows(url, catalog: catalog), maxBytes > 0, maxBytes <= 16 * 1024 * 1024 else {
            throw MusicArtworkCatalogError.invalidResponse
        }
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let finalURL = response.url, MusicArtworkRedirectPolicy.allows(finalURL, catalog: catalog),
              response.expectedContentLength <= maxBytes else { throw MusicArtworkCatalogError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maxBytes else { throw MusicArtworkCatalogError.invalidResponse }
            data.append(byte)
        }
        return data
    }
}
