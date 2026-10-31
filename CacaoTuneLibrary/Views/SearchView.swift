import SwiftUI

/// YouTube の検索結果（入力欄に URL でない文字を入れて Return すると開く）
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("曲名・アーティスト名・チャンネル名", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.search(query) }
                Button("検索") { model.search(query) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || model.isSearching)
            }
            .padding()

            Divider()

            if model.isSearching && model.searchResults.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("「\(model.searchQuery)」を YouTube で検索しています…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = model.searchError, model.searchResults.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(e).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.searchResults) { r in
                        SearchRow(result: r)
                    }
                    HStack {
                        Spacer()
                        if model.isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("もっと見る") { model.search(model.searchQuery, more: true) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("追加した曲は、閉じたあとメインの一覧で保存が進みます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 420, idealHeight: 560)
        .onAppear {
            query = model.searchQuery
            focused = true
        }
    }
}

struct SearchRow: View {
    @Environment(AppModel.self) private var model
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.thumbnailURL) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .quaternaryLabelColor)
                }
            }
            .frame(width: 80, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let c = result.channel { Text(c) }
                    if !result.detail.isEmpty {
                        if result.channel != nil { Text("・") }
                        Text(result.detail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if model.isQueued(result) {
                Label("追加済み", systemImage: "checkmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    model.add(result: result)
                } label: { Label("追加", systemImage: "plus") }
                    .disabled(!model.toolsReady)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("YouTube で開く") {
                if let u = URL(string: result.url) { NSWorkspace.shared.open(u) }
            }
        }
    }
}
