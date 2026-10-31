import Foundation
import AppKit
import Observation

/// 1 件の URL のダウンロード。再生リストなら複数のファイルができる。
@Observable
final class DownloadJob: Identifiable {
    enum State: Equatable {
        case waiting
        case running(String)      // 何をしているか（取得中 / 変換中 など）
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let url: String
    var title: String?
    var uploader: String?
    var playlistTitle: String?         // 再生リストなら、その名前
    var itemIndex: Int?                // 再生リストの何曲目か
    var itemCount: Int?                // 再生リストの全曲数
    var state: State = .waiting
    var progress: Double = 0           // 0...1（取得中のみ意味を持つ）
    var files: [URL] = []              // できあがった音声ファイル
    var errorCount = 0                 // 再生リストの中で保存できなかった曲数
    var lastError: String?             // その理由（最後のもの）
    var thumbnail: NSImage?            // 一覧に出すカバー画像
    var log: [String] = []             // yt-dlp の出力（そのまま）

    init(url: String) { self.url = url }

    var isActive: Bool {
        if case .running = state { return true }
        return state == .waiting
    }

    var displayTitle: String { playlistTitle ?? title ?? url }

    /// 再生リストのときの「3/15 曲目」
    var itemText: String? {
        guard let i = itemIndex, let n = itemCount, n > 1 else { return nil }
        return "\(i)/\(n) 曲目"
    }

    var statusText: String {
        switch state {
        case .waiting: return "待機中"
        case .running(let phase):
            if let it = itemText { return "\(it)　\(phase)" }
            return phase
        case .done:
            if errorCount > 0 { return "完了（\(files.count) 曲、\(errorCount) 曲は保存できず）" }
            return files.count > 1 ? "完了（\(files.count) 曲）" : "完了"
        case .failed(let msg): return "失敗: \(msg)"
        case .cancelled: return "中止"
        }
    }
}
