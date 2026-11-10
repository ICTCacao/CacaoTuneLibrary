import SwiftUI
import AppKit

/// 保存した曲をチャンネルごとに並べ、検索・置換で名前を作って、最後にまとめて書き換える
struct RenameView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: RenameModel?
    @State private var confirmCommit = false

    var body: some View {
        Group {
            if let model {
                RenameBody(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if model == nil {
                let m = RenameModel(folder: appModel.folder)
                m.scan()
                model = m
            }
        }
    }
}

private struct RenameBody: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: RenameModel
    @State private var confirmCommit = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 検索・置換
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("検索", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .onSubmit { model.applyReplace() }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("置換（空なら削除）", text: $model.replacement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.applyReplace() }
                    Button("置換") { model.applyReplace() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.search.isEmpty)
                }
                HStack(spacing: 14) {
                    Toggle("正規表現", isOn: $model.useRegex)
                    Toggle("大文字小文字を区別しない", isOn: $model.ignoreCase)
                    Picker("対象", selection: $model.scope) {
                        Text("すべてのチャンネル").tag("")
                        ForEach(model.channels, id: \.self) { ch in
                            Text(RenameModel.label(for: ch)).tag(ch)
                        }
                    }
                    .frame(maxWidth: 320)
                    Spacer()
                    Button("すべて元に戻す") { model.resetAll() }
                        .disabled(model.changedCount == 0)
                }
                if let e = model.regexError {
                    Text(e).font(.caption).foregroundStyle(.red)
                } else {
                    Text("置換は「新しい名前」に対してかかるので、何度でも重ねられます。例: 正規表現で「【.*?】」→ 空。ファイル名の末尾の動画 ID「 [xxxxxxxxxxx]」は隠してあり、更新のとき自動で付け直します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            // チャンネルごとの一覧
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("保存先に m4a / mp3 がありません").foregroundStyle(.secondary)
                    Text((model.folder.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.scope.isEmpty ? model.channels : [model.scope], id: \.self) { ch in
                        Section {
                            ForEach(model.items(in: ch)) { item in
                                RenameRow(item: item, model: model)
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

            Divider()

            // 足元
            HStack {
                Button {
                    model.scan()
                } label: { Label("読み直す", systemImage: "arrow.clockwise") }
                if !model.items(in: "").isEmpty {
                    Button {
                        appModel.sortIntoChannelFolders { model.scan() }
                    } label: { Label("直下の曲をチャンネルに振り分ける", systemImage: "folder.badge.gearshape") }
                        .help("直下にある曲を、埋め込んだチャンネル名のフォルダへ移します")
                }
                Text((model.folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let r = model.lastResult {
                    Text(r.split(separator: "\n").first.map(String.init) ?? r)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.errorCount > 0 {
                    Label("\(model.errorCount) 件に問題", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
                Text(model.changedCount == 0 ? "変更なし" : "\(model.changedCount) 件を変更")
                    .foregroundStyle(.secondary)
                Button("更新") { confirmCommit = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.changedCount == 0 || model.errorCount > 0)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { searchFocused = true }
        .alert("\(model.changedCount) 件のファイル名を書き換えます", isPresented: $confirmCommit) {
            Button("更新") { model.commit() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("曲の中のタイトル（タグ）はそのままです。元に戻すにはもう一度名前を付け直してください。")
        }
    }
}

private struct RenameRow: View {
    @Bindable var item: RenameItem
    let model: RenameModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let img = item.icon {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    TextField("新しい名前", text: $item.newBase)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .onChange(of: item.newBase) { model.validate() }
                    if !item.idSuffix.isEmpty {
                        Text("[ID]").font(.caption).foregroundStyle(.tertiary).help("動画 ID\(item.idSuffix) は隠してあります。更新のとき自動で付きます")
                    }
                    Text(".\(item.ext)").foregroundStyle(.secondary)
                }
                if item.isChanged {
                    Text("元: \(item.originalBase)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let e = item.error {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if item.isChanged {
                Button {
                    model.reset(item)
                } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("この行を元に戻す")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Finder で表示")
        }
        .padding(.vertical, 2)
        .background(item.isChanged ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}
