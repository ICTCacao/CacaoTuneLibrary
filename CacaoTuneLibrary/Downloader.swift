import Foundation
import AppKit

/// yt-dlp を外部プロセスとして動かし、出力を読んで進み具合をジョブに反映する。
final class Downloader {
    struct Options {
        var folder: URL
        var format: AudioFormat
        var coverMode: CoverMode
        var wholePlaylist: Bool
        var idInFilename: Bool
        var channelFolders: Bool
        var ytdlp: URL
        var ffmpegDir: URL
    }

    private var process: Process?
    private var buffer = Data()

    /// 中央を正方形に切り抜く yt-dlp の後処理引数（README の例と同じ）
    static let squareCropPPA = "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\""
    /// 幅はそのまま、上下を同じ画像のぼかしで埋めて正方形にする
    static let squarePadPPA = "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf \"split[o][b];[b]scale='max(iw,ih)':'max(iw,ih)',gblur=sigma=40,eq=brightness=-0.08[bg];[bg][o]overlay=(W-w)/2:(H-h)/2\""

    static func arguments(for url: String, options o: Options) -> [String] {
        var a: [String] = [
            "--no-update",                 // 更新の案内は設定画面から行うので黙らせる
            "--no-colors", "--newline", "--progress",
            "--no-simulate",
            "--print", "before_dl:TITLE\t%(title)s",
            "--print", "before_dl:UPLOADER\t%(uploader,channel)s",
            "--print", "before_dl:ITEM\t%(playlist_index|)s\t%(playlist_count|)s\t%(playlist_title|)s",
            "--print", "after_move:FILE\t%(filepath)s",
            "--no-write-playlist-metafiles",   // 再生リスト自体のサムネイルは書かない
            "-x", "--audio-format", o.format.rawValue,
            "--embed-metadata", "--embed-thumbnail",
            "--write-thumbnail", "--convert-thumbnails", "jpg",
            "--ffmpeg-location", o.ffmpegDir.path,
            "-o", o.folder.path + "/"
                + (o.channelFolders ? "%(uploader,channel|その他)s/" : "")   // チャンネル名のフォルダ（yt-dlp が使えない文字を直す）
                + (o.idInFilename ? "%(title)s [%(id)s].%(ext)s" : "%(title)s.%(ext)s"),
        ]
        if o.format == .mp3 { a += ["--audio-quality", "0"] }
        switch o.coverMode {
        case .pad: a += ["--ppa", squarePadPPA]
        case .crop: a += ["--ppa", squareCropPPA]
        case .none: break
        }
        a.append(o.wholePlaylist ? "--yes-playlist" : "--no-playlist")
        a.append("--")
        a.append(url)
        return a
    }

    /// 完了したら completion（成功なら nil、失敗ならメッセージ）。進み具合は job を直接更新する（メインスレッドで）。
    func start(job: DownloadJob, options: Options, completion: @escaping (String?) -> Void) {
        let p = Process()
        p.executableURL = options.ytdlp
        p.arguments = Self.arguments(for: job.url, options: options)
        p.environment = Tools.environment
        p.currentDirectoryURL = options.folder
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        process = p
        buffer = Data()

        var lastError: String?
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty { return }
            self.buffer.append(d)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer[self.buffer.startIndex..<nl]
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                let line = String(decoding: lineData, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
                DispatchQueue.main.async {
                    if let e = Self.apply(line: line, to: job, options: options) { lastError = e }
                }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            DispatchQueue.main.async {
                if !rest.isEmpty {
                    for line in String(decoding: rest, as: UTF8.self).split(separator: "\n") {
                        if let e = Self.apply(line: String(line), to: job, options: options) { lastError = e }
                    }
                }
                if reason == .uncaughtSignal {
                    completion("中止")
                } else if status == 0 {
                    completion(nil)
                } else {
                    completion(lastError ?? "yt-dlp が終了コード \(status) で終わりました")
                }
            }
        }
        do {
            try p.run()
            DispatchQueue.main.async { job.state = .running("準備中") }
        } catch {
            completion("yt-dlp を起動できません: \(error.localizedDescription)")
        }
    }

    func cancel() {
        process?.terminate()
    }

    private static let percentRegex = try! NSRegularExpression(pattern: #"^\[download\]\s+([\d.]+)%"#)

    /// 1 行を解釈してジョブに反映。ERROR 行ならそのメッセージを返す。
    @discardableResult
    static func apply(line: String, to job: DownloadJob, options: Options) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        job.log.append(t)
        if job.log.count > 400 { job.log.removeFirst(job.log.count - 400) }

        if t.hasPrefix("TITLE\t") {
            job.title = String(t.dropFirst(6))
            job.progress = 0
            job.state = .running("取得中")
        } else if t.hasPrefix("UPLOADER\t") {
            let u = String(t.dropFirst(9))
            job.uploader = (u == "NA" || u.isEmpty) ? nil : u
        } else if t.hasPrefix("ITEM\t") {
            let parts = t.dropFirst(5).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            job.itemIndex = parts.count > 0 ? Int(parts[0]) : nil
            job.itemCount = parts.count > 1 ? Int(parts[1]) : nil
            if parts.count > 2, !parts[2].isEmpty { job.playlistTitle = parts[2] }
        } else if t.hasPrefix("FILE\t") {
            let url = URL(fileURLWithPath: String(t.dropFirst(5)))
            job.files.append(url)
            job.progress = 1
            job.state = .running("保存中")
        } else if let m = percentRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r = Range(m.range(at: 1), in: t), let v = Double(t[r]) {
            job.progress = min(1, v / 100)
            job.state = .running("取得中")
        } else if t.hasPrefix("[download]"), t.contains("already been downloaded") {
            job.progress = 1
            job.state = .running("すでに保存済み")
        } else if t.hasPrefix("[ExtractAudio]") {
            job.state = .running(options.format == .mp3 ? "mp3 に変換中" : "音声を取り出し中")
        } else if t.hasPrefix("[ThumbnailsConvertor]") {
            job.state = .running("カバー画像を整え中")
        } else if t.hasPrefix("[EmbedThumbnail]") {
            job.state = .running("カバーを埋め込み中")
        } else if t.hasPrefix("[Metadata]") {
            job.state = .running("曲情報を書き込み中")
        } else if t.hasPrefix("ERROR:") {
            // 再生リストでは、1 曲が失敗しても yt-dlp は次の曲に進む。数えておいて最後にまとめて見せる
            let msg = humanize(String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            job.errorCount += 1
            job.lastError = msg
            return msg
        }
        return nil
    }

    /// yt-dlp のエラーを日本語の短い言葉に
    static func humanize(_ msg: String) -> String {
        let m = msg.lowercased()
        if m.contains("is not a valid url") || m.contains("unsupported url") { return "URL として読めません" }
        if m.contains("video unavailable") || m.contains("private video") { return "この動画は見られません（非公開・削除など）" }
        if m.contains("sign in") || m.contains("age") && m.contains("confirm") { return "ログインが必要な動画です" }
        if m.contains("ffmpeg") || m.contains("ffprobe") { return "ffmpeg が見つかりません（設定の「道具を用意する」を押してください）" }
        if m.contains("unable to download") || m.contains("network") || m.contains("resolve") { return "ネットワークにつながりません" }
        if m.contains("requested format is not available") { return "音声の形式が取り出せません（yt-dlp を更新すると直ることが多い）" }
        if m.contains("nsig") || m.contains("signature") || m.contains("player") { return "YouTube 側が変わりました（yt-dlp を更新してください）" }
        return msg.count > 120 ? String(msg.prefix(120)) + "…" : msg
    }
}
