import Foundation

/// yt-dlp・ffmpeg・deno を公式の配布元から直接取ってきて、アプリ専用の場所に置く。
/// Homebrew も管理者パスワードも要らない（Windows 版と同じ考え方）。
enum ToolInstaller {
    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 配布元は CPU に合わせて選ぶ
    #if arch(arm64)
    private static let ffmpegArch = "arm64"
    private static let denoFile = "deno-aarch64-apple-darwin.zip"
    #else
    private static let ffmpegArch = "amd64"
    private static let denoFile = "deno-x86_64-apple-darwin.zip"
    #endif

    /// 全部（yt-dlp・ffmpeg・ffprobe・deno）を用意する。`progress` には今の作業が日本語で届く
    static func installAll(progress: @escaping @Sendable (String) -> Void) async throws {
        let dir = Tools.appToolsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try await installYtdlp(progress: progress)

        for name in ["ffmpeg", "ffprobe"] {
            progress("\(name) をダウンロード中…")
            let url = "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(ffmpegArch)/release/\(name).zip"
            try await fetchZip(url, name: name, into: dir)
        }

        progress("deno をダウンロード中…")
        try await fetchZip("https://github.com/denoland/deno/releases/latest/download/\(denoFile)", name: "deno", into: dir)

        progress("確認中…")
        for name in ["yt-dlp", "ffmpeg", "deno"] {
            let exe = dir.appendingPathComponent(name)
            let r = Tools.run(exe, [name == "ffmpeg" ? "-version" : "--version"], timeout: 60)
            if r.status != 0 {
                throw InstallError(message: "\(name) を起動できませんでした（\(r.output.prefix(200))）")
            }
        }
        progress("準備ができました")
    }

    /// yt-dlp だけ入れ直す（更新用）
    static func installYtdlp(progress: @escaping @Sendable (String) -> Void) async throws {
        let dir = Tools.appToolsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        progress("yt-dlp をダウンロード中…")
        let src = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let tmp = try await download(src)
        try place(tmp, as: dir.appendingPathComponent("yt-dlp"))
    }

    // MARK: 内部

    private static func download(_ url: URL) async throws -> URL {
        do {
            let (tmp, res) = try await URLSession.shared.download(from: url)
            if let h = res as? HTTPURLResponse, h.statusCode != 200 {
                throw InstallError(message: "ダウンロードに失敗しました（HTTP \(h.statusCode)）: \(url.host ?? "")")
            }
            return tmp
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError(message: "ダウンロードできませんでした。ネットワークにつながっているか確認してください（\(error.localizedDescription)）")
        }
    }

    /// zip を落として、中の実行ファイル（name）だけを dir に置く
    private static func fetchZip(_ urlString: String, name: String, into dir: URL) async throws {
        let tmp = try await download(URL(string: urlString)!)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let r = Tools.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-o", "-q", tmp.path, "-d", work.path], timeout: 120)
        guard r.status == 0 else { throw InstallError(message: "\(name) の zip を開けませんでした（\(r.output.prefix(200))）") }

        // zip の中身は階層が違うことがあるので、name という名前のファイルを探す
        guard let e = FileManager.default.enumerator(at: work, includingPropertiesForKeys: [.isRegularFileKey]),
              let found = (e.allObjects as? [URL])?.first(where: { $0.lastPathComponent == name })
        else { throw InstallError(message: "\(name) が zip の中に見つかりませんでした") }
        try place(found, as: dir.appendingPathComponent(name))
    }

    /// 置き換えて、実行権限を付け、隔離属性（あれば）を外す
    private static func place(_ src: URL, as dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: src, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        _ = Tools.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-d", "com.apple.quarantine", dest.path], timeout: 10)
    }
}
