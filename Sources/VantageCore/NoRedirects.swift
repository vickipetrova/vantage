import Foundation

/// A URLSession delegate that refuses every redirect.
///
/// "Two network destinations" is a promise this app makes in its README and its SECURITY.md, and
/// without this it is only a description of current behaviour. A 302 from either host would send
/// the next request — and, for App Store Connect, the bearer token with it — somewhere neither
/// document mentions. Refusing redirects turns the promise into something the code enforces.
///
/// Returning nil from the redirect callback delivers the redirect response itself to the caller,
/// which then fails the status-code check. That's the intended outcome: a redirect is not a report.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
