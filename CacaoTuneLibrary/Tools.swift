import Foundation

/// yt-dlp / ffmpeg の場所を探す。Homebrew（Apple Silicon / Intel）と ~/.local/bin を見る。
enum Tools {
    static let searchDirs: [String] = [
        "/opt/homebrew/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin", "/usr/bin",
    ]

    /// 設定で指定があればそれを、なければ探して返す
    static func locate(_ name: String, override: String) -> URL? {
        let o = override.trimmingCharacters(in: .whitespaces)
        if !o.isEmpty {
            let p = (o as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: p) ? URL(fileURLWithPath: p) : nil
        }
        for dir in searchDirs {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    static var brew: URL? { locate("brew", override: "") }

    /// 外部プロセスに渡す PATH。アプリから起動すると PATH がほぼ空なので、Homebrew の場所を足す
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = searchDirs.joined(separator: ":")
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["LANG"] = "ja_JP.UTF-8"
        return env
    }

    /// `tool --version` などを同期で実行して出力を返す（短時間で終わるものだけに使う）
    static func run(_ exe: URL, _ args: [String], timeout: TimeInterval = 20) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error.localizedDescription)") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // 行頭のタブは意味を持つ（--print の空の項目）ので、改行だけ落とす
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
    }
}
