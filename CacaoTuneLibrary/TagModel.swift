import Foundation
import AppKit
import Observation

/// 曲の中に埋め込まれた情報（タグ）の項目。キーは ffmpeg のメタデータ名
enum TagField: String, CaseIterable, Identifiable {
    case title, artist, album, album_artist, genre, date, track, comment, description

    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: "タイトル"
        case .artist: "アーティスト"
        case .album: "アルバム"
        case .album_artist: "アルバムアーティスト"
        case .genre: "ジャンル"
        case .date: "日付・年"
        case .track: "トラック番号"
        case .comment: "コメント"
        case .description: "説明"
        }
    }
    /// 複数行で編集するもの
    var isLong: Bool { self == .comment || self == .description }
}

/// タグを直す 1 曲
@Observable
final class TagItem: Identifiable {
    let id = UUID()
    let url: URL
    let channel: String
    let fileBase: String               // ファイル名（拡張子・末尾の動画 ID なし）
    var original: [TagField: String] = [:]
    var values: [TagField: String] = [:]
    var loaded = false
    var error: String?
    var icon: NSImage?

    init(url: URL, channel: String) {
        self.url = url
        self.channel = channel
        self.fileBase = RenameItem.splitID(url.deletingPathExtension().lastPathComponent).0
    }

    func value(_ f: TagField) -> String { values[f] ?? "" }
    func isChanged(_ f: TagField) -> Bool { (values[f] ?? "") != (original[f] ?? "") }
    var isChanged: Bool { TagField.allCases.contains { isChanged($0) } }
    var changedFields: [TagField] { TagField.allCases.filter { isChanged($0) } }
    /// どこかの項目に、分かれた濁点・半濁点（U+3099 / U+309A）がある
    var hasDecomposed: Bool {
        values.values.contains { $0.unicodeScalars.contains { $0.value == 0x3099 || $0.value == 0x309A } }
    }
    /// 一覧に出す名前（タイトルが空ならファイル名）
    var displayTitle: String {
        let t = value(.title).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? fileBase : t
    }
}

/// 保存先の曲のタグをまとめて読み、検索・置換やまとめて入れるで直して、最後に書き込む。
/// 読み書きは ffmpeg（音声・カバー画像はそのまま -c copy で写し、タグだけ変える）。
@Observable
final class TagModel {
    let folder: URL
    let ffmpeg: URL?
    var items: [TagItem] = []
    var scope = ""                     // 対象のチャンネル（空ならすべて）
    var selection: TagItem.ID?
    var loading = 0                    // 読み込みの残り
    var writing: (done: Int, total: Int)?
    var lastResult: String?
    var regexError: String?

    // 検索・置換
    var replaceField: TagField = .title
    var search = ""
    var replacement = ""
    var useRegex = false
    var ignoreCase = false

    // まとめて入れる
    var fillField: TagField = .album
    var fillValue = ""

    init(folder: URL, ffmpeg: URL?) {
        self.folder = folder
        self.ffmpeg = ffmpeg
    }

    var channels: [String] {
        var seen: [String] = []
        for i in items where !seen.contains(i.channel) { seen.append(i.channel) }
        return seen.sorted { a, b in
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
    var shownChannels: [String] { scope.isEmpty ? channels : [scope] }
    func items(in channel: String) -> [TagItem] { items.filter { $0.channel == channel } }
    /// 対象（いま一覧に出ている曲）
    var targets: [TagItem] { items.filter { scope.isEmpty || $0.channel == scope } }
    var selected: TagItem? { items.first { $0.id == selection } }
    var changedCount: Int { items.filter(\.isChanged).count }
    var isBusy: Bool { loading > 0 || writing != nil }

    // MARK: 読み込み

    func scan() {
        let fm = FileManager.default
        let audio = ["m4a", "mp3"]
        var found: [TagItem] = []
        if let top = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for entry in top {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    for f in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    where audio.contains(f.pathExtension.lowercased()) {
                        found.append(TagItem(url: f, channel: entry.lastPathComponent))
                    }
                } else if audio.contains(entry.pathExtension.lowercased()) {
                    found.append(TagItem(url: entry, channel: ""))
                }
            }
        }
        found.sort { a, b in
            if a.channel != b.channel { return a.channel.localizedStandardCompare(b.channel) == .orderedAscending }
            return a.fileBase.localizedStandardCompare(b.fileBase) == .orderedAscending
        }
        items = found
        selection = nil
        lastResult = nil
        guard let ffmpeg else { return }
        loading = found.count
        // 一度に読みすぎないよう、4 本ずつ並べて読む
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        for item in found {
            queue.addOperation {
                let tags = Self.readTags(item.url, ffmpeg: ffmpeg)
                let img = NSWorkspace.shared.icon(forFile: item.url.path)
                img.size = NSSize(width: 64, height: 64)
                DispatchQueue.main.async {
                    switch tags {
                    case .success(let t):
                        item.original = t
                        item.values = t
                    case .failure(let e):
                        item.error = e.localizedDescription
                    }
                    item.icon = img
                    item.loaded = true
                    self.loading -= 1
                }
            }
        }
    }

    /// ffmpeg -f ffmetadata で、いまのタグを全部（キーは小文字）読む
    static func readRawTags(_ url: URL, ffmpeg: URL) -> Result<[String: String], Error> {
        let r = runProcess(ffmpeg, ["-v", "error", "-nostdin", "-i", url.path, "-f", "ffmetadata", "-"])
        guard r.status == 0 else { return .failure(TagError.message(r.error.isEmpty ? "タグを読めませんでした" : r.error)) }
        return .success(parseFFMetadata(r.output))
    }

    /// ffmetadata の書き方: = ; # \ 改行 の前に \ を付ける
    static func escapeFFMetadata(_ s: String) -> String {
        var o = ""
        for ch in s {
            if ch == "\r\n" { o += "\\\n"; continue }        // CRLF は 1 文字として来るので改行にそろえる
            if "=;#\\\n".contains(ch) { o.append("\\") }
            o.append(ch)
        }
        return o
    }

    /// いまのタグのうち、この窓で扱う項目
    static func readTags(_ url: URL, ffmpeg: URL) -> Result<[TagField: String], Error> {
        let raw: [String: String]
        switch readRawTags(url, ffmpeg: ffmpeg) {
        case .success(let t): raw = t
        case .failure(let e): return .failure(e)
        }
        var t: [TagField: String] = [:]
        for f in TagField.allCases {
            if let v = raw[f.rawValue] { t[f] = v }
        }
        // mp4 の説明は desc（description）と ldes（synopsis）の 2 か所にある
        if t[.description] == nil, let s = raw["synopsis"] { t[.description] = s }
        if t[.date] == nil, let y = raw["year"] { t[.date] = y }
        return .success(t)
    }

    /// ffmetadata 形式（key=value、\ で = ; # \ 改行をエスケープ）を辞書にする
    static func parseFFMetadata(_ s: String) -> [String: String] {
        var dict: [String: String] = [:]
        var key: String?
        var cur = ""
        var escaping = false
        for ch in s {
            if escaping { cur.append(ch); escaping = false; continue }
            if ch == "\\" { escaping = true; continue }
            if ch == "\n" || ch == "\r\n" {
                if let k = key { dict[k.lowercased()] = cur }
                else if cur.hasPrefix("[") { return dict }      // [CHAPTER] などから先は曲全体のタグではない
                key = nil; cur = ""
                continue
            }
            if ch == "=", key == nil { key = cur; cur = ""; continue }
            cur.append(ch)
        }
        if let k = key { dict[k.lowercased()] = cur }
        return dict
    }

    // MARK: 直す

    func applyReplace() {
        regexError = nil
        guard !search.isEmpty else { return }
        let f = replaceField
        if useRegex {
            var opts: NSRegularExpression.Options = []
            if ignoreCase { opts.insert(.caseInsensitive) }
            let re: NSRegularExpression
            do { re = try NSRegularExpression(pattern: search, options: opts) } catch {
                regexError = "正規表現が読めません: \(error.localizedDescription)"
                return
            }
            for i in targets where i.loaded {
                let s = i.value(f)
                i.values[f] = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement)
            }
        } else {
            let opts: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
            for i in targets where i.loaded {
                i.values[f] = i.value(f).replacingOccurrences(of: search, with: replacement, options: opts)
            }
        }
    }

    /// 対象の曲すべてに同じ値を入れる（空なら消す）
    func fill() {
        for i in targets where i.loaded { i.values[fillField] = fillValue }
    }

    /// 対象の曲のタイトルを、いまのファイル名（動画 ID なし）にする。
    /// Mac のディスク（HFS+）のファイル名は「ガ」が「カ＋濁点」に分かれている（NFD）ので、1 文字（NFC）に戻して入れる
    func titleFromFileName() {
        for i in targets where i.loaded { i.values[.title] = i.fileBase.precomposedStringWithCanonicalMapping }
    }

    /// 「カ＋濁点」のように分かれた文字（NFD）を含む曲の数（対象のうち）
    var decomposedCount: Int { targets.filter { $0.loaded && $0.hasDecomposed }.count }

    /// 対象の曲のすべての項目で、分かれた濁点・半濁点を 1 文字にそろえる（車のナビなどで □ になるのを防ぐ）
    func normalizeAll() {
        for i in targets where i.loaded {
            for f in TagField.allCases where i.values[f] != nil {
                i.values[f] = i.value(f).precomposedStringWithCanonicalMapping
            }
        }
    }

    func reset(_ item: TagItem) { item.values = item.original }
    func resetAll() { for i in items { i.values = i.original } }

    // MARK: 書き込み

    func commit() {
        guard let ffmpeg, writing == nil else { return }
        let changed = items.filter(\.isChanged)
        guard !changed.isEmpty else { return }
        writing = (0, changed.count)
        lastResult = nil
        // 値は main で写し取ってから裏で書く
        let work: [(TagItem, URL, [(TagField, String)])] = changed.map { i in (i, i.url, i.changedFields.map { ($0, i.value($0)) }) }
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = 0, failed = 0
            for (item, url, fields) in work {
                let err = Self.writeTags(url, fields: fields, ffmpeg: ffmpeg)
                if err == nil { ok += 1 } else { failed += 1 }
                DispatchQueue.main.async {
                    if let err {
                        item.error = err
                    } else {
                        item.error = nil
                        for (f, v) in fields {
                            let n = v.precomposedStringWithCanonicalMapping
                            item.original[f] = n
                            item.values[f] = n
                        }
                    }
                    self.writing?.done += 1
                }
            }
            let summary = failed == 0 ? "\(ok) 曲の情報を書き換えました" : "\(ok) 曲を書き換え、\(failed) 曲は失敗しました"
            DispatchQueue.main.async {
                self.writing = nil
                self.lastResult = summary
            }
        }
    }

    /// タグだけ変えた新しいファイルを隣に作り、Finder のアイコン（拡張属性）を写してから入れ替える。
    /// 戻り値は失敗の理由（成功なら nil）
    static func writeTags(_ url: URL, fields: [(TagField, String)], ffmpeg: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".cacaotag-\(UUID().uuidString).\(ext)")
        // 値はコマンドの引数では渡さない: Foundation の Process は引数を「カ＋濁点」に分けて（NFD に）渡してしまい、
        // 車のナビなどで濁点が □ になる。いまのタグを全部読み、直した値と合わせて UTF-8 のファイル（ffmetadata）に書いて読ませる
        let current: [String: String]
        switch readRawTags(url, ffmpeg: ffmpeg) {
        case .success(let t): current = t
        case .failure(let e): return e.localizedDescription
        }
        var tags = current
        for k in ["major_brand", "minor_version", "compatible_brands", "encoder"] { tags[k] = nil }   // 書き出すときに作られるもの
        for (f, v) in fields {
            tags[f.rawValue] = v.isEmpty ? nil : v
            if f == .description { tags["synopsis"] = v.isEmpty ? nil : v }   // mp4 の長い説明も揃える
        }
        var meta = ";FFMETADATA1\n"
        for k in tags.keys.sorted() {
            // 書き込む文字は必ず NFC（「ガ」を 1 文字）に
            meta += escapeFFMetadata(k) + "=" + escapeFFMetadata(tags[k]!.precomposedStringWithCanonicalMapping) + "\n"
        }
        let metaFile = FileManager.default.temporaryDirectory.appendingPathComponent("cacaotag-\(UUID().uuidString).txt")
        do { try meta.write(to: metaFile, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
        defer { try? FileManager.default.removeItem(at: metaFile) }
        // -dn: チャプター付きの動画から保存した曲には、チャプター用の文字トラック（bin_data）が入っている。
        // そのまま写すと m4a に書けず失敗するので写さない。チャプターは -map_chapters 0 で写り、ffmpeg が作り直す
        var args = ["-v", "error", "-nostdin", "-y", "-i", url.path, "-f", "ffmetadata", "-i", metaFile.path,
                    "-map", "0", "-dn", "-map_metadata", "1", "-map_chapters", "0", "-c", "copy"]
        if ext == "mp3" { args += ["-id3v2_version", "3", "-f", "mp3"] } else { args += ["-f", "ipod"] }
        args.append(tmp.path)
        let r = runProcess(ffmpeg, args)
        let fm = FileManager.default
        guard r.status == 0, fm.fileExists(atPath: tmp.path) else {
            try? fm.removeItem(at: tmp)
            return r.error.isEmpty ? "ffmpeg が失敗しました（\(r.status)）" : r.error
        }
        copyXattrs(from: url, to: tmp)
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            return nil
        } catch {
            try? fm.removeItem(at: tmp)
            return error.localizedDescription
        }
    }

    /// 拡張属性（Finder のカスタムアイコン = ResourceFork / FinderInfo など）を写す
    static func copyXattrs(from src: URL, to dst: URL) {
        src.withUnsafeFileSystemRepresentation { s in
            dst.withUnsafeFileSystemRepresentation { d in
                guard let s, let d else { return }
                let size = listxattr(s, nil, 0, 0)
                guard size > 0 else { return }
                var names = [CChar](repeating: 0, count: size)
                guard listxattr(s, &names, size, 0) == size else { return }
                var start = 0
                for i in 0..<size where names[i] == 0 {
                    let name = String(cString: Array(names[start...i]))
                    start = i + 1
                    let len = getxattr(s, name, nil, 0, 0, 0)
                    guard len >= 0 else { continue }
                    var buf = [UInt8](repeating: 0, count: len)
                    guard getxattr(s, name, &buf, len, 0, 0) == len else { continue }
                    _ = setxattr(d, name, buf, len, 0, 0)
                }
            }
        }
    }

    /// 出力が大きくても詰まらないよう、標準出力・エラーを読み切ってから終了を待つ
    static func runProcess(_ exe: URL, _ args: [String]) -> (status: Int32, output: String, error: String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = Tools.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum TagError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
}
