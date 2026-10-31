import Foundation

/// YouTube の検索結果の 1 件（yt-dlp の ytsearch から）
struct SearchResult: Identifiable, Equatable {
    let id: String           // 動画 ID
    let title: String
    let channel: String?
    let duration: Int?       // 秒
    let viewCount: Int?

    var url: String { "https://www.youtube.com/watch?v=\(id)" }
    var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }

    /// 「3:29 ・ 16.5万回」のような補足
    var detail: String {
        var parts: [String] = []
        if let d = duration { parts.append(Self.formatDuration(d)) }
        if let v = viewCount { parts.append(Self.formatViews(v)) }
        return parts.joined(separator: " ・ ")
    }

    static func formatDuration(_ s: Int) -> String {
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    static func formatViews(_ v: Int) -> String {
        if v >= 100_000_000 { return String(format: "%.1f億回", Double(v) / 100_000_000) }
        if v >= 10_000 { return String(format: "%.1f万回", Double(v) / 10_000) }
        return "\(v)回"
    }

    /// yt-dlp の --print（タブ区切り: id, title, channel, duration, view_count）の 1 行から
    init?(line: Substring) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5, !f[0].isEmpty else { return nil }
        id = f[0]
        title = f[1].isEmpty ? f[0] : f[1]
        channel = (f[2].isEmpty || f[2] == "NA") ? nil : f[2]
        duration = Int(f[3])
        viewCount = Int(f[4])
    }

    /// yt-dlp に渡す引数。`ytsearchN:語` で YouTube を検索し、1 件 1 行で出す
    static func arguments(query: String, count: Int) -> [String] {
        [
            "--no-update", "--no-warnings", "--no-colors",
            "--flat-playlist", "--skip-download",
            "--print", "%(id)s\t%(title)s\t%(channel,uploader|)s\t%(duration|)s\t%(view_count|)s",
            "--", "ytsearch\(count):\(query)",
        ]
    }
}
