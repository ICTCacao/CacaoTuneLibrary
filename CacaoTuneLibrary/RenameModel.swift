import Foundation
import AppKit
import Observation

/// 名前を付け直す 1 ファイル。拡張子と、末尾の動画 ID「 [xxxxxxxxxxx]」は変えない（一覧にも出さない）
@Observable
final class RenameItem: Identifiable {
    /// ファイル名の末尾の動画 ID（yt-dlp の %(id)s は 11 文字）
    static let idSuffixRegex = try! NSRegularExpression(pattern: #" \[[A-Za-z0-9_-]{11}\]$"#)

    let id = UUID()
    var url: URL                       // いまの場所
    let channel: String                // チャンネル名のフォルダ（直下なら空）
    var originalBase: String           // いまの名前（拡張子・動画 ID なし）
    var newBase: String                // 新しい名前（拡張子・動画 ID なし）
    let idSuffix: String               // 「 [動画ID]」。無ければ空。更新のとき自動で付け直す
    let ext: String
    var icon: NSImage?                 // Finder のアイコン（カバー画像）
    var error: String?                 // 更新できない理由

    init(url: URL, channel: String) {
        self.url = url
        self.channel = channel
        let full = url.deletingPathExtension().lastPathComponent
        let (base, suffix) = Self.splitID(full)
        self.originalBase = base
        self.newBase = base
        self.idSuffix = suffix
        self.ext = url.pathExtension
    }

    /// 「題名 [動画ID]」→（題名, 「 [動画ID]」）
    static func splitID(_ name: String) -> (String, String) {
        let r = NSRange(name.startIndex..., in: name)
        if let m = idSuffixRegex.firstMatch(in: name, range: r), let range = Range(m.range, in: name) {
            return (String(name[..<range.lowerBound]), String(name[range]))
        }
        return (name, "")
    }

    var isChanged: Bool { newBase != originalBase }
    /// 実際のファイル名（拡張子なし）。隠している動画 ID を戻す
    var newFullBase: String {
        var b = newBase
        if !idSuffix.isEmpty, b.hasSuffix(idSuffix) { b.removeLast(idSuffix.count) }   // 手で ID を書いてしまっても二重にしない
        return b + idSuffix
    }
    var newURL: URL { url.deletingLastPathComponent().appendingPathComponent(newFullBase).appendingPathExtension(ext) }
}

/// 保存先の中の m4a / mp3 を集めて、検索・置換で名前を作り、最後にまとめて書き換える
@Observable
final class RenameModel {
    let folder: URL
    var items: [RenameItem] = []
    var search = ""
    var replacement = ""
    var useRegex = false
    var ignoreCase = false
    var scope = ""                     // 置換の対象（空ならすべてのチャンネル）
    var regexError: String?
    var lastResult: String?

    init(folder: URL) { self.folder = folder }

    /// チャンネル名の一覧（直下のファイルは "" で表す）
    var channels: [String] {
        var seen: [String] = []
        for i in items where !seen.contains(i.channel) { seen.append(i.channel) }
        return seen.sorted { a, b in
            if a.isEmpty != b.isEmpty { return b.isEmpty }   // 直下は最後
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    func items(in channel: String) -> [RenameItem] {
        items.filter { $0.channel == channel }
    }

    var changedCount: Int { items.filter(\.isChanged).count }
    var errorCount: Int { items.filter { $0.error != nil }.count }

    static func label(for channel: String) -> String { channel.isEmpty ? "（保存先の直下）" : channel }

    // MARK: 読み込み

    func scan() {
        let fm = FileManager.default
        var found: [RenameItem] = []
        let audio = ["m4a", "mp3"]
        guard let top = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            items = []
            return
        }
        for entry in top {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if let files = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for f in files where audio.contains(f.pathExtension.lowercased()) {
                        found.append(RenameItem(url: f, channel: entry.lastPathComponent))
                    }
                }
            } else if audio.contains(entry.pathExtension.lowercased()) {
                found.append(RenameItem(url: entry, channel: ""))
            }
        }
        found.sort { a, b in
            if a.channel != b.channel { return a.channel.localizedStandardCompare(b.channel) == .orderedAscending }
            return a.originalBase.localizedStandardCompare(b.originalBase) == .orderedAscending
        }
        items = found
        lastResult = nil
        // アイコンは後から
        DispatchQueue.global(qos: .userInitiated).async {
            for i in found {
                let img = NSWorkspace.shared.icon(forFile: i.url.path)
                img.size = NSSize(width: 64, height: 64)
                DispatchQueue.main.async { i.icon = img }
            }
        }
        validate()
    }

    // MARK: 検索・置換

    /// いまの「新しい名前」に対して置換をかける（何度でも重ねられる）
    func applyReplace() {
        regexError = nil
        guard !search.isEmpty else { return }
        let targets = items.filter { scope.isEmpty || $0.channel == scope }
        if useRegex {
            var opts: NSRegularExpression.Options = []
            if ignoreCase { opts.insert(.caseInsensitive) }
            let re: NSRegularExpression
            do { re = try NSRegularExpression(pattern: search, options: opts) } catch {
                regexError = "正規表現が読めません: \(error.localizedDescription)"
                return
            }
            for i in targets {
                let s = i.newBase
                i.newBase = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement)
            }
        } else {
            let opts: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
            for i in targets {
                i.newBase = i.newBase.replacingOccurrences(of: search, with: replacement, options: opts)
            }
        }
        validate()
    }

    func resetAll() {
        for i in items { i.newBase = i.originalBase }
        validate()
    }

    func reset(_ item: RenameItem) {
        item.newBase = item.originalBase
        validate()
    }

    // MARK: 確認

    /// 空・使えない文字・同じフォルダ内の重複・既にあるファイル、を見て error を付ける
    func validate() {
        for i in items { i.error = nil }
        let fm = FileManager.default
        for ch in channels {
            let group = items(in: ch)
            var names: [String: Int] = [:]
            for i in group { names[i.newFullBase.precomposedStringWithCanonicalMapping, default: 0] += 1 }
            for i in group {
                let name = i.newBase.trimmingCharacters(in: .whitespaces)
                if name.isEmpty { i.error = "名前が空です"; continue }
                if name.hasPrefix(".") { i.error = "先頭に . は使えません"; continue }
                if name.contains("/") || name.contains(":") { i.error = "/ と : は使えません（／ や ： に）"; continue }
                if names[i.newFullBase.precomposedStringWithCanonicalMapping, default: 0] > 1 { i.error = "同じフォルダに同じ名前があります"; continue }
                if i.isChanged, fm.fileExists(atPath: i.newURL.path),
                   i.newURL.path.precomposedStringWithCanonicalMapping.lowercased() != i.url.path.precomposedStringWithCanonicalMapping.lowercased() {
                    i.error = "その名前のファイルが既にあります"
                }
            }
        }
    }

    // MARK: 更新

    /// 変わった分だけ実際に名前を変える（同名の jpg があれば一緒に）。
    func commit() {
        validate()
        guard errorCount == 0 else { return }
        let fm = FileManager.default
        var ok = 0
        var failed: [String] = []
        for i in items where i.isChanged {
            let dest = i.newURL
            do {
                try fm.moveItem(at: i.url, to: dest)
                // カバー画像（jpg）を残している場合は一緒に
                for ext in ["jpg", "jpeg", "png"] {
                    let side = i.url.deletingPathExtension().appendingPathExtension(ext)
                    if fm.fileExists(atPath: side.path) {
                        try? fm.moveItem(at: side, to: dest.deletingPathExtension().appendingPathExtension(ext))
                    }
                }
                i.url = dest
                i.originalBase = i.newBase
                ok += 1
            } catch {
                failed.append("\(i.originalBase): \(error.localizedDescription)")
                i.error = error.localizedDescription
            }
        }
        lastResult = failed.isEmpty ? "\(ok) 件の名前を変えました"
            : "\(ok) 件を変え、\(failed.count) 件は失敗しました\n" + failed.joined(separator: "\n")
    }
}
