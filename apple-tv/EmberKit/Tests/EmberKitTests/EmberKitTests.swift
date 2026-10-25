import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EmberKit

/// A fake server: answers by method + path, and records every request.
final class FakeServer: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body: String = ""
    }
    var routes: [String: (URLRequest) -> Reply] = [:]
    private(set) var log: [URLRequest] = []
    private let lock = NSLock()

    func on(_ method: String, _ path: String, _ reply: @escaping (URLRequest) -> Reply) {
        routes["\(method) \(path)"] = reply
    }

    func on(_ method: String, _ path: String, json: String, status: Int = 200, headers: [String: String] = [:]) {
        on(method, path) { _ in Reply(status: status, headers: headers, body: json) }
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        lock.lock(); log.append(request); lock.unlock()
        let path = request.url!.path
        guard let route = routes["\(request.httpMethod ?? "GET") \(path)"] else {
            return HTTPResult(status: 404, headers: [:], body: Data())
        }
        let r = route(request)
        return HTTPResult(status: r.status, headers: r.headers, body: Data(r.body.utf8))
    }

    var last: URLRequest? { lock.lock(); defer { lock.unlock() }; return log.last }

    func query(_ r: URLRequest?) -> [String: String] {
        var out: [String: String] = [:]
        for q in URLComponents(url: r!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[q.name] = q.value }
        return out
    }

    func body(_ r: URLRequest?) -> JSON { try! JSON.parse(r!.httpBody!) }
}

final class JSONTests: XCTestCase {
    func testParsesAndReads() throws {
        let j = try JSON.parse(Data(#"{"a":1,"b":true,"c":"x","d":[1,2],"e":{"f":null},"g":1.5}"#.utf8))
        XCTAssertEqual(j["a"].int, 1)
        XCTAssertEqual(j["b"].bool, true)
        XCTAssertNil(j["a"].bool, "numbers must not read as booleans")
        XCTAssertEqual(j["c"].string, "x")
        XCTAssertEqual(j["d"].list.count, 2)
        XCTAssertTrue(j["e"]["f"].isNull)
        XCTAssertTrue(j["missing"]["deeper"].isNull)
        XCTAssertEqual(j["g"].double, 1.5)
    }

    func testEncodesWholeNumbersWithoutDecimals() throws {
        let value: JSON = ["n": 5, "t": JSON(Int64(123_456_789_012))]
        let data = try value.encoded()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"n":5,"t":123456789012}"#)
    }
}

final class JellyfinTests: XCTestCase {
    func client(_ s: FakeServer) -> JellyfinClient {
        JellyfinClient(baseURL: "hearth:8096", deviceId: "dev1", deviceName: "Apple TV", token: "tok", userId: "u1", transport: s)
    }

    func testNormalizesPastedAddresses() {
        XCTAssertEqual(JellyfinClient.normalize("hearth:8096"), "http://hearth:8096")
        XCTAssertEqual(JellyfinClient.normalize(" https://media.example.ts.net/web/#/home "), "https://media.example.ts.net")
        XCTAssertEqual(JellyfinClient.normalize("https://x.net/jellyfin/web/index.html"), "https://x.net/jellyfin")
        XCTAssertEqual(JellyfinClient.normalize("http://10.0.0.5:8096///"), "http://10.0.0.5:8096")
    }

    func testAuthHeaderIsAscii() {
        let c = JellyfinClient(baseURL: "h", deviceId: "d", deviceName: "Abel’s \"TV\"", token: "t")
        XCTAssertEqual(c.authHeader, #"MediaBrowser Client="Ember", Device="Abel-s 'TV'", DeviceId="d", Version="0.1.0", Token="t""#)
    }

    func testSignInStoresToken() async throws {
        let s = FakeServer()
        s.on("POST", "/Users/AuthenticateByName", json: #"{"AccessToken":"new","User":{"Id":"u9","Name":"Abel","Policy":{"IsAdministrator":true}}}"#)
        let c = JellyfinClient(baseURL: "hearth:8096", deviceId: "d", deviceName: "n", transport: s)
        let r = try await c.authenticate(username: "Abel", password: "pw")
        XCTAssertEqual(r.token, "new")
        XCTAssertTrue(r.isAdmin)
        XCTAssertEqual(c.userId, "u9")
        XCTAssertEqual(s.body(s.last)["Pw"].string, "pw")
        XCTAssertTrue(c.authHeader.contains(#"Token="new""#))
    }

    func testWrongPasswordHasPlainMessage() async {
        let s = FakeServer()
        s.on("POST", "/Users/AuthenticateByName", json: "", status: 401)
        do {
            _ = try await client(s).authenticate(username: "a", password: "b")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That username or password isn't right.")
        }
    }

    func testQueryLeavesOutNilsAndJoinsLists() async throws {
        let s = FakeServer()
        s.on("GET", "/Items", json: #"{"Items":[{"Id":"m1","Name":"Dune","Type":"Movie"}]}"#)
        let items = try await client(s).items(types: ["Movie", "Series"], genre: nil, searchTerm: "dune part")
        XCTAssertEqual(items.map(\.name), ["Dune"])
        let q = s.query(s.last)
        XCTAssertEqual(q["includeItemTypes"], "Movie,Series")
        XCTAssertEqual(q["searchTerm"], "dune part")
        XCTAssertEqual(q["recursive"], "true")
        XCTAssertNil(q["genres"])
        XCTAssertNil(q["parentId"])
        XCTAssertTrue(s.last!.url!.absoluteString.contains("searchTerm=dune%20part"))
    }

    func testItemFieldsAndImages() throws {
        let raw = try JSON.parse(Data(#"""
        {"Id":"e1","Name":"Pilot","Type":"Episode","SeriesId":"s1","SeriesName":"Show","IndexNumber":4,
         "ParentIndexNumber":2,"RunTimeTicks":36000000000,"UserData":{"PlaybackPositionTicks":9000000000},
         "ImageTags":{"Primary":"p1"},"SeriesPrimaryImageTag":"sp","ParentLogoItemId":"s1","ParentLogoImageTag":"lg"}
        """#.utf8))
        let it = JFItem(raw)
        XCTAssertEqual(it.episodeLabel, "S2 : E4")
        XCTAssertEqual(it.progress!, 0.25, accuracy: 0.0001)
        XCTAssertEqual(it.resumeSeconds, 900)
        XCTAssertEqual(Labels.timeLeft(it), "45m left")
        let c = JellyfinClient(baseURL: "http://h", deviceId: "d", deviceName: "n")
        XCTAssertEqual(c.landscapeImage(it)?.absoluteString, "http://h/Items/e1/Images/Primary?quality=90&tag=p1&maxWidth=640")
        XCTAssertEqual(c.posterImage(it)?.absoluteString, "http://h/Items/s1/Images/Primary?quality=90&tag=sp&maxHeight=480")
        XCTAssertEqual(c.logoImage(it)?.absoluteString, "http://h/Items/s1/Images/Logo?quality=90&tag=lg&maxWidth=900")
        XCTAssertTrue(it.with(userData: "IsFavorite", true).isFavorite)
    }

    func testDirectPlayUsesStaticStream() async throws {
        let s = FakeServer()
        s.on("POST", "/Items/m1/PlaybackInfo",
             json: #"{"PlaySessionId":"ps","MediaSources":[{"Id":"ms","SupportsDirectPlay":true,"MediaStreams":[{"Type":"Audio","Index":1}],"DefaultAudioStreamIndex":1}]}"#)
        let src = try await client(s).playbackSource("m1")
        XCTAssertEqual(src.playMethod, "DirectPlay")
        XCTAssertEqual(src.defaultAudioIndex, 1)
        let q = s.query(URLRequest(url: src.url))
        XCTAssertEqual(src.url.path, "/Videos/m1/stream")
        XCTAssertEqual(q["static"], "true")
        XCTAssertEqual(q["api_key"], "tok")
        let body = s.body(s.last)
        XCTAssertEqual(body["EnableDirectPlay"].bool, true)
        XCTAssertTrue(body["AudioStreamIndex"].isNull, "nil values are left out")
        XCTAssertEqual(body["DeviceProfile"]["DirectPlayProfiles"][0]["Container"].string, "mp4,m4v,mov")
        XCTAssertEqual(body["DeviceProfile"]["TranscodingProfiles"][0]["Container"].string, "mp4")
    }

    func testRemuxUsesServerHLSAddress() async throws {
        let s = FakeServer()
        s.on("POST", "/Items/m2/PlaybackInfo",
             json: #"{"PlaySessionId":"ps","MediaSources":[{"Id":"ms","TranscodingUrl":"/videos/m2/master.m3u8?VideoCodec=hevc"}]}"#)
        let src = try await client(s).playbackSource("m2", audioStreamIndex: 3)
        XCTAssertEqual(src.url.absoluteString, "http://hearth:8096/videos/m2/master.m3u8?VideoCodec=hevc")
        XCTAssertEqual(src.playMethod, "Transcode")
        XCTAssertEqual(s.body(s.last)["AudioStreamIndex"].int, 3)
    }

    func testLowQualityAsksForH264() async throws {
        let s = FakeServer()
        s.on("POST", "/Items/m3/PlaybackInfo", json: #"{"MediaSources":[{"Id":"ms","TranscodingUrl":"/x.m3u8"}]}"#)
        _ = try await client(s).playbackSource("m3", maxBitrate: 4_000_000)
        let body = s.body(s.last)
        XCTAssertEqual(body["EnableDirectPlay"].bool, false)
        XCTAssertEqual(body["DeviceProfile"]["DirectPlayProfiles"].list.count, 0)
        XCTAssertEqual(body["DeviceProfile"]["TranscodingProfiles"][0]["VideoCodec"].string, "h264")
    }

    func testSegments() async {
        let s = FakeServer()
        s.on("GET", "/MediaSegments/e1", json: #"{"Items":[{"Type":"Intro","StartTicks":50000000,"EndTicks":900000000}]}"#)
        let segs = await client(s).mediaSegments("e1")
        XCTAssertEqual(segs, [MediaSegment(type: "Intro", start: 5, end: 90)])
        XCTAssertTrue(segs[0].contains(10))
        XCTAssertFalse(segs[0].contains(89.5))
    }

    func testFindByTmdbChecksIds() async throws {
        let s = FakeServer()
        s.on("GET", "/Items", json: #"{"Items":[{"Id":"a","ProviderIds":{"Tmdb":"1"}},{"Id":"b","ProviderIds":{"Tmdb":"438631"}}]}"#)
        let hit = try await client(s).find(tmdbId: "438631", mediaType: "movie", title: "Dune")
        XCTAssertEqual(hit?.id, "b")
    }

    func testYoutubeKey() {
        XCTAssertEqual(youtubeKey("https://www.youtube.com/watch?v=abc123"), "abc123")
        XCTAssertEqual(youtubeKey("https://youtu.be/xyz"), "xyz")
        XCTAssertNil(youtubeKey("https://vimeo.com/1"))
    }
}

final class SeerrTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(SeerrClient.normalize("seerr.example.ts.net/login"), "http://seerr.example.ts.net")
        XCTAssertEqual(SeerrClient.normalize("https://h.net/seerr/discover/movies?x=1"), "https://h.net/seerr")
        XCTAssertEqual(SeerrClient.normalize("http://h:5055/"), "http://h:5055")
    }

    func testSignInKeepsCookiesAndSendsThem() async throws {
        let s = FakeServer()
        s.on("POST", "/api/v1/auth/jellyfin", json: #"{"id":1}"#,
             headers: ["Set-Cookie": "connect.sid=s%3Aabc; Path=/; HttpOnly, XSRF-TOKEN=tok%2B1; Path=/"])
        s.on("GET", "/api/v1/auth/me", json: #"{"id":1,"permissions":18}"#)
        let c = SeerrClient(baseURL: "http://seerr:5055", transport: s)
        try await c.signInWithJellyfin(username: "a", password: "b")
        XCTAssertTrue(c.hasSession)
        let me = try await c.me()
        XCTAssertTrue(SeerrClient.canManageRequests(me))
        XCTAssertEqual(s.last?.value(forHTTPHeaderField: "Cookie"), "XSRF-TOKEN=tok%2B1; connect.sid=s%3Aabc")
        XCTAssertEqual(s.last?.value(forHTTPHeaderField: "X-XSRF-TOKEN"), "tok+1")
        // The cookie string survives a save and reload.
        let again = SeerrClient(baseURL: "http://seerr:5055", cookie: c.cookie, transport: s)
        XCTAssertTrue(again.hasSession)
    }

    func testReauthRetriesOnce() async throws {
        let s = FakeServer()
        var calls = 0
        s.on("GET", "/api/v1/request") { _ in
            calls += 1
            return calls == 1 ? .init(status: 401, body: #"{"message":"Unauthorized"}"#)
                : .init(body: #"{"results":[{"id":7,"status":2,"media":{"status":3,"mediaType":"movie","tmdbId":5}}]}"#)
        }
        let c = SeerrClient(baseURL: "http://seerr", cookie: "connect.sid=old", transport: s)
        c.reauth = { true }
        let list = try await c.requests()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(list.first?.label, "Approved · waiting for release")
    }

    func testRequestBodyForSeries() async throws {
        let s = FakeServer()
        s.on("POST", "/api/v1/request", json: "{}")
        let c = SeerrClient(baseURL: "http://seerr", apiKey: "k", transport: s)
        try await c.request(mediaType: "tv", tmdbId: 1399, seasons: [1, 2])
        let body = s.body(s.last)
        XCTAssertEqual(body["seasons"].list.compactMap(\.int), [1, 2])
        XCTAssertEqual(s.last?.value(forHTTPHeaderField: "X-Api-Key"), "k")
        try await c.request(mediaType: "movie", tmdbId: 5)
        XCTAssertTrue(s.body(s.last)["seasons"].isNull)
    }

    func testSearchEncodesSpacesAndDropsPeople() async throws {
        let s = FakeServer()
        s.on("GET", "/api/v1/search",
             json: #"{"results":[{"id":1,"mediaType":"movie","title":"A"},{"id":2,"mediaType":"person","name":"B"},{"id":3,"mediaType":"tv","name":"C","mediaInfo":{"status":5}}]}"#)
        let r = try await SeerrClient(baseURL: "http://seerr", transport: s).search("the bear")
        XCTAssertEqual(r.map(\.title), ["A", "C"])
        XCTAssertTrue(r[1].isAvailable)
        XCTAssertTrue(s.last!.url!.absoluteString.contains("query=the%20bear"))
    }

    func testDownloadProgress() throws {
        let r = SeerrRequest(try JSON.parse(Data(#"{"id":1,"status":2,"media":{"status":3,"downloadStatus":[{"size":100,"sizeLeft":25}]}}"#.utf8)))
        XCTAssertEqual(r.downloadProgress, 0.75)
        XCTAssertEqual(r.label, "Downloading")
        XCTAssertEqual(r.filterKey, "Approved")
    }
}

final class FormatTests: XCTestCase {
    func testBadges() throws {
        let streams = try JSON.parse(Data(#"""
        [{"Type":"Video","Width":3840,"Height":2160,"VideoRangeType":"DOVIWithHDR10"},
         {"Type":"Audio","Codec":"truehd","Profile":"Dolby TrueHD + Dolby Atmos","Channels":8}]
        """#.utf8)).list
        let f = FormatInfo(streams: streams)
        XCTAssertEqual(f.badges, ["4K", "Dolby Vision", "HDR10", "Dolby Atmos", "7.1"])
        XCTAssertTrue(f.isDolbyVision)
        XCTAssertEqual(f.videoBadge, "4K · Dolby Vision")
    }

    func testRuntime() {
        XCTAssertEqual(Labels.runtime(seconds: 6720), "1h 52m")
        XCTAssertEqual(Labels.runtime(seconds: 2880), "48m")
        XCTAssertEqual(Labels.runtime(seconds: 7200), "2h")
    }
}
