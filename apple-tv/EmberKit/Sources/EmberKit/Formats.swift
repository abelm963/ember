import Foundation

/// What a file contains, in the terms people know: 4K, Dolby Vision, HDR10, Atmos, DTS:X…
public struct FormatInfo: Equatable, Sendable {
    public let badges: [String]
    /// "Dolby Vision", "HDR10+", "HDR10", "HLG" or "SDR".
    public let videoRange: String?
    public let isHDR: Bool
    public let isDolbyVision: Bool

    public init(streams: [JSON]) {
        var badges: [String] = []
        var range: String?
        var hdr = false, dv = false
        if let v = streams.first(where: { $0["Type"].string == "Video" }) {
            let w = v["Width"].int ?? 0, h = v["Height"].int ?? 0
            if w >= 3200 || h >= 2000 { badges.append("4K") } else if w >= 1800 || h >= 1000 { badges.append("HD") }
            let rt = (v["VideoRangeType"].string ?? v["VideoRange"].string ?? "").uppercased()
            if rt.contains("DOVI") {
                dv = true; hdr = true; range = "Dolby Vision"
                badges.append("Dolby Vision")
                if rt.contains("HDR10PLUS") { badges.append("HDR10+") } else if rt.contains("HDR10") { badges.append("HDR10") }
            } else if rt.contains("HDR10PLUS") {
                hdr = true; range = "HDR10+"; badges.append("HDR10+")
            } else if rt.contains("HDR") {
                hdr = true; range = "HDR10"; badges.append("HDR10")
            } else if rt.contains("HLG") {
                hdr = true; range = "HLG"; badges.append("HLG")
            } else {
                range = "SDR"
            }
        }
        // Best audio format across all tracks.
        var atmos = false, dtsx = false, dtshd = false, truehd = false, ddp = false, dts = false
        var maxCh = 0
        for a in streams where a["Type"].string == "Audio" {
            let codec = (a["Codec"].string ?? "").lowercased()
            let prof = [a["Profile"].string, a["DisplayTitle"].string, a["Title"].string]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            maxCh = max(maxCh, a["Channels"].int ?? 0)
            if prof.contains("atmos") { atmos = true }
            if prof.contains("dts:x") || prof.contains("dts-x") || prof.contains("dts x") { dtsx = true }
            if codec == "dts" && (prof.contains("ma") || prof.contains("hd")) { dtshd = true }
            if codec == "dts" { dts = true }
            if codec == "truehd" { truehd = true }
            if codec == "eac3" { ddp = true }
        }
        if atmos { badges.append("Dolby Atmos") }
        else if dtsx { badges.append("DTS:X") }
        else if dtshd { badges.append("DTS-HD MA") }
        else if truehd { badges.append("Dolby TrueHD") }
        else if ddp { badges.append("Dolby Digital+") }
        else if dts { badges.append("DTS") }
        if maxCh >= 8 { badges.append("7.1") } else if maxCh >= 6 { badges.append("5.1") }
        self.badges = badges
        self.videoRange = range
        self.isHDR = hdr
        self.isDolbyVision = dv
    }

    /// "4K · HDR" style badge for the metadata line.
    public var videoBadge: String? {
        let video = badges.filter { ["4K", "HD", "Dolby Vision", "HDR10", "HDR10+", "HLG"].contains($0) }.prefix(2)
        if video.isEmpty { return nil }
        return video.map { $0 == "HDR10" ? "HDR" : $0 }.joined(separator: " · ")
    }
}

/// Human-friendly text shared by every screen.
public enum Labels {
    /// "1h 52m", "48m".
    public static func runtime(seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// "38m left".
    public static func timeLeft(_ item: JFItem) -> String? {
        guard let rt = item.runtime, item.positionTicks > 0 else { return nil }
        let left = rt - Ticks.seconds(item.positionTicks)
        return left > 0 ? "\(runtime(seconds: left)) left" : nil
    }

    /// "Track 2 · English · 5.1" style label for an audio or subtitle stream.
    public static func streamLabel(_ s: JSON) -> String {
        if let t = s["DisplayTitle"].string, !t.isEmpty { return t }
        return [s["Language"].string, s["Codec"].string?.uppercased()].compactMap { $0 }.joined(separator: " · ")
    }
}
