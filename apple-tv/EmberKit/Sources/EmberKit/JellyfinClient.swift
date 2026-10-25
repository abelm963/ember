import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public let emberClientName = "Ember"
public let emberClientVersion = "0.1.0"

/// Jellyfin REST client covering what Ember needs. Mirrors `lib/api/jellyfin.dart`.
public final class JellyfinClient: @unchecked Sendable {
    public let baseURL: String
    public let deviceId: String
    public let deviceName: String
    public var token: String?
    public var userId: String?
    let transport: HTTPTransport

    public init(baseURL: String, deviceId: String, deviceName: String, token: String? = nil, userId: String? = nil,
                transport: HTTPTransport = URLSessionTransport.shared) {
        self.baseURL = JellyfinClient.normalize(baseURL)
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.token = token
        self.userId = userId
        self.transport = transport
    }

    /// Accepts whatever people type or paste (`hearth:8096`, `https://host/web/#/home`) and
    /// returns the server's base address. A reverse-proxy base path is kept.
    public static func normalize(_ url: String) -> String {
        var u = Address.clean(url)
        for suffix in ["/web/index.html", "/web"] where u.lowercased().hasSuffix(suffix) {
            u.removeLast(suffix.count)
        }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    /// HTTP header values must be plain ASCII.
    static func ascii(_ v: String) -> String {
        String(v.unicodeScalars.map { $0.value >= 0x20 && $0.value <= 0x7E ? Character($0) : "-" })
            .replacingOccurrences(of: "\"", with: "'")
    }

    public var authHeader: String {
        var parts = [
            "Client=\"\(emberClientName)\"",
            "Device=\"\(Self.ascii(deviceName))\"",
            "DeviceId=\"\(Self.ascii(deviceId))\"",
            "Version=\"\(emberClientVersion)\"",
        ]
        if let token { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    // MARK: Requests

    /// Builds a URL. `nil` values and empty lists are left out; lists are joined with commas.
    func url(_ path: String, _ query: [(String, Any?)] = []) -> URL {
        var items: [(String, String)] = []
        for (k, v) in query {
            switch v {
            case nil: continue
            case let list as [String]:
                if !list.isEmpty { items.append((k, list.joined(separator: ","))) }
            case let b as Bool: items.append((k, b ? "true" : "false"))
            case let some?: items.append((k, "\(some)"))
            }
        }
        let q = items.isEmpty ? "" : "?" + Query.string(items)
        return URL(string: baseURL + path + q)!
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [(String, Any?)] = [], body: JSON? = nil,
              timeout: TimeInterval = 20) async throws -> JSON {
        var req = URLRequest(url: url(path, query), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try body.encoded()
        }
        let res = try await transport.send(req)
        if res.status == 401 { throw APIError(401, "Your session has expired. Please sign in again.") }
        if res.status >= 400 { throw APIError(res.status, "Server returned \(res.status) for \(path)") }
        if res.body.isEmpty { return .null }
        return (try? JSON.parse(res.body)) ?? .string(res.text)
    }

    func items(_ json: JSON) -> [JFItem] {
        if let list = json["Items"].array { return list.map(JFItem.init) }
        if let list = json.array { return list.map(JFItem.init) }
        return []
    }

    static let fields =
        "Overview,Genres,PrimaryImageAspectRatio,ProductionYear,OfficialRating,CommunityRating,ProviderIds,ChildCount,RemoteTrailers,LocalTrailerCount,Status,EndDate"
    static let imageTypes = "Primary,Backdrop,Thumb,Logo"

    // MARK: Server

    /// Public server info; works without signing in. Used to check an address.
    public func publicInfo() async throws -> JSON {
        let json = try await send("GET", "/System/Info/Public", timeout: 6)
        guard json["Id"].string != nil || json["ServerName"].string != nil else {
            throw APIError(0, "That address answered, but it isn't a Jellyfin server.")
        }
        return json
    }

    // MARK: Sign-in

    public func publicUsers() async throws -> [PublicUser] {
        try await send("GET", "/Users/Public").list.map {
            PublicUser(id: $0["Id"].string ?? "", name: $0["Name"].string ?? "",
                       imageTag: $0["PrimaryImageTag"].string, hasPassword: $0["HasPassword"].bool ?? true)
        }
    }

    private func adopt(_ json: JSON) throws -> AuthResult {
        guard let token = json["AccessToken"].string else { throw APIError(0, "The server didn't send a sign-in token.") }
        let r = AuthResult(token: token, user: json["User"])
        self.token = r.token
        self.userId = r.userId
        return r
    }

    public func authenticate(username: String, password: String) async throws -> AuthResult {
        do {
            return try adopt(try await send("POST", "/Users/AuthenticateByName", body: ["Username": .string(username), "Pw": .string(password)]))
        } catch let e as APIError where e.status == 401 {
            throw APIError(401, "That username or password isn't right.")
        }
    }

    public func quickConnectEnabled() async -> Bool {
        (try? await send("GET", "/QuickConnect/Enabled"))?.isTrue ?? false
    }

    /// Starts Quick Connect. Returns the secret (kept by Ember) and the code (shown on screen).
    public func quickConnectInitiate() async throws -> (secret: String, code: String) {
        let json = try await send("POST", "/QuickConnect/Initiate")
        return (json["Secret"].string ?? "", json["Code"].string ?? "")
    }

    public func quickConnectAuthorized(secret: String) async throws -> Bool {
        try await send("GET", "/QuickConnect/Connect", query: [("Secret", secret)])["Authenticated"].isTrue
    }

    public func authenticateWithQuickConnect(secret: String) async throws -> AuthResult {
        try adopt(try await send("POST", "/Users/AuthenticateWithQuickConnect", body: ["Secret": .string(secret)]))
    }

    /// Approves a Quick Connect code with this signed-in session (used to sign in to Seerr).
    public func authorizeQuickConnect(code: String) async throws {
        try await send("POST", "/QuickConnect/Authorize", query: [("code", code), ("userId", userId)])
    }

    public func me() async throws -> JSON { try await send("GET", "/Users/Me") }

    public func logout() async { _ = try? await send("POST", "/Sessions/Logout") }

    // MARK: Library

    public func views() async throws -> [JFItem] {
        items(try await send("GET", "/UserViews", query: [("userId", userId)]))
    }

    public func resume(limit: Int = 16) async throws -> [JFItem] {
        items(try await send("GET", "/UserItems/Resume", query: [
            ("userId", userId), ("limit", limit), ("mediaTypes", "Video"),
            ("fields", Self.fields), ("enableImageTypes", Self.imageTypes),
        ]))
    }

    public func nextUp(limit: Int = 16) async throws -> [JFItem] {
        items(try await send("GET", "/Shows/NextUp", query: [
            ("userId", userId), ("limit", limit), ("fields", Self.fields), ("enableResumable", false),
        ]))
    }

    /// Episodes of shows in the library that haven't aired yet.
    public func upcomingEpisodes(limit: Int = 60) async throws -> [JFItem] {
        items(try await send("GET", "/Shows/Upcoming", query: [
            ("userId", userId), ("limit", limit), ("fields", Self.fields), ("enableImageTypes", "Primary,Backdrop,Thumb"),
        ]))
    }

    public func latest(parentId: String? = nil, types: [String]? = nil, limit: Int = 20) async throws -> [JFItem] {
        items(try await send("GET", "/Items/Latest", query: [
            ("userId", userId), ("parentId", parentId), ("includeItemTypes", types), ("limit", limit), ("fields", Self.fields),
        ]))
    }

    public func items(parentId: String? = nil, types: [String]? = nil, genre: String? = nil,
                      sortBy: String? = "SortName", sortOrder: String = "Ascending", filters: String? = nil,
                      searchTerm: String? = nil, limit: Int? = nil, startIndex: Int? = nil,
                      recursive: Bool = true) async throws -> [JFItem] {
        items(try await send("GET", "/Items", query: [
            ("userId", userId), ("parentId", parentId), ("includeItemTypes", types), ("genres", genre),
            ("sortBy", sortBy), ("sortOrder", sortOrder), ("filters", filters), ("searchTerm", searchTerm),
            ("limit", limit), ("startIndex", startIndex), ("recursive", recursive),
            ("fields", Self.fields), ("enableImageTypes", Self.imageTypes),
        ]))
    }

    public func genres(parentId: String? = nil, types: [String]? = nil) async throws -> [String] {
        items(try await send("GET", "/Genres", query: [
            ("userId", userId), ("parentId", parentId), ("includeItemTypes", types), ("sortBy", "SortName"),
        ])).map(\.name)
    }

    public func item(_ id: String) async throws -> JFItem {
        JFItem(try await send("GET", "/Items/\(id)", query: [("userId", userId)]))
    }

    public func seasons(seriesId: String) async throws -> [JFItem] {
        items(try await send("GET", "/Shows/\(seriesId)/Seasons", query: [("userId", userId), ("fields", Self.fields)]))
    }

    public func episodes(seriesId: String, seasonId: String? = nil, startItemId: String? = nil,
                         limit: Int? = nil) async throws -> [JFItem] {
        items(try await send("GET", "/Shows/\(seriesId)/Episodes", query: [
            ("userId", userId), ("seasonId", seasonId), ("startItemId", startItemId), ("limit", limit),
            ("fields", Self.fields + ",MediaSources"),
        ]))
    }

    /// The episode after `episode` in its series, or nil at the end.
    public func nextEpisode(after episode: JFItem) async throws -> JFItem? {
        guard let sid = episode.seriesId else { return nil }
        let list = try await episodes(seriesId: sid, startItemId: episode.id, limit: 2)
        return list.count > 1 ? list[1] : nil
    }

    /// What "Play" means for a series: the next unwatched (or in-progress) episode, else the first.
    public func episodeToPlay(series: JFItem) async throws -> JFItem? {
        if let next = try await nextUp(limit: 50).first(where: { $0.seriesId == series.id }) { return next }
        return try await episodes(seriesId: series.id, limit: 1).first
    }

    public func similar(_ id: String, limit: Int = 12) async throws -> [JFItem] {
        items(try await send("GET", "/Items/\(id)/Similar", query: [("userId", userId), ("limit", limit), ("fields", Self.fields)]))
    }

    public func localTrailers(_ id: String) async -> [JFItem] {
        (try? items(await send("GET", "/Items/\(id)/LocalTrailers", query: [("userId", userId)]))) ?? []
    }

    public func search(_ term: String, limit: Int = 24) async throws -> [JFItem] {
        try await items(types: ["Movie", "Series"], sortBy: nil, searchTerm: term, limit: limit)
    }

    public func favorites() async throws -> [JFItem] {
        try await items(types: ["Movie", "Series"], filters: "IsFavorite")
    }

    /// The movie or series in the library with this TMDB id, or nil.
    /// Newer Jellyfin ignores the provider-id filter, so every candidate's id is checked.
    public func find(tmdbId: String, mediaType: String, title: String? = nil) async throws -> JFItem? {
        func look(_ extra: [(String, Any?)]) async throws -> JFItem? {
            let list = items(try await send("GET", "/Items", query: [
                ("userId", userId), ("recursive", true), ("includeItemTypes", mediaType == "tv" ? "Series" : "Movie"),
                ("limit", 50), ("fields", Self.fields),
            ] + extra))
            return list.first { $0.tmdbId == tmdbId }
        }
        if let title, !title.isEmpty, let hit = try await look([("searchTerm", title)]) { return hit }
        return try await look([("hasTmdbId", true), ("anyProviderIdEquals", "tmdb.\(tmdbId)")])
    }

    public func setFavorite(_ id: String, _ favorite: Bool) async throws {
        try await send(favorite ? "POST" : "DELETE", "/UserFavoriteItems/\(id)", query: [("userId", userId)])
    }

    public func setPlayed(_ id: String, _ played: Bool) async throws {
        try await send(played ? "POST" : "DELETE", "/UserPlayedItems/\(id)", query: [("userId", userId)])
    }

    // MARK: Images

    public func imageURL(_ itemId: String, _ type: String, tag: String? = nil, maxWidth: Int? = nil,
                         maxHeight: Int? = nil, index: Int = 0) -> URL {
        let path = type == "Backdrop" ? "/Items/\(itemId)/Images/Backdrop/\(index)" : "/Items/\(itemId)/Images/\(type)"
        return url(path, [("quality", 90), ("tag", tag), ("maxWidth", maxWidth), ("maxHeight", maxHeight)])
    }

    /// Best wide (16:9) image: episode still, thumb, backdrop, then the series' artwork.
    public func landscapeImage(_ it: JFItem, maxWidth: Int = 640) -> URL? {
        let tags = it.imageTags
        if it.isEpisode, let t = tags["Primary"] { return imageURL(it.id, "Primary", tag: t, maxWidth: maxWidth) }
        if let t = tags["Thumb"] { return imageURL(it.id, "Thumb", tag: t, maxWidth: maxWidth) }
        if let t = it.backdropTags.first { return imageURL(it.id, "Backdrop", tag: t, maxWidth: maxWidth) }
        if let p = it.parentThumbItemId, let t = it.parentThumbTag { return imageURL(p, "Thumb", tag: t, maxWidth: maxWidth) }
        if let p = it.parentBackdropItemId, let t = it.parentBackdropTags.first {
            return imageURL(p, "Backdrop", tag: t, maxWidth: maxWidth)
        }
        if let t = tags["Primary"] { return imageURL(it.id, "Primary", tag: t, maxWidth: maxWidth) }
        return nil
    }

    public func backdropImage(_ it: JFItem, maxWidth: Int = 1920) -> URL? {
        if let t = it.backdropTags.first { return imageURL(it.id, "Backdrop", tag: t, maxWidth: maxWidth) }
        if let p = it.parentBackdropItemId, let t = it.parentBackdropTags.first {
            return imageURL(p, "Backdrop", tag: t, maxWidth: maxWidth)
        }
        return landscapeImage(it, maxWidth: maxWidth)
    }

    public func posterImage(_ it: JFItem, maxHeight: Int = 480) -> URL? {
        if !it.isEpisode, let t = it.imageTags["Primary"] { return imageURL(it.id, "Primary", tag: t, maxHeight: maxHeight) }
        if let s = it.seriesId, let t = it.seriesPrimaryTag { return imageURL(s, "Primary", tag: t, maxHeight: maxHeight) }
        return nil
    }

    public func logoImage(_ it: JFItem, maxWidth: Int = 900) -> URL? {
        if let t = it.imageTags["Logo"] { return imageURL(it.id, "Logo", tag: t, maxWidth: maxWidth) }
        if let p = it.parentLogoItemId, let t = it.parentLogoTag { return imageURL(p, "Logo", tag: t, maxWidth: maxWidth) }
        return nil
    }

    public func personImage(_ person: JSON, maxHeight: Int = 300) -> URL? {
        guard let tag = person["PrimaryImageTag"].string, let id = person["Id"].string else { return nil }
        return imageURL(id, "Primary", tag: tag, maxHeight: maxHeight)
    }

    public func userImage(userId: String, tag: String) -> URL {
        url("/Users/\(userId)/Images/Primary", [("tag", tag), ("maxHeight", 300)])
    }

    // MARK: Playback

    /// What Apple TV 4K's own player (AVPlayer) can play, so Jellyfin sends the original file
    /// when it can, remuxes (repackages without re-encoding) when only the container is the
    /// problem, and converts only the audio when the soundtrack is DTS or TrueHD.
    public static func appleTVProfile(maxBitrate: Int?) -> JSON {
        let rate = maxBitrate ?? 200_000_000
        let transcode = maxBitrate != nil
        let direct: JSON = transcode ? [] : [
            ["Type": "Video", "Container": "mp4,m4v,mov",
             "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,alac,flac,mp3"],
            ["Type": "Audio", "Container": "mp3,aac,m4a,m4b,flac,alac,wav"],
        ]
        let hls: JSON = transcode
            ? ["Type": "Video", "Container": "ts", "Protocol": "hls", "Context": "Streaming",
               "VideoCodec": "h264", "AudioCodec": "aac,ac3,eac3", "MaxAudioChannels": "6",
               "MinSegments": 1, "BreakOnNonKeyFrames": true]
            : ["Type": "Video", "Container": "mp4", "Protocol": "hls", "Context": "Streaming",
               "VideoCodec": "hevc,h264", "AudioCodec": "eac3,ac3,aac,alac,flac", "MaxAudioChannels": "8",
               "MinSegments": 2, "BreakOnNonKeyFrames": true]
        return [
            "Name": "Ember for Apple TV",
            "MaxStreamingBitrate": .number(Double(rate)),
            "MaxStaticBitrate": .number(Double(rate)),
            "MusicStreamingTranscodingBitrate": 384000,
            "DirectPlayProfiles": direct,
            "TranscodingProfiles": [
                hls,
                ["Type": "Audio", "Container": "aac", "Protocol": "hls", "Context": "Streaming",
                 "AudioCodec": "aac", "MaxAudioChannels": "6"],
            ],
            "ContainerProfiles": [],
            "CodecProfiles": [
                // Apple TV decodes 10-bit HEVC (HDR10, Dolby Vision 5 and 8.1) but not 10-bit H.264.
                ["Type": "Video", "Codec": "h264",
                 "Conditions": [["Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": false]]],
            ],
            "SubtitleProfiles": [
                ["Format": "vtt", "Method": "Hls"],
                ["Format": "mov_text", "Method": "Embed"],
                ["Format": "pgssub", "Method": "Encode"],
                ["Format": "dvdsub", "Method": "Encode"],
                ["Format": "dvbsub", "Method": "Encode"],
            ],
        ]
    }

    /// Asks the server how to play `itemId`. `maxBitrate` nil = best quality.
    public func playbackSource(_ itemId: String, maxBitrate: Int? = nil, audioStreamIndex: Int? = nil,
                               subtitleStreamIndex: Int? = nil) async throws -> PlaybackSource {
        let transcode = maxBitrate != nil
        let body: JSON = JSON.object([
            "UserId": JSON(userId),
            "MaxStreamingBitrate": .number(Double(maxBitrate ?? 200_000_000)),
            "AudioStreamIndex": JSON(audioStreamIndex),
            "SubtitleStreamIndex": JSON(subtitleStreamIndex),
            "EnableDirectPlay": .bool(!transcode),
            "EnableDirectStream": .bool(!transcode),
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": .bool(!transcode),
            "AllowAudioStreamCopy": .bool(!transcode),
            "AutoOpenLiveStream": true,
            "DeviceProfile": Self.appleTVProfile(maxBitrate: maxBitrate),
        ]).compacted

        let json = try await send("POST", "/Items/\(itemId)/PlaybackInfo", query: [("userId", userId)], body: body)
        guard let src = json["MediaSources"].list.first else {
            if let err = json["ErrorCode"].string { throw APIError(500, "The server can't play this title (\(err)).") }
            throw APIError(500, "The server has no playable version of this title.")
        }
        let playSessionId = json["PlaySessionId"].string ?? ""
        let msid = src["Id"].string ?? itemId
        let url: URL
        let method: String
        if let t = src["TranscodingUrl"].string, !t.isEmpty, let u = URL(string: baseURL + t) {
            // An HLS stream from the server. It still copies the picture untouched when it can
            // (remux) and only re-encodes what Apple TV can't play.
            url = u
            method = "Transcode"
        } else {
            url = self.url("/Videos/\(itemId)/stream", [
                ("static", true), ("mediaSourceId", msid), ("playSessionId", playSessionId),
                ("deviceId", deviceId), ("api_key", token),
            ])
            method = "DirectPlay"
        }
        return PlaybackSource(
            url: url, mediaSourceId: msid, playSessionId: playSessionId, playMethod: method,
            streams: src["MediaStreams"].list, bitrate: src["Bitrate"].int,
            defaultAudioIndex: src["DefaultAudioStreamIndex"].int,
            defaultSubtitleIndex: src["DefaultSubtitleStreamIndex"].int)
    }

    /// The original file, untouched (used for local trailers and previews).
    public func staticStreamURL(itemId: String) -> URL {
        url("/Videos/\(itemId)/stream", [("static", true), ("deviceId", deviceId), ("api_key", token)])
    }

    /// Makes sure a server stream address carries the sign-in token (AVPlayer can't add headers).
    public func authorized(_ url: URL) -> URL {
        let s = url.absoluteString
        if s.lowercased().contains("api_key=") || s.contains("ApiKey=") { return url }
        guard let token else { return url }
        return URL(string: s + (s.contains("?") ? "&" : "?") + "api_key=" + token) ?? url
    }

    public func reportStart(_ s: PlaybackSource, itemId: String, position: Double) async {
        await report("/Sessions/Playing", s, itemId: itemId, position: position, paused: false)
    }

    public func reportProgress(_ s: PlaybackSource, itemId: String, position: Double, paused: Bool) async {
        await report("/Sessions/Playing/Progress", s, itemId: itemId, position: position, paused: paused)
    }

    public func reportStopped(_ s: PlaybackSource, itemId: String, position: Double) async {
        await report("/Sessions/Playing/Stopped", s, itemId: itemId, position: position, paused: false)
    }

    private func report(_ path: String, _ s: PlaybackSource, itemId: String, position: Double, paused: Bool) async {
        // Progress reporting never interrupts playback.
        _ = try? await send("POST", path, body: [
            "ItemId": .string(itemId), "MediaSourceId": .string(s.mediaSourceId),
            "PlaySessionId": .string(s.playSessionId), "PositionTicks": JSON(Ticks.from(seconds: position)),
            "IsPaused": .bool(paused), "CanSeek": true, "PlayMethod": .string(s.playMethod),
        ])
    }

    /// Intro / outro markers (Jellyfin 10.10+, filled by e.g. the Intro Skipper plugin).
    public func mediaSegments(_ itemId: String) async -> [MediaSegment] {
        guard let json = try? await send("GET", "/MediaSegments/\(itemId)") else { return [] }
        return items(json).compactMap { e in
            guard let s = e.raw["StartTicks"].int64, let t = e.raw["EndTicks"].int64 else { return nil }
            return MediaSegment(type: e.raw["Type"].string ?? "", start: Ticks.seconds(s), end: Ticks.seconds(t))
        }
    }

    // MARK: Ember Trailers plugin

    /// Trailer service status, or nil when the plugin isn't installed or reachable.
    public func trailerHealth() async -> JSON? {
        try? await send("GET", "/EmberTrailers/Health", timeout: 15)
    }

    /// The trailer key the server can stream for a library item, or nil plus the server's reason.
    public func trailerCheck(itemId: String) async -> (key: String?, reason: String?) {
        do {
            let json = try await send("GET", "/EmberTrailers/Items/\(itemId)/Info", timeout: 90)
            if json["available"].isTrue { return (json["key"].string, nil) }
            return (nil, json["reason"].string ?? "The server couldn't play this trailer.")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Checks a YouTube trailer (for titles not on the server). Returns the key if playable.
    public func trailerKeyChecked(_ key: String) async -> String? {
        (try? await send("GET", "/EmberTrailers/Videos/\(key)/Info", timeout: 60))?["available"].isTrue == true ? key : nil
    }

    public func trailerStreamURL(_ key: String) -> URL {
        url("/EmberTrailers/Videos/\(key)/Stream", [("api_key", token)])
    }

    /// The release calendar built by the Ember plugin. Nil when the plugin is missing or too old.
    public func releaseCalendar(region: String, days: Int = 120) async throws -> [JSON]? {
        do {
            return try await send("GET", "/EmberTrailers/Calendar", query: [("region", region), ("days", days)], timeout: 90)["items"].array
        } catch let e as APIError where e.status == 404 {
            return nil
        }
    }
}

/// YouTube video key from a trailer link, or nil.
public func youtubeKey(_ link: String?) -> String? {
    guard let link, let u = URLComponents(string: link), let host = u.host?.lowercased() else { return nil }
    if host.contains("youtu.be") { return u.path.split(separator: "/").first.map(String.init) }
    if host.contains("youtube") { return u.queryItems?.first { $0.name == "v" }?.value }
    return nil
}
