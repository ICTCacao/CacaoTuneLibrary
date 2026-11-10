import SwiftUI
import AppKit

/// 保存した曲の中の情報（タイトル・アーティスト・アルバムなどのタグ）を直す窓。ファイル名は変えない
struct TagView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: TagModel?

    var body: some View {
        Group {
            if let model {
                TagBody(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if model == nil {
                let m = TagModel(folder: appModel.folder, ffmpeg: appModel.ffmpeg)
                m.scan()
                // 動作確認用: CACAOTUNELIBRARY_TAGS=select なら最初の曲を選んでおく
                if ProcessInfo.processInfo.environment["CACAOTUNELIBRARY_TAGS"] == "select" { m.selection = m.items.first?.id }
                model = m
            }
        }
    }
}

private struct TagBody: View {
    @Bindable var model: TagModel
    @State private var confirmCommit = false

    var body: some View {
        VStack(spacing: 0) {
            tools.padding()
            Divider()
            if model.ffmpeg == nil {
                message("ffmpeg が見つかりません", "メイン画面の設定で「道具を用意する」を押してください")
            } else if model.items.isEmpty {
                message("保存先に m4a / mp3 がありません", (model.folder.path as NSString).abbreviatingWithTildeInPath)
            } else {
                HSplitView {
                    list.frame(minWidth: 320, idealWidth: 420)
                    detail.frame(minWidth: 340, idealWidth: 420)
                }
            }
            Divider()
            footer.padding(.horizontal).padding(.vertical, 8)
        }
        .frame(minWidth: 820, minHeight: 520)
        .alert("\(model.changedCount) 曲の情報を書き換えます", isPresented: $confirmCommit) {
            Button("書き換える") { model.commit() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ファイル名・音声・カバー画像はそのままで、曲の中のタイトルなどの情報だけを書き換えます。")
        }
    }

    // MARK: 上: 対象・検索置換・まとめて入れる

    private var tools: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("対象", selection: $model.scope) {
                    Text("すべてのチャンネル").tag("")
                    ForEach(model.channels, id: \.self) { Text(RenameModel.label(for: $0)).tag($0) }
                }
                .frame(maxWidth: 320)
                Text("\(model.targets.count) 曲").foregroundStyle(.secondary)
                Spacer()
                Button("タイトルをファイル名にそろえる") { model.titleFromFileName() }
                    .help("対象の曲のタイトルを、いまのファイル名（動画 ID なし）にします")
                Button("すべて元に戻す") { model.resetAll() }
                    .disabled(model.changedCount == 0)
            }
            HStack(spacing: 8) {
                fieldPicker($model.replaceField)
                TextField("検索", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.applyReplace() }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("置換（空なら削除）", text: $model.replacement)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.applyReplace() }
                Toggle("正規表現", isOn: $model.useRegex)
                Toggle("大小を区別しない", isOn: $model.ignoreCase)
                Button("置換") { model.applyReplace() }
                    .disabled(model.search.isEmpty)
            }
            HStack(spacing: 8) {
                fieldPicker($model.fillField)
                TextField("まとめて入れる値（空なら消す）", text: $model.fillValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.fill() }
                Button("対象すべてに入れる") { model.fill() }
            }
            if let e = model.regexError {
                Text(e).font(.caption).foregroundStyle(.red)
            } else {
                Text("ここで直すのは曲の中の情報（ミュージックや車で表示される名前）です。ファイル名は「ファイル名を整える」で。置換・まとめて入れるは「対象」の曲すべてにかかり、「書き換える」を押すまでファイルは変わりません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func fieldPicker(_ b: Binding<TagField>) -> some View {
        Picker("", selection: b) {
            ForEach(TagField.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .frame(width: 150)
    }

    // MARK: 左: 曲の一覧

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.shownChannels, id: \.self) { ch in
                Section {
                    ForEach(model.items(in: ch)) { item in
                        TagRow(item: item).tag(item.id)
                    }
                } header: {
                    HStack {
                        Image(systemName: ch.isEmpty ? "folder" : "person.crop.rectangle")
                        Text(RenameModel.label(for: ch))
                        Text("\(model.items(in: ch).count) 曲").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: 右: 選んだ曲の情報

    @ViewBuilder private var detail: some View {
        if let item = model.selected {
            TagDetail(item: item, model: model)
        } else {
            message("左の一覧から曲を選ぶと、ここで情報を直せます", nil)
        }
    }

    // MARK: 下

    private var footer: some View {
        HStack {
            Button { model.scan() } label: { Label("読み直す", systemImage: "arrow.clockwise") }
                .disabled(model.isBusy)
            if model.loading > 0 {
                ProgressView().controlSize(.small)
                Text("読み込み中… あと \(model.loading) 曲").font(.caption).foregroundStyle(.secondary)
            }
            if let w = model.writing {
                ProgressView(value: Double(w.done), total: Double(max(w.total, 1))).frame(width: 120)
                Text("書き換え中 \(w.done) / \(w.total)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let r = model.lastResult {
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.changedCount == 0 ? "変更なし" : "\(model.changedCount) 曲を変更")
                .foregroundStyle(.secondary)
            Button("書き換える") { confirmCommit = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.changedCount == 0 || model.isBusy)
        }
    }

    private func message(_ title: String, _ sub: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            if let sub { Text(sub).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TagRow: View {
    let item: TagItem

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let img = item.icon {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).lineLimit(1)
                    .fontWeight(item.isChanged ? .semibold : .regular)
                Text(item.loaded ? (item.value(.artist).isEmpty ? "（アーティストなし）" : item.value(.artist))
                        + (item.value(.album).isEmpty ? "" : " — " + item.value(.album)) : "読み込み中…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let e = item.error {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if item.isChanged {
                Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor)
                    .help("変更あり（まだ書き込んでいません）")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TagDetail: View {
    @Bindable var item: TagItem
    let model: TagModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let img = item.icon {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ファイル名").font(.caption).foregroundStyle(.secondary)
                        Text(item.url.lastPathComponent).textSelection(.enabled).lineLimit(3)
                        HStack {
                            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Button("この曲を元に戻す") { model.reset(item) }.disabled(!item.isChanged)
                        }
                        .controlSize(.small)
                    }
                }
                if !item.loaded {
                    ProgressView("読み込み中…")
                } else {
                    ForEach(TagField.allCases) { f in field(f) }
                }
            }
            .padding()
        }
    }

    private func binding(_ f: TagField) -> Binding<String> {
        Binding(get: { item.values[f] ?? "" }, set: { item.values[f] = $0 })
    }

    @ViewBuilder private func field(_ f: TagField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(f.label).font(.caption).foregroundStyle(.secondary)
                if item.isChanged(f) {
                    Text("変更").font(.caption2).foregroundStyle(Color.accentColor)
                    Spacer()
                    Button("元に戻す") { item.values[f] = item.original[f] }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            if f.isLong {
                TextEditor(text: binding(f))
                    .font(.body)
                    .frame(height: f == .description ? 140 : 54)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            } else {
                TextField(f.label, text: binding(f)).textFieldStyle(.roundedBorder)
            }
        }
    }
}
