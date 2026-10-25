import Foundation

/// Jellyfin counts time in "ticks": 10 million per second.
public enum Ticks {
    public static let perSecond: Double = 10_000_000
    public static func seconds(_ ticks: Int64) -> Double { Double(ticks) / perSecond }
    public static func from(seconds: Double) -> Int64 { Int64((seconds * perSecond).rounded()) }
}

/// A Jellyfin item (movie, series, season, episode, library…). Wraps the raw JSON.
public struct JFItem: Identifiable, Hashable, Sendable {
    public let raw: JSON
    public init(_ raw: JSON) { self.raw = raw }

    public static func == (a: JFItem, b: JFItem) -> Bool { a.id == b.id && a.raw == b.raw }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public var id: String { raw["Id"].string ?? "" }
    public var name: String { raw["Name"].string ?? "" }
    public var type: String { raw["Type"].string ?? "" }
    public var isSeries: Bool { type == "Series" }
    public var isEpisode: Bool { type == "Episode" }
    public var isMovie: Bool { type == "Movie" }
    public var isSeason: Bool { type == "Season" }
    public var overview: String? { raw["Overview"].string }
    public var year: Int? { raw["ProductionYear"].int }
    public var officialRating: String? { raw["OfficialRating"].string }
    public var communityRating: Double? { raw["CommunityRating"].double }
    public var runTimeTicks: Int64? { raw["RunTimeTicks"].int64 }
    /// Length in seconds.
    public var runtime: Double? { runTimeTicks.map(Ticks.seconds) }
    public var genres: [String] { raw["Genres"].list.compactMap(\.string) }
    public var collectionType: String? { raw["CollectionType"].string }
    public var status: String? { raw["Status"].string }

    public var userData: JSON { raw["UserData"] }
    public var positionTicks: Int64 { userData["PlaybackPositionTicks"].int64 ?? 0 }
    public var played: Bool { userData["Played"].isTrue }
    public var isFavorite: Bool { userData["IsFavorite"].isTrue }
    public var unplayedCount: Int? { userData["UnplayedItemCount"].int }

    public var seriesId: String? { raw["SeriesId"].string }
    public var seriesName: String? { raw["SeriesName"].string }
    public var seasonId: String? { raw["SeasonId"].string }
    public var indexNumber: Int? { raw["IndexNumber"].int }
    public var parentIndexNumber: Int? { raw["ParentIndexNumber"].int }
    public var childCount: Int? { raw["ChildCount"].int }
    public var premiereDate: Date? { raw["PremiereDate"].string.flatMap(DateParsing.iso) }

    public var imageTags: [String: String] { raw["ImageTags"].object?.compactMapValues(\.string) ?? [:] }
    public var backdropTags: [String] { raw["BackdropImageTags"].list.compactMap(\.string) }
    public var parentBackdropTags: [String] { raw["ParentBackdropImageTags"].list.compactMap(\.string) }
    public var parentBackdropItemId: String? { raw["ParentBackdropItemId"].string }
    public var parentThumbItemId: String? { raw["ParentThumbItemId"].string }
    public var parentThumbTag: String? { raw["ParentThumbImageTag"].string }
    public var parentLogoItemId: String? { raw["ParentLogoItemId"].string }
    public var parentLogoTag: String? { raw["ParentLogoImageTag"].string }
    public var seriesPrimaryTag: String? { raw["SeriesPrimaryImageTag"].string }

    public var providerIds: [String: String] { raw["ProviderIds"].object?.compactMapValues(\.text) ?? [:] }
    public var tmdbId: String? { providerIds["Tmdb"] }

    public var people: [JSON] { raw["People"].list }
    public var mediaSources: [JSON] { raw["MediaSources"].list }
    public var remoteTrailers: [JSON] { raw["RemoteTrailers"].list }
    public var localTrailerCount: Int { raw["LocalTrailerCount"].int ?? 0 }

    /// Video, audio and subtitle streams of the main version of this file.
    public var mediaStreams: [JSON] {
        if let direct = raw["MediaStreams"].array { return direct }
        return mediaSources.first?["MediaStreams"].list ?? []
    }

    /// "S2 : E4" style label for episodes.
    public var episodeLabel: String {
        let s = parentIndexNumber, e = indexNumber
        if s == nil && e == nil { return "" }
        return "S\(s.map(String.init) ?? "?") : E\(e.map(String.init) ?? "?")"
    }

    /// Resume progress 0…1, or nil when not started.
    public var progress: Double? {
        guard let rt = runTimeTicks, rt > 0, positionTicks > 0 else { return nil }
        return min(max(Double(positionTicks) / Double(rt), 0), 1)
    }

    /// Seconds to resume from, or nil to start at the beginning.
    public var resumeSeconds: Double? { positionTicks > 0 ? Ticks.seconds(positionTicks) : nil }

    /// A copy with changed user data (after marking played or adding to My List).
    public func with(userData key: String, _ value: JSON) -> JFItem {
        var r = raw
        var ud = r["UserData"]
        if ud.isNull { ud = [:] }
        ud.set(key, value)
        r.set("UserData", ud)
        return JFItem(r)
    }
}

public struct AuthResult: Sendable {
    public let token: String
    public let user: JSON
    public var userId: String { user["Id"].string ?? "" }
    public var userName: String { user["Name"].string ?? "" }
    public var isAdmin: Bool { user["Policy"]["IsAdministrator"].isTrue }
    public var primaryImageTag: String? { user["PrimaryImageTag"].string }
}

/// A public user shown on the sign-in screen.
public struct PublicUser: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let imageTag: String?
    public let hasPassword: Bool
}

/// How to play one item, as agreed with the server.
public struct PlaybackSource: Sendable {
    public let url: URL
    public let mediaSourceId: String
    public let playSessionId: String
    /// "DirectPlay", "DirectStream" (remux, no quality loss) or "Transcode".
    public let playMethod: String
    public let streams: [JSON]
    public let bitrate: Int?
    public var audioStreams: [JSON] { streams.filter { $0["Type"].string == "Audio" } }
    public var subtitleStreams: [JSON] { streams.filter { $0["Type"].string == "Subtitle" } }
    public var defaultAudioIndex: Int?
    public var defaultSubtitleIndex: Int?
}

/// An intro, outro, recap… marker (Jellyfin 10.10+ media segments).
public struct MediaSegment: Sendable, Equatable {
    public let type: String
    public let start: Double
    public let end: Double
    public init(type: String, start: Double, end: Double) {
        self.type = type
        self.start = start
        self.end = end
    }
    public func contains(_ t: Double) -> Bool { t >= start && t < end - 1 }
}

enum DateParsing {
    static func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Jellyfin sometimes sends 7 fractional digits; trim to 3.
        if let dot = s.firstIndex(of: ".") {
            let tail = s[s.index(after: dot)...]
            let digits = tail.prefix { $0.isNumber }
            let rest = tail.dropFirst(digits.count)
            let fixed = s[..<dot] + "." + digits.prefix(3) + (rest.isEmpty ? "Z" : rest)
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: String(fixed))
        }
        return nil
    }
}
