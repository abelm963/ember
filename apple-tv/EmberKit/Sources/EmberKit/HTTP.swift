import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thrown when a server answers with an error, or can't be reached.
public struct APIError: Error, LocalizedError, Equatable, Sendable {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
    public var errorDescription: String? { message }
}

/// A finished HTTP exchange.
public struct HTTPResult: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Header lookup that ignores letter case.
    public func header(_ name: String) -> String? {
        let n = name.lowercased()
        return headers.first { $0.key.lowercased() == n }?.value
    }

    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// How requests leave the app. Tests swap in a fake server.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

/// The real network. Cookies are handled by Ember itself (each profile has its own Seerr
/// session), so the system cookie store is switched off.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    public static let shared = URLSessionTransport()
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    let ns = error as NSError
                    let msg: String
                    if ns.code == NSURLErrorTimedOut {
                        msg = "The server took too long to answer."
                    } else if ns.code == NSURLErrorCannotFindHost || ns.code == NSURLErrorCannotConnectToHost {
                        msg = "Couldn't reach \(request.url?.host ?? "the server"). Check the address and that it's switched on."
                    } else {
                        msg = error.localizedDescription
                    }
                    cont.resume(throwing: APIError(0, msg))
                    return
                }
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (k, v) in http?.allHeaderFields ?? [:] {
                    headers["\(k)"] = "\(v)"
                }
                cont.resume(returning: HTTPResult(status: http?.statusCode ?? 0, headers: headers, body: data ?? Data()))
            }
            task.resume()
        }
    }
}

/// Query string helpers shared by both clients.
enum Query {
    /// Encodes like `Uri.encodeComponent` in Dart: spaces become %20, never "+".
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func string(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}

/// Trims what people paste: whitespace, missing scheme, `#…` and `?…`, trailing slashes.
enum Address {
    static func clean(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return u }
        if !u.lowercased().hasPrefix("http://") && !u.lowercased().hasPrefix("https://") { u = "http://" + u }
        for c in ["#", "?"] {
            if let r = u.range(of: c) { u = String(u[..<r.lowerBound]) }
        }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
}
