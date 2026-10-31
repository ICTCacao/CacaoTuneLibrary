import Foundation
import AppKit

/// 保存した音声ファイルの横にある jpg（yt-dlp が書いたカバー画像）を見つけて、Finder のアイコンに使う。
enum CoverArt {
    /// 同じ名前の .jpg を探す
    static func thumbnailURL(for audio: URL) -> URL? {
        let base = audio.deletingPathExtension()
        for ext in ["jpg", "jpeg", "png", "webp"] {
            let u = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// 画像を正方形に切り抜いて角を丸め、Finder のアイコン（512px）にする
    static func makeIcon(from image: NSImage, size: CGFloat = 512) -> NSImage {
        let src = image
        let w = src.size.width, h = src.size.height
        let side = min(w, h)
        let crop = NSRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        let out = NSImage(size: NSSize(width: size, height: size))
        out.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: size * 0.09, yRadius: size * 0.09).addClip()
        src.draw(in: rect, from: crop, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// Finder のアイコンを設定。成功したら true
    @discardableResult
    static func applyFinderIcon(image: NSImage, to file: URL) -> Bool {
        NSWorkspace.shared.setIcon(makeIcon(from: image), forFile: file.path, options: [])
    }
}
