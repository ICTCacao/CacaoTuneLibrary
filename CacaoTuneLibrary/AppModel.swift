import Foundation
import AppKit
import Observation

@Observable
final class AppModel {
    var jobs: [DownloadJob] = []
    var urlText = ""
    /// 見つかったツール。nil なら未インストール
    var ytdlp: URL?
    var ffmpeg: URL?
    var ytdlpVersion: String?

    private var downloader: Downloader?
    private var current: DownloadJob?
    /// 待機中の行に題名を出すための軽い問い合わせ（1 件ずつ・ダウンロードとは別に動く）
    private let prefetchQueue = DispatchQueue(label: "com.ictcacao.CacaoTuneLibrary.prefetch")

    init() {
        Prefs.migrateFromOldName()
        Prefs.registerDefaults()
        refreshTools()
    }

    // MARK: 設定の読み出し

    var folder: URL {
        URL(fileURLWithPath: UserDefaults.standard.string(forKey: Prefs.folder) ?? Prefs.defaultFolder.path, isDirectory: true)
    }
    var format: AudioFormat {
        AudioFormat(rawValue: UserDefaults.standard.string(forKey: Prefs.format) ?? "") ?? .m4a
    }
    var isBusy: Bool { current != nil }
    var toolsReady: Bool { ytdlp != nil && ffmpeg != nil }

    func refreshTools() {
        let d = UserDefaults.standard
        ytdlp = Tools.locate("yt-dlp", override: d.string(forKey: Prefs.ytdlpPath) ?? "")
        ffmpeg = Tools.locate("ffmpeg", override: d.string(forKey: Prefs.ffmpegPath) ?? "")
        ytdlpVersion = nil
        if let y = ytdlp {
            DispatchQueue.global().async {
                let r = Tools.run(y, ["--version"])
                DispatchQueue.main.async { self.ytdlpVersion = r.status == 0 ? r.output : nil }
            }
        }
    }

    // MARK: URL の追加

    /// 入力欄のテキストから URL を拾って追加（複数行・空白区切りも可）
    /// 入力欄の Return。URL なら追加、URL でない文字なら YouTube を検索する
    func addFromText() {
        let urls = Self.extractURLs(from: urlText)
        if urls.isEmpty {
            let q = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { urlText = ""; search(q) }
            return
        }
        urlText = ""
        for u in urls { enqueue(u) }
    }

    // MARK: 検索（yt-dlp の ytsearch）

    var searchQuery = ""
    var searchResults: [SearchResult] = []
    var isSearching = false
    var searchError: String?
    var showSearch = false
    private var searchCount = 20
    private var searchGeneration = 0

    /// 検索窓を開いて検索する（`more` なら同じ語で件数を増やす）
    func search(_ query: String, more: Bool = false) {
        guard let ytdlp else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if more { searchCount += 20 } else { searchCount = 20; searchResults = [] }
        searchQuery = q
        showSearch = true
        isSearching = true
        searchError = nil
        searchGeneration += 1
        let gen = searchGeneration
        let args = SearchResult.arguments(query: q, count: searchCount)
        prefetchQueue.async { [weak self] in
            let r = Tools.run(ytdlp, args, timeout: 60)
            let results = r.output.split(separator: "\n").compactMap(SearchResult.init(line:))
            DispatchQueue.main.async {
                guard let self, gen == self.searchGeneration else { return }
                self.isSearching = false
                if results.isEmpty {
                    self.searchError = r.status == 0 ? "見つかりませんでした" : Downloader.humanize(r.output.split(separator: "\n").last.map(String.init) ?? "検索できませんでした")
                } else {
                    self.searchResults = results
                }
            }
        }
    }

    /// 検索結果の 1 件を一覧に追加する。題名などは分かっているので先に入れておく
    func add(result: SearchResult) {
        enqueue(result.url)
        if let job = jobs.first(where: { $0.url == result.url }) {
            if job.title == nil { job.title = result.title }
            if job.uploader == nil { job.uploader = result.channel }
        }
    }
    /// もう一覧に入っているか（検索結果に「追加済み」を出す）
    func isQueued(_ result: SearchResult) -> Bool {
        jobs.contains(where: { $0.url == result.url })
    }

    func addFromClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        for u in Self.extractURLs(from: s) { enqueue(u) }
    }

    func add(urls: [String]) {
        for u in urls { for x in Self.extractURLs(from: u) { enqueue(x) } }
    }

    static func extractURLs(from text: String) -> [String] {
        var found: [String] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            var s = String(raw)
            if !s.contains("://") {
                if s.hasPrefix("youtu.be/") || s.hasPrefix("www.youtube.com/") || s.hasPrefix("youtube.com/") || s.hasPrefix("music.youtube.com/") {
                    s = "https://" + s
                } else { continue }
            }
            if URL(string: s) != nil, !found.contains(s) { found.append(s) }
        }
        return found
    }

    private func enqueue(_ url: String) {
        if jobs.contains(where: { $0.url == url && $0.isActive }) { return }
        let job = DownloadJob(url: url)
        jobs.insert(job, at: 0)   // 新しいものを上に
        prefetch(job)
        pump()
    }

    // MARK: 題名の先読み

    /// 追加した直後に yt-dlp で題名・チャンネル名・サムネイルだけ取ってくる（1〜2 秒）。本番の取得が先に始まっていたら、そちらを優先する
    private func prefetch(_ job: DownloadJob) {
        guard let ytdlp else { return }
        let whole = UserDefaults.standard.bool(forKey: Prefs.wholePlaylist)
        let args: [String] = [
            "--no-update", "--no-warnings", "--no-colors",
            "--flat-playlist", "--skip-download", "-I", "1",
            whole ? "--yes-playlist" : "--no-playlist",
            "--print", "%(playlist_title|)s\t%(title)s\t%(playlist_channel,playlist_uploader,channel,uploader|)s\t%(thumbnail|)s\t%(id|)s",
            "--", job.url,
        ]
        prefetchQueue.async { [weak self] in
            let r = Tools.run(ytdlp, args, timeout: 30)
            guard r.status == 0, let line = r.output.split(separator: "\n").first else { return }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { return }
            let playlistTitle = f[0].isEmpty ? nil : f[0]
            let title = f[1]
            let uploader = (f[2].isEmpty || f[2] == "NA") ? nil : f[2]
            let thumb = !f[3].isEmpty ? f[3] : (f[4].isEmpty ? "" : "https://i.ytimg.com/vi/\(f[4])/hqdefault.jpg")
            DispatchQueue.main.async {
                guard let self, self.jobs.contains(where: { $0 === job }) else { return }
                if job.playlistTitle == nil { job.playlistTitle = playlistTitle }
                if job.title == nil { job.title = title }
                if job.uploader == nil { job.uploader = uploader }
            }
            guard let u = URL(string: thumb) else { return }
            URLSession.shared.dataTask(with: u) { data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    if job.thumbnail == nil { job.thumbnail = img }
                }
            }.resume()
        }
    }

    // MARK: 実行（1 件ずつ）

    private func pump() {
        guard current == nil, toolsReady, let ytdlp, let ffmpeg else { return }
        // 一覧は新しい順なので、いちばん下（先に追加したもの）から処理する
        guard let job = jobs.last(where: { $0.state == .waiting }) else { return }
        let d = UserDefaults.standard
        let folder = self.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            job.state = .failed("保存先フォルダを作れません: \(folder.path)")
            pump()
            return
        }
        let opts = Downloader.Options(
            folder: folder,
            format: format,
            coverMode: CoverMode(rawValue: d.string(forKey: Prefs.coverMode) ?? "") ?? .pad,
            wholePlaylist: d.bool(forKey: Prefs.wholePlaylist),
            idInFilename: d.bool(forKey: Prefs.idInFilename),
            channelFolders: d.bool(forKey: Prefs.channelFolders),
            ytdlp: ytdlp,
            ffmpegDir: ffmpeg.deletingLastPathComponent())
        let dl = Downloader()
        downloader = dl
        current = job
        job.state = .running("準備中")
        dl.start(job: job, options: opts) { [weak self] error in
            guard let self else { return }
            if error == "中止" {
                job.state = .cancelled
            } else if job.files.isEmpty {
                job.state = .failed(error ?? "ファイルができませんでした")
            } else {
                // 再生リストの一部が失敗していても、できた曲ぶんは仕上げて「完了」にする（失敗数は行に出す）
                self.finish(job)
                job.state = .done
            }
            self.current = nil
            self.downloader = nil
            self.pump()
        }
    }

    /// できあがったファイルごとに、カバー画像を Finder アイコンにして、jpg を片づける
    private func finish(_ job: DownloadJob) {
        let d = UserDefaults.standard
        let setIcon = d.bool(forKey: Prefs.setFinderIcon)
        let keep = d.bool(forKey: Prefs.keepThumbnail)
        for file in job.files {
            guard let thumb = CoverArt.thumbnailURL(for: file) else { continue }
            if let img = NSImage(contentsOf: thumb) {
                if file == job.files.first { job.thumbnail = img }   // 先読みの仮の画像を本物のカバーに置き換える
                if setIcon { CoverArt.applyFinderIcon(image: img, to: file) }
            }
            if !keep { try? FileManager.default.removeItem(at: thumb) }
        }
    }

    func cancel(_ job: DownloadJob) {
        if job === current {
            downloader?.cancel()
        } else if job.state == .waiting {
            job.state = .cancelled
        }
    }

    func cancelAll() {
        for j in jobs where j.state == .waiting { j.state = .cancelled }
        downloader?.cancel()
    }

    func retry(_ job: DownloadJob) {
        guard !job.isActive else { return }
        job.state = .waiting
        job.progress = 0
        job.files = []
        job.log = []
        job.errorCount = 0
        job.lastError = nil
        pump()
    }

    func remove(_ job: DownloadJob) {
        if job.isActive { cancel(job) }
        jobs.removeAll { $0 === job }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    // MARK: Finder

    func reveal(_ job: DownloadJob) {
        if job.files.isEmpty { revealFolder() } else { NSWorkspace.shared.activateFileViewerSelecting(job.files) }
    }

    /// 保存先に残っている jpg（途中で失敗した再生リストのぶんなど）を Finder アイコンにして片づける
    func tidyFolder() {
        let fm = FileManager.default
        let d = UserDefaults.standard
        let setIcon = d.bool(forKey: Prefs.setFinderIcon)
        let keep = d.bool(forKey: Prefs.keepThumbnail)
        var n = 0
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let f as URL in e where ["m4a", "mp3"].contains(f.pathExtension.lowercased()) {
                guard let t = CoverArt.thumbnailURL(for: f), let img = NSImage(contentsOf: t) else { continue }
                if setIcon { CoverArt.applyFinderIcon(image: img, to: f) }
                if !keep { try? fm.removeItem(at: t) }
                n += 1
            }
        }
        let alert = NSAlert()
        alert.messageText = n == 0 ? "片づけるものはありませんでした" : "\(n) 曲のカバー画像を片づけました"
        alert.informativeText = n == 0 ? "保存先に、曲と同じ名前の jpg は残っていません。"
            : (setIcon ? "Finder アイコンに設定し、" : "") + (keep ? "jpg はそのまま残しました。" : "jpg は消しました。")
        alert.runModal()
    }

    /// 直下の曲を、埋め込んだチャンネル名のフォルダに振り分ける（確認 → 実行 → 結果）。終わったら onDone
    func sortIntoChannelFolders(onDone: (() -> Void)? = nil) {
        let files = ChannelSorter.rootAudioFiles(in: folder)
        let ask = NSAlert()
        if files.isEmpty {
            ask.messageText = "保存先の直下に曲はありません"
            ask.informativeText = "すでにチャンネルごとのフォルダに入っています。"
            ask.runModal()
            return
        }
        ask.messageText = "直下の \(files.count) 曲をチャンネルのフォルダに振り分けます"
        ask.informativeText = "曲に埋め込んであるチャンネル名（アーティスト）のフォルダへ移します。入っていない曲はそのまま残します。"
        ask.addButton(withTitle: "振り分ける")
        ask.addButton(withTitle: "キャンセル")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let folder = self.folder
        Task { @MainActor in
            let r = await ChannelSorter.run(folder: folder)
            let done = NSAlert()
            done.messageText = r.summary.split(separator: "\n").first.map(String.init) ?? ""
            let rest = r.summary.split(separator: "\n").dropFirst().joined(separator: "\n")
            let detail = (r.skippedNoArtist + r.skippedExists + r.failed).prefix(8).joined(separator: "\n")
            done.informativeText = [rest, detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
            done.runModal()
            onDone?()
        }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "この場所に保存"
        panel.directoryURL = folder
        if panel.runModal() == .OK, let u = panel.url {
            UserDefaults.standard.set(u.path, forKey: Prefs.folder)
        }
    }
}
