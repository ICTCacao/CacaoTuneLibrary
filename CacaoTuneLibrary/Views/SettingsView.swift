import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.setFinderIcon) private var setFinderIcon = true
    @AppStorage(Prefs.coverMode) private var coverMode = CoverMode.pad.rawValue
    @AppStorage(Prefs.keepThumbnail) private var keepThumbnail = false
    @AppStorage(Prefs.wholePlaylist) private var wholePlaylist = false
    @AppStorage(Prefs.idInFilename) private var idInFilename = false
    @AppStorage(Prefs.channelFolders) private var channelFolders = true
    @AppStorage(Prefs.albumName) private var albumName = AppInfo.name
    @AppStorage(Prefs.ytdlpPath) private var ytdlpPath = ""
    @AppStorage(Prefs.ffmpegPath) private var ffmpegPath = ""
    @State private var updating = false
    @State private var updateResult: String?

    var body: some View {
        Form {
            Section("カバー画像") {
                Toggle("保存したファイルの Finder アイコンにカバー画像を使う", isOn: $setFinderIcon)
                Picker("正方形にする", selection: $coverMode) {
                    ForEach(CoverMode.allCases) { m in Text(m.label).tag(m.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Toggle("カバー画像（jpg）もファイルとして残す", isOn: $keepThumbnail)
                Text("曲の中には常にカバー画像とタイトル・チャンネル名を埋め込みます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("曲の情報（タグ）") {
                LabeledContent("アルバム名") {
                    HStack {
                        TextField("空なら入れない", text: $albumName)
                            .textFieldStyle(.roundedBorder)
                        Button("初期値に戻す") { albumName = AppInfo.name }
                            .disabled(albumName == AppInfo.name)
                    }
                }
                Text("これから保存する曲に入れるアルバム名です（初期値は \(AppInfo.name)）。空にするとアルバムは入れません。保存済みの曲は「曲の情報を整える」で直せます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("保存") {
                Toggle("保存先の中にチャンネル名のフォルダを作って分ける", isOn: $channelFolders)
                Toggle("動画の URL に再生リストが付いているとき（&list=…）も全曲を保存する", isOn: $wholePlaylist)
                Text("再生リストそのものの URL（youtube.com/playlist?list=…）は、この設定に関係なく全曲を保存します。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("ファイル名の末尾に動画 ID を付ける（同じ題名の曲がぶつからない）", isOn: $idInFilename)
            }
            Section("道具（yt-dlp・ffmpeg）") {
                LabeledContent("yt-dlp") {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField("自動検出（\(model.ytdlp?.path ?? "見つかりません")）", text: $ytdlpPath)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.refreshTools() }
                        if let v = model.ytdlpVersion {
                            Text("バージョン \(v)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("ffmpeg") {
                    TextField("自動検出（\(model.ffmpeg?.path ?? "見つかりません")）", text: $ffmpegPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.refreshTools() }
                }
                HStack {
                    Button("探し直す") { model.refreshTools() }
                    if model.toolsReady {
                        Button(updating || model.installing ? "更新中…" : (Tools.isAppManaged(model.ytdlp) ? "yt-dlp を更新" : "yt-dlp を更新（brew upgrade）")) { update() }
                            .disabled(updating || model.installing || (!Tools.isAppManaged(model.ytdlp) && Tools.brew == nil))
                    } else {
                        Button(model.installing ? "用意しています…" : "道具を用意する") { model.installTools() }
                            .disabled(model.installing)
                    }
                    if model.installing { ProgressView().controlSize(.small); Text(model.installMessage).font(.caption) }
                    Spacer()
                }
                if let err = model.installError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if let r = updateResult {
                    ScrollView {
                        Text(r)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                }
                Text("YouTube 側の変更で保存できなくなったら、まず yt-dlp を更新してください。入っていないときは「道具を用意する」を押すと、アプリが自分で取ってきます（Homebrew は要りません）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onChange(of: ytdlpPath) { model.refreshTools() }
        .onChange(of: ffmpegPath) { model.refreshTools() }
    }

    private func update() {
        if Tools.isAppManaged(model.ytdlp) { model.installTools(ytdlpOnly: true); return }
        guard let brew = Tools.brew else { return }
        updating = true
        updateResult = nil
        DispatchQueue.global().async {
            let r = Tools.run(brew, ["upgrade", "yt-dlp"], timeout: 600)
            DispatchQueue.main.async {
                updating = false
                updateResult = r.output.isEmpty ? (r.status == 0 ? "更新は不要でした（最新です）" : "終了コード \(r.status)") : r.output
                model.refreshTools()
            }
        }
    }
}
