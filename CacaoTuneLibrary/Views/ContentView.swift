import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.folder) private var folderPath = Prefs.defaultFolder.path
    @AppStorage(Prefs.format) private var format = AudioFormat.m4a.rawValue
    @FocusState private var urlFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // 入力
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("YouTube の URL を貼り付けるか、曲名・アーティスト名を入れて Return", text: $model.urlText)
                        .textFieldStyle(.roundedBorder)
                        .focused($urlFocused)
                        .onSubmit { model.addFromText() }
                    Button {
                        model.addFromText()
                    } label: {
                        if isSearchText {
                            Label("検索", systemImage: "magnifyingglass")
                        } else {
                            Label("追加", systemImage: "plus")
                        }
                    }
                    .disabled(model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.toolsReady)
                    .keyboardShortcut(.defaultAction)
                    .help(isSearchText ? "YouTube を検索して、結果から選んで追加" : "URL を一覧に追加")
                    Button {
                        model.addFromClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .help("クリップボードの URL を追加（⇧⌘V）")
                    .disabled(!model.toolsReady)
                }
                HStack(spacing: 12) {
                    Picker("形式", selection: $format) {
                        ForEach(AudioFormat.allCases) { f in Text(f.label).tag(f.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .help(AudioFormat(rawValue: format)?.note ?? "")
                    Spacer()
                    Text("保存先:")
                        .foregroundStyle(.secondary)
                    Text(abbreviated(folderPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folderPath)
                    Button("変更…") { model.chooseFolder() }
                    Button {
                        model.revealFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("保存先を Finder で開く（⇧⌘O）")
                }
            }
            .padding()

            Divider()

            // 一覧
            if model.jobs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("ここに保存した曲が並びます")
                        .foregroundStyle(.secondary)
                    Text("URL はこの窓にドラッグ＆ドロップしても追加できます。曲名を入れて Return すると YouTube を検索できます")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // 足元: ツールの状態
            HStack {
                ToolStatusView()
                Spacer()
                Button {
                    openWindow(id: "rename")
                } label: { Label("ファイル名を整える", systemImage: "pencil.line") }
                    .help("保存した曲をチャンネルごとに並べて、検索・置換で名前を付け直す（⌘R）")
                if model.jobs.contains(where: { !$0.isActive }) {
                    Button("終わったものを消す") { model.clearFinished() }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .dropDestination(for: String.self) { items, _ in
            model.add(urls: items)
            return true
        }
        .onAppear {
            urlFocused = true
            // 動作確認用: 環境変数に検索語があれば、起動と同時に検索窓を開く
            if let q = ProcessInfo.processInfo.environment["CACAOTUNELIBRARY_SEARCH"], !q.isEmpty { model.search(q) }
        }
        .sheet(isPresented: $model.showSearch) {
            SearchView().environment(model)
        }
    }

    /// 入力欄の中身が URL ではない（＝検索語）
    private var isSearchText: Bool {
        let t = model.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && AppModel.extractURLs(from: t).isEmpty
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// 1 曲（1 URL）分の行
struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: DownloadJob
    @State private var showLog = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.playlistTitle != nil, let t = job.title, case .running = job.state {
                    Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let u = job.uploader {
                    Text(u).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                switch job.state {
                case .running:
                    HStack(spacing: 8) {
                        ProgressView(value: job.progress)
                            .frame(maxWidth: 220)
                        Text(job.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    Text(job.statusText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                default:
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if job.state == .done, job.errorCount > 0 {
                        Text("\(job.errorCount) 曲は保存できませんでした（\(job.lastError ?? "")）")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            buttons
        }
        .padding(.vertical, 4)
        .popover(isPresented: $showLog) {
            ScrollView {
                Text(job.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(width: 560, height: 320)
        }
    }

    private var statusLine: String {
        if job.state == .done, let f = job.files.first {
            return job.files.count > 1 ? "\(job.files.count) 曲 → \(f.deletingLastPathComponent().lastPathComponent)/" : f.lastPathComponent
        }
        return job.statusText
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor))
            if let img = job.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: job.state == .done ? "music.note" : "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            if job.state == .done {
                Button {
                    model.reveal(job)
                } label: { Image(systemName: "magnifyingglass") }
                    .help("Finder で表示")
                Button {
                    if let f = job.files.first { NSWorkspace.shared.open(f) }
                } label: { Image(systemName: "play.fill") }
                    .help("再生（既定のアプリで開く）")
            }
            if case .failed = job.state {
                Button {
                    model.retry(job)
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("やり直す")
            }
            if job.state == .done, job.errorCount > 0 {
                Button {
                    model.retry(job)
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("やり直す（再生リスト全体をもう一度）")
            }
            if job.state == .cancelled {
                Button {
                    model.retry(job)
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("やり直す")
            }
            Button {
                showLog.toggle()
            } label: { Image(systemName: "text.alignleft") }
                .help("yt-dlp の出力を見る")
                .disabled(job.log.isEmpty)
            if job.isActive {
                Button {
                    model.cancel(job)
                } label: { Image(systemName: "xmark.circle") }
                    .help("中止")
            } else {
                Button {
                    model.remove(job)
                } label: { Image(systemName: "trash") }
                    .help("一覧から消す（ファイルは残ります）")
            }
        }
        .buttonStyle(.borderless)
    }
}

/// yt-dlp / ffmpeg が見つかっているかどうか
struct ToolStatusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 6) {
            if model.toolsReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("yt-dlp \(model.ytdlpVersion ?? "") ・ ffmpeg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(missing)
                    .font(.caption)
                Button("設定…") { openSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var missing: String {
        var names: [String] = []
        if model.ytdlp == nil { names.append("yt-dlp") }
        if model.ffmpeg == nil { names.append("ffmpeg") }
        return "\(names.joined(separator: " と ")) が見つかりません。ターミナルで brew install \(names.joined(separator: " ")) を実行してください"
    }
}
