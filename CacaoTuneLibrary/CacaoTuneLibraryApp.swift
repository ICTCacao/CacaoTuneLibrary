import SwiftUI
import AppKit

enum AppInfo {
    static let name = "CacaoTuneLibrary"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

/// ウインドウを閉じたらアプリも終了する。ダウンロード中なら確認してから。
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "ダウンロードの途中です"
        alert.informativeText = "中止して終了しますか？（途中のファイルは残りません）"
        alert.addButton(withTitle: "中止して終了")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            model.cancelAll()
            return .terminateNow
        }
        return .terminateCancel
    }
}

@main
struct CacaoTuneLibraryApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 620, minHeight: 440)
                .onAppear { AppDelegate.model = model }
        }
        .defaultSize(width: 720, height: 520)
        Window("ファイル名を整える", id: "rename") {
            RenameView()
                .environment(model)
        }
        .defaultSize(width: 820, height: 600)
        Settings {
            SettingsView()
                .environment(model)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("\(AppInfo.name) について") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: AppInfo.version,
                        .version: "",
                        .credits: NSAttributedString(string: "YouTube の URL から音声だけを m4a / mp3 にして、チャンネルごとの棚に並べる。\n実作業は yt-dlp と ffmpeg（Homebrew）。\n個人で聴く範囲でお使いください。"),
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("クリップボードの URL を追加") { model.addFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("保存先を Finder で開く") { model.revealFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                RenameMenuButton()
                Button("直下の曲をチャンネルのフォルダに振り分ける") { model.sortIntoChannelFolders() }
                Button("保存先に残ったカバー画像（jpg）を片づける") { model.tidyFolder() }
            }
        }
    }
}

/// メニューから「ファイル名を整える」の窓を開く（openWindow は View の中でしか取れない）
private struct RenameMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("保存した曲のファイル名を整える…") { openWindow(id: "rename") }
            .keyboardShortcut("r", modifiers: [.command])
    }
}
