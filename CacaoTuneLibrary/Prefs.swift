import Foundation

/// 設定の保存キー。画面（@AppStorage）とモデル（UserDefaults）で同じキーを使う。
enum Prefs {
    static let folder = "saveFolder"               // 保存先フォルダのパス
    static let format = "audioFormat"              // m4a / mp3
    static let setFinderIcon = "setFinderIcon"     // 保存したファイルの Finder アイコンにカバー画像を使う
    static let coverMode = "coverMode"             // カバー画像の整え方（CoverMode）
    static let keepThumbnail = "keepThumbnail"     // カバー画像（jpg）もファイルとして残す
    static let wholePlaylist = "wholePlaylist"     // 再生リストの URL なら全曲
    static let idInFilename = "idInFilename"       // ファイル名に動画 ID を付ける（同名曲の衝突よけ）
    static let channelFolders = "channelFolders"   // 保存先の中にチャンネル名のフォルダを作って分ける
    static let ytdlpPath = "ytdlpPath"             // 空なら自動検出
    static let ffmpegPath = "ffmpegPath"           // 空なら自動検出

    /// 旧名 CacaoYT2Music のときの設定を一度だけ引き継ぐ（registerDefaults より前に呼ぶ）
    static func migrateFromOldName() {
        let d = UserDefaults.standard
        let flag = "migratedFromCacaoYT2Music"
        guard !d.bool(forKey: flag) else { return }
        if let old = UserDefaults(suiteName: "com.ictcacao.CacaoYT2Music") {
            for key in [folder, format, setFinderIcon, coverMode, keepThumbnail, wholePlaylist, idInFilename, channelFolders, ytdlpPath, ffmpegPath]
            where d.object(forKey: key) == nil {
                if let v = old.object(forKey: key) { d.set(v, forKey: key) }
            }
        }
        d.set(true, forKey: flag)
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            folder: defaultFolder.path,
            format: AudioFormat.m4a.rawValue,
            setFinderIcon: true,
            coverMode: CoverMode.pad.rawValue,
            keepThumbnail: false,
            wholePlaylist: false,
            idInFilename: false,
            channelFolders: true,
            ytdlpPath: "",
            ffmpegPath: "",
        ])
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YouTube", isDirectory: true)
    }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case m4a, mp3
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var note: String {
        switch self {
        case .m4a: return "元の音声をそのまま（劣化なし・おすすめ）"
        case .mp3: return "変換して保存（対応機器が多い）"
        }
    }
}

/// カバー画像（YouTube のサムネイルは 16:9）をどう正方形にするか
enum CoverMode: String, CaseIterable, Identifiable {
    case pad      // 幅はそのまま、上下をぼかした同じ画像で埋める
    case crop     // 中央を正方形に切り抜く
    case none     // 16:9 のまま
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pad: return "16:9 の幅のまま、上下をぼかしで埋めて正方形に"
        case .crop: return "中央を正方形に切り抜く"
        case .none: return "そのまま（16:9）"
        }
    }
}
