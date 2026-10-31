import Foundation
import AVFoundation

/// 保存先の直下にある m4a / mp3 を、埋め込んだアーティスト（＝チャンネル名）のフォルダへ移す。
/// 手でフォルダを統合したあとなど、直下に曲がたまったときの整理用。
enum ChannelSorter {
    struct Result {
        var moved = 0
        var channels: Set<String> = []
        var skippedNoArtist: [String] = []
        var skippedExists: [String] = []
        var failed: [String] = []

        var summary: String {
            var lines: [String] = []
            lines.append(moved == 0 ? "振り分けた曲はありません" : "\(moved) 曲を \(channels.count) 個のチャンネルフォルダに振り分けました")
            if !skippedNoArtist.isEmpty { lines.append("チャンネル名が入っていないので残した: \(skippedNoArtist.count) 曲") }
            if !skippedExists.isEmpty { lines.append("同じ名前のファイルが先にあるので残した: \(skippedExists.count) 曲") }
            if !failed.isEmpty { lines.append("移せなかった: \(failed.count) 曲") }
            return lines.joined(separator: "\n")
        }
    }

    /// 直下の音声ファイル
    static func rootAudioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { u in
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return !isDir && ["m4a", "mp3"].contains(u.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 埋め込んだアーティスト名（yt-dlp の --embed-metadata はチャンネル名を入れる）
    static func artist(of file: URL) async -> String? {
        let asset = AVURLAsset(url: file)
        guard let meta = try? await asset.load(.commonMetadata) else { return nil }
        for item in meta where item.commonKey == .commonKeyArtist {
            if let s = try? await item.load(.stringValue), !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return nil
    }

    /// yt-dlp の sanitize_filename と同じ置き換え。yt-dlp が作ったフォルダ名と一致させる
    static func folderName(for artist: String) -> String {
        let table: [Character: Character] = [
            "/": "⧸", "\\": "⧵", ":": "：", "|": "｜", "?": "？", "*": "＊", "\"": "＂", "<": "＜", ">": "＞",
        ]
        var s = String(artist.map { table[$0] ?? $0 }).trimmingCharacters(in: .whitespaces)
        while s.hasSuffix(".") { s.removeLast() }       // 末尾のピリオドも yt-dlp は落とす
        return s.isEmpty ? "その他" : s
    }

    static func run(folder: URL) async -> Result {
        var r = Result()
        let fm = FileManager.default
        for file in rootAudioFiles(in: folder) {
            guard let a = await artist(of: file) else { r.skippedNoArtist.append(file.lastPathComponent); continue }
            let dir = folder.appendingPathComponent(folderName(for: a), isDirectory: true)
            let dest = dir.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { r.skippedExists.append(file.lastPathComponent); continue }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.moveItem(at: file, to: dest)
                for ext in ["jpg", "jpeg", "png"] {     // 残してあるカバー画像も一緒に
                    let side = file.deletingPathExtension().appendingPathExtension(ext)
                    if fm.fileExists(atPath: side.path) {
                        try? fm.moveItem(at: side, to: dir.appendingPathComponent(side.lastPathComponent))
                    }
                }
                r.moved += 1
                r.channels.insert(dir.lastPathComponent)
            } catch {
                r.failed.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return r
    }
}
