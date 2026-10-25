import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Seerr media availability (shared by Overseerr / Jellyseerr / Seerr).
public enum MediaStatus: Sendable {
    case unknown, pending, processing, partiallyAvailable, available, other

    public init(_ v: Int?) {
        switch v {
        case nil, 1: self = .unknown
        case 2: self = .pending
        case 3: self = .processing
        case 4: self = .partiallyAvailable
        case 5: self = .available
        default: self = .other
        }
    }
}

/// A movie or series as Seerr describes it (from TMDB).
public struct SeerrMedia: Identifiable, Hashable, Sendable {
    public let raw: JSON
    public init(_ raw: JSON) { self.raw = raw }

    public var id: Int { raw["id"].int ?? 0 }
    public var key: String { "\(mediaType):\(id)" }
    public var mediaType: String {
        raw["mediaType"].string ?? (!raw["firstAirDate"].isNull || !raw["name"].isNull ? "tv" : "movie")
    }
    public var isTv: Bool { mediaType == "tv" }
    public var title: String { raw["title"].string ?? raw["name"].string ?? raw["originalTitle"].string ?? "" }
    public var overview: String? { raw["overview"].string }
    public var posterPath: String? { raw["posterPath"].string }
    public var backdropPath: String? { raw["backdropPath"].string }
    public var date: String? { raw["releaseDate"].string ?? raw["firstAirDate"].string }
    public var year: Int? { date.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil } }
    public var voteAverage: Double? { raw["voteAverage"].double }
    public var mediaInfo: JSON { raw["mediaInfo"] }
    public var status: MediaStatus { MediaStatus(mediaInfo["status"].int) }
    public var requests: [JSON] { mediaInfo["requests"].list }
    public var isAvailable: Bool { status == .available }
    public var isRequested: Bool {
        status == .pending || status == .processing || (!requests.isEmpty && !isAvailable)
    }

    // Details-only fields.
    public var genres: [String] { raw["genres"].list.compactMap { $0["name"].string } }
    /// Minutes.
    public var runtime: Int? { raw["runtime"].int }
    public var numberOfSeasons: Int? { raw["numberOfSeasons"].int }
    public var seasons: [JSON] { raw["seasons"].list.filter { ($0["seasonNumber"].int ?? 0) > 0 } }
    public var cast: [JSON] { raw["credits"]["cast"].list }
    public var videos: [JSON] { raw["relatedVideos"].list }

    public var certification: String? {
        for r in raw["releases"]["results"].list {
            for d in r["release_dates"].list {
                if let c = d["certification"].string, !c.isEmpty { return c }
            }
        }
        return raw["contentRatings"]["results"].list.first?["rating"].string
    }

    /// The best official YouTube trailer (a Trailer, else a Teaser).
    public var bestTrailerKey: String? {
        let yt = videos.filter { $0["site"].string?.lowercased() == "youtube" }
        for t in ["Trailer", "Teaser"] {
            if let v = yt.first(where: { $0["type"].string == t }) { return v["key"].string }
        }
        return nil
    }

    public static func image(_ path: String?, size: String = "w780") -> URL? {
        path.flatMap { URL(string: "https://image.tmdb.org/t/p/\(size)\($0)") }
    }
    public var posterURL: URL? { Self.image(posterPath, size: "w500") }
    public var backdropURL: URL? { Self.image(backdropPath, size: "w1280") }
    public var largeBackdropURL: URL? { Self.image(backdropPath, size: "original") }
}

public struct SeerrRequest: Identifiable, Sendable {
    public let raw: JSON
    public init(_ raw: JSON) { self.raw = raw }

    public var id: Int { raw["id"].int ?? 0 }
    /// 1 pending, 2 approved, 3 declined.
    public var status: Int { raw["status"].int ?? 1 }
    public var media: JSON { raw["media"] }
    public var mediaStatus: MediaStatus { MediaStatus(media["status"].int) }
    public var tmdbId: Int? { media["tmdbId"].int }
    public var mediaType: String { media["mediaType"].string ?? raw["type"].string ?? "movie" }
    public var is4k: Bool { raw["is4k"].isTrue }
    public var requestedBy: String {
        raw["requestedBy"]["displayName"].string ?? raw["requestedBy"]["jellyfinUsername"].string ?? "Someone"
    }
    public var createdAt: Date? { raw["createdAt"].string.flatMap(DateParsing.iso) }
    public var seasonNumbers: [Int] { raw["seasons"].list.compactMap { $0["seasonNumber"].int } }

    /// Downloads in progress (from Radarr / Sonarr, via Seerr).
    public var downloads: [JSON] { media[is4k ? "downloadStatus4k" : "downloadStatus"].list }

    /// 0…1 across this request's downloads, or nil when nothing is downloading.
    public var downloadProgress: Double? {
        let d = downloads
        if d.isEmpty { return nil }
        var size = 0.0, left = 0.0
        for x in d {
            size += x["size"].double ?? 0
            left += x["sizeLeft"].double ?? 0
        }
        guard size > 0 else { return 0 }
        return min(max((size - left) / size, 0), 1)
    }

    /// When the slowest download should finish.
    public var downloadETA: Date? {
        downloads.compactMap { $0["estimatedCompletionTime"].string.flatMap(DateParsing.iso) }.max()
    }

    /// The Jellyfin item, once it's on the server.
    public var jellyfinId: String? { media[is4k ? "jellyfinMediaId4k" : "jellyfinMediaId"].string }

    /// Plain-language status combining approval and download state.
    public var label: String {
        if status == 3 { return "Declined" }
        if mediaStatus == .available { return "Available" }
        if mediaStatus == .partiallyAvailable { return downloads.isEmpty ? "Partly available" : "Downloading" }
        if status == 1 { return "Pending approval" }
        if !downloads.isEmpty { return "Downloading" }
        if mediaStatus == .processing { return "Approved · waiting for release" }
        return "Approved"
    }

    public var filterKey: String {
        if status == 3 { return "Declined" }
        if mediaStatus == .available || mediaStatus == .partiallyAvailable { return "Available" }
        if status == 1 { return "Pending" }
        return "Approved"
    }
}

/// Seerr client. Signs in with the person's Jellyfin account (a session cookie, so each
/// profile's requests are its own) or with an API key from Seerr's settings.
public final class SeerrClient: @unchecked Sendable {
    public let baseURL: String
    public var apiKey: String?
    /// Called when Seerr rejects the saved session; signs in again without a password and
    /// returns true if the request should be retried.
    public var reauth: (@Sendable () async -> Bool)?
    let transport: HTTPTransport
    private var jar: [String: String] = [:]
    private let lock = NSLock()

    public init(baseURL: String, cookie: String? = nil, apiKey: String? = nil,
                transport: HTTPTransport = URLSessionTransport.shared) {
        self.baseURL = SeerrClient.normalize(baseURL)
        self.apiKey = apiKey
        self.transport = transport
        self.cookie = cookie
    }

    /// Accepts any link copied from Seerr in a browser (…/login, …/discover/movies) and
    /// returns the base address. A reverse-proxy base path (e.g. /seerr) is kept.
    public static func normalize(_ url: String) -> String {
        let u = Address.clean(url)
        guard var comps = URLComponents(string: u) else { return u }
        let pages: Set<String> = ["login", "setup", "discover", "requests", "request", "movie", "movies", "tv",
                                  "series", "users", "settings", "search", "issues", "profile", "collection",
                                  "person", "api", "watchlist", "blacklist"]
        let segs = comps.path.split(separator: "/").map(String.init)
        let keep = segs.firstIndex { pages.contains($0.lowercased()) }.map { Array(segs[..<$0]) } ?? segs
        comps.path = keep.isEmpty ? "" : "/" + keep.joined(separator: "/")
        var out = comps.string ?? u
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    // MARK: Session

    /// Cookies Seerr hands out: the session (connect.sid) and, with CSRF protection on,
    /// _csrf / XSRF-TOKEN. Saved as one "a=b; c=d" string per profile.
    public var cookie: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return jar.isEmpty ? nil : jar.keys.sorted().map { "\($0)=\(jar[$0]!)" }.joined(separator: "; ")
        }
        set {
            lock.lock(); defer { lock.unlock() }
            jar.removeAll()
            guard let newValue else { return }
            for part in newValue.split(separator: ";") {
                guard let eq = part.firstIndex(of: "=") else { continue }
                let k = part[..<eq].trimmingCharacters(in: .whitespaces)
                let v = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !k.isEmpty { jar[k] = v }
            }
        }
    }

    private func jarValue(_ k: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return jar[k]
    }

    private func dropSession() {
        lock.lock(); defer { lock.unlock() }
        jar.removeValue(forKey: "connect.sid")
    }

    public var hasSession: Bool { jarValue("connect.sid") != nil }
    public var isSignedIn: Bool { hasSession || !(apiKey ?? "").isEmpty }

    func keepCookies(_ res: HTTPResult) {
        guard let raw = res.header("Set-Cookie") else { return }
        let re = try! NSRegularExpression(pattern: "(connect\\.sid|_csrf|XSRF-TOKEN)=([^;,\\s]+)")
        let ns = raw as NSString
        lock.lock(); defer { lock.unlock() }
        for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            jar[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
    }

    func request(_ method: String, _ path: String, query: [(String, String)] = [], body: JSON? = nil) throws -> URLRequest {
        let q = query.isEmpty ? "" : "?" + Query.string(query)
        guard let url = URL(string: "\(baseURL)/api/v1\(path)\(q)") else { throw APIError(0, "That Seerr address isn't valid.") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let c = cookie { req.setValue(c, forHTTPHeaderField: "Cookie") }
        if let x = jarValue("XSRF-TOKEN") { req.setValue(x.removingPercentEncoding ?? x, forHTTPHeaderField: "X-XSRF-TOKEN") }
        if !hasSession, let k = apiKey, !k.isEmpty { req.setValue(k, forHTTPHeaderField: "X-Api-Key") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try body.encoded()
        }
        return req
    }

    static func errorText(_ res: HTTPResult) -> String {
        if let j = try? JSON.parse(res.body), let m = j["message"].text ?? j["error"].text { return m }
        return "HTTP \(res.status)"
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [(String, String)] = [], body: JSON? = nil,
              retried: Bool = false) async throws -> JSON {
        let res = try await transport.send(try request(method, path, query: query, body: body))
        keepCookies(res)
        // With CSRF protection on, Seerr wants a token from a cookie echoed in a header.
        if res.status == 403, method != "GET", !retried, res.text.lowercased().contains("csrf") {
            keepCookies(try await transport.send(try request("GET", "/status")))
            return try await send(method, path, query: query, body: body, retried: true)
        }
        if res.status == 401 || res.status == 403, !retried, let reauth, !path.hasPrefix("/auth/") {
            if await reauth() { return try await send(method, path, query: query, body: body, retried: true) }
        }
        if res.status == 401 || res.status == 403 {
            throw APIError(res.status, "Seerr refused the request (\(Self.errorText(res))). Sign in to Seerr again in Settings.")
        }
        if res.status >= 400 { throw APIError(res.status, "Seerr returned \(res.status): \(Self.errorText(res))") }
        if res.body.isEmpty { return .null }
        return try JSON.parse(res.body)
    }

    public func status() async throws -> JSON { try await send("GET", "/status") }

    /// Checks the address points at a Seerr server.
    public func ping() async -> Bool { (try? await send("GET", "/status"))?["version"].isNull == false }

    /// Signs in with Jellyfin credentials. Keeps the session cookie on success.
    @discardableResult
    public func signInWithJellyfin(username: String, password: String) async throws -> JSON {
        dropSession()
        do {
            let json = try await send("POST", "/auth/jellyfin", body: ["username": .string(username), "password": .string(password)])
            guard hasSession else { throw APIError(0, "Seerr accepted the sign-in but sent no session.") }
            return json
        } catch let e as APIError {
            throw APIError(e.status, "Seerr sign-in failed: \(e.message)")
        }
    }

    /// Signs in without a password using Jellyfin Quick Connect: Seerr asks Jellyfin for a code,
    /// and `authorize` approves it with the Jellyfin session Ember already has.
    @discardableResult
    public func signInWithQuickConnect(authorize: (String) async throws -> Void) async throws -> JSON {
        dropSession()
        let initiate = try await send("POST", "/auth/jellyfin/quickconnect/initiate")
        let code = initiate["code"].text ?? ""
        let secret = initiate["secret"].text ?? ""
        try await authorize(code)
        for _ in 0..<10 {
            let check = try await send("GET", "/auth/jellyfin/quickconnect/check", query: [("secret", secret)])
            if check["authenticated"].isTrue { break }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        let json = try await send("POST", "/auth/jellyfin/quickconnect/authenticate", body: ["secret": .string(secret)])
        guard hasSession else { throw APIError(0, "Seerr accepted the sign-in but sent no session.") }
        return json
    }

    public func me() async throws -> JSON { try await send("GET", "/auth/me") }

    /// Seerr permission bits: ADMIN = 2, MANAGE_REQUESTS = 16.
    public static func canManageRequests(_ user: JSON) -> Bool {
        let p = user["permissions"].int ?? 0
        return p & 2 != 0 || p & 16 != 0
    }

    // MARK: Discover

    func results(_ json: JSON, defaultType: String? = nil) -> [SeerrMedia] {
        json["results"].list.compactMap { e in
            var raw = e
            if let t = defaultType, raw["mediaType"].isNull { raw.set("mediaType", .string(t)) }
            let type = raw["mediaType"].string
            return type == nil || type == "movie" || type == "tv" ? SeerrMedia(raw) : nil
        }
    }

    public func trending(page: Int = 1) async throws -> [SeerrMedia] {
        results(try await send("GET", "/discover/trending", query: [("page", "\(page)")]))
    }

    public func upcoming(_ mediaType: String, page: Int = 1) async throws -> [SeerrMedia] {
        let path = mediaType == "tv" ? "/discover/tv/upcoming" : "/discover/movies/upcoming"
        return results(try await send("GET", path, query: [("page", "\(page)")]), defaultType: mediaType)
    }

    public func popular(_ mediaType: String, page: Int = 1) async throws -> [SeerrMedia] {
        let path = mediaType == "tv" ? "/discover/tv" : "/discover/movies"
        return results(try await send("GET", path, query: [("page", "\(page)"), ("sortBy", "popularity.desc")]),
                       defaultType: mediaType)
    }

    public func search(_ query: String, page: Int = 1) async throws -> [SeerrMedia] {
        results(try await send("GET", "/search", query: [("query", query), ("page", "\(page)")]))
    }

    public func details(_ mediaType: String, tmdbId: Int) async throws -> SeerrMedia {
        var json = try await send("GET", mediaType == "tv" ? "/tv/\(tmdbId)" : "/movie/\(tmdbId)")
        json.set("mediaType", .string(mediaType))
        return SeerrMedia(json)
    }

    public func similar(_ mediaType: String, tmdbId: Int) async throws -> [SeerrMedia] {
        let path = mediaType == "tv" ? "/tv/\(tmdbId)/similar" : "/movie/\(tmdbId)/similar"
        return results(try await send("GET", path), defaultType: mediaType)
    }

    // MARK: Requests

    /// Requests a title. For series, `seasons` nil = every season.
    public func request(mediaType: String, tmdbId: Int, seasons: [Int]? = nil, is4k: Bool = false) async throws {
        var body: JSON = ["mediaType": .string(mediaType), "mediaId": JSON(tmdbId), "is4k": .bool(is4k)]
        if mediaType == "tv" { body.set("seasons", seasons.map { JSON($0) } ?? "all") }
        try await send("POST", "/request", body: body)
    }

    public func requests(take: Int = 40) async throws -> [SeerrRequest] {
        try await send("GET", "/request", query: [("take", "\(take)"), ("skip", "0"), ("sort", "added"), ("filter", "all")])["results"]
            .list.map(SeerrRequest.init)
    }

    public func approve(_ requestId: Int) async throws { try await send("POST", "/request/\(requestId)/approve") }
    public func decline(_ requestId: Int) async throws { try await send("POST", "/request/\(requestId)/decline") }
}
