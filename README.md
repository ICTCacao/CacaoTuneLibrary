# CacaoTuneLibrary

YouTube の URL を貼り付けると、音声だけを **m4a（または mp3）** にして、チャンネルごとの棚（フォルダ）に並べる Mac アプリ。
カバーやアレンジ曲を自分で聴くための道具。実作業は Homebrew の `yt-dlp` と `ffmpeg` に任せている。
（1.0.7 までは CacaoYT2Music という名前だった。設定は引き継ぐ）

| できること | 中身 |
|---|---|
| URL → m4a | 元の AAC 音声をそのまま取り出す（劣化なし） |
| URL → mp3 | 最高品質（VBR）に変換 |
| 曲情報 | タイトル・チャンネル名を埋め込む |
| カバー画像 | YouTube のサムネイル（16:9）を、幅はそのまま上下をぼかしで埋めて正方形にして埋め込む。保存したファイルの **Finder アイコン** にも使う |
| まとめて | 複数 URL・再生リスト（設定で全曲）・ドラッグ＆ドロップ・クリップボード（⇧⌘V） |

**Windows 版**（Windows 10 / 11）もある（`CacaoTuneLibraryWin/`）。できることは同じで、yt-dlp・ffmpeg・deno は
アプリが初回に GitHub から取ってくる（Homebrew は要らない）。保存した曲のカバー画像は、エクスプローラがそのままサムネイルに使う。

## 入手

[Releases](https://github.com/ICTCacao/CacaoTuneLibrary/releases) から落とす。

- **Mac**: `CacaoTuneLibrary-<version>.dmg`。中のアプリを Applications へドラッグする。署名していないので、初回は Applications 内のアプリを
  右クリック →「開く」で起動する（macOS 14 以降）
- **Windows**: `CacaoTuneLibrary-<version>-Windows-x64-setup.exe`（インストーラ）か、`…-Windows-x64.zip`（展開してそのまま動く）。
  ARM 版 Windows（Mac の仮想マシンなど）は `…-Windows-arm64-…`。
  署名していないので、初回は SmartScreen の「詳細情報」→「実行」。起動したら窓の下の「GitHub から用意する」で yt-dlp・ffmpeg・deno を取ってくる

## 必要なもの

Mac は macOS 14 以降と、Homebrew の yt-dlp / ffmpeg。Windows はアプリが道具を用意するので、何も要らない。

```bash
brew install yt-dlp ffmpeg
```

YouTube 側の変更で保存できなくなったら、設定画面の「yt-dlp を更新」（`brew upgrade yt-dlp`）。

## 使い方

1. URL を貼って Return（または「追加」）。クリップボードに URL があれば ⇧⌘V でも追加できる。
2. 保存先は既定で `~/Music/YouTube`。「変更…」で好きな場所に。その中にチャンネル名のフォルダができ、曲はそこに入る（設定で分けないこともできる）。
3. できたら行の 🔍 で Finder に表示、▶ で再生。ミュージックのライブラリに入れるなら m4a をドラッグするだけ。

URL を追加した直後に yt-dlp で題名・チャンネル名・サムネイルだけ軽く取ってきて（1〜2 秒）、
待機中の行にも題名を出す。本番の保存が終わると、埋め込んだカバー画像に置き換わる。

再生リストの中に見られない動画（非公開・削除など）があっても、その曲だけ飛ばして残りを保存し、
行に「N 曲は保存できず」と出す。途中で失敗して jpg が保存先に残ったときは、ファイルメニューの
「保存先に残ったカバー画像（jpg）を片づける」で Finder アイコンに設定して消せる。

**ファイル名を整える**（⌘R、または窓の下のボタン）で、保存した曲をチャンネルごとに並べて名前を付け直せる。
検索・置換（正規表現も可、チャンネルを絞ることも可）で新しい名前をまとめて作り、行ごとに手で直し、
最後に「更新」で一括して書き換える。同じ名前の重複や既にあるファイルは赤く出て、直すまで更新できない。
ファイル名の末尾の動画 ID「 [xxxxxxxxxxx]」は一覧に出さず、更新のとき自動で付け直す。曲の中のタイトル（タグ）は変えない。

保存先の直下に曲がたまったとき（手でフォルダを統合したあとなど）は、ファイルメニューの
「直下の曲をチャンネルのフォルダに振り分ける」で、曲に埋め込んだチャンネル名のフォルダへまとめて移せる。

設定（⌘,）で、Finder アイコンにカバーを使うか、正方形のしかた（上下を埋める／切り抜く／そのまま）、jpg も残すか、再生リストを全曲にするか、
ファイル名に動画 ID を付けるか、yt-dlp / ffmpeg の場所を変えられる。

## 構成

```
CacaoTuneLibrary/
├── project.yml                    # XcodeGen の定義（ここから .xcodeproj を生成）
├── CacaoTuneLibrary.xcodeproj        # 生成物（xcodegen generate で再生成できる）
├── bump-version.sh                # 配布用ビルドの前に 0.0.1 上げる
├── make-dmg.sh                    # 配布用 dmg を作る（背景は dmg/make-background.swift で生成）
├── icon/make-icon.swift           # アプリアイコンを描くスクリプト
├── dist/                          # ビルド済み: *.app / *.dmg
└── CacaoTuneLibrary/                 # Mac アプリ（SwiftUI）
    ├── CacaoTuneLibraryApp.swift     # エントリ・メニュー
    ├── AppModel.swift             # キュー（1 件ずつ実行）・設定・Finder
    ├── Downloader.swift           # yt-dlp を起動し、出力を読んで進み具合に変える
    ├── CoverArt.swift             # 同名の jpg を Finder アイコンにする
    ├── Tools.swift                # yt-dlp / ffmpeg / brew の場所探し
    ├── Prefs.swift                # 設定キーと既定値
    └── Views/                     # 画面・設定
```

### yt-dlp に渡しているもの

```
-x --audio-format m4a|mp3 [--audio-quality 0]
--embed-metadata --embed-thumbnail --write-thumbnail --convert-thumbnails jpg
--ppa "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf ..."        # 正方形にする（上下をぼかしで埋める／切り抜く／なし）
--print before_dl:TITLE / UPLOADER、after_move:FILE          # 画面に出す題名とできたファイルの場所
--no-playlist | --yes-playlist
-o <保存先>/%(uploader,channel)s/%(title)s.%(ext)s   # チャンネル名のフォルダに分ける
```

`--write-thumbnail` で残った jpg を Finder アイコンに使い、使い終わったら消す（設定で残せる）。

## Windows 版

```
CacaoTuneLibraryWin/
├── src/main.ts          # 画面と、yt-dlp の出力の読み取り（Mac 版の AppModel / Downloader / RenameModel と同じ考え方）
├── src/styles.css
├── src-tauri/src/lib.rs # yt-dlp / ffmpeg / curl / tar の起動、保存先の読み取り、ファイルの移動
├── src-tauri/tauri.conf.json
└── make-dist.sh         # ../dist に setup.exe と zip を置く
```

土台は Tauri 2（画面は Windows 付属の WebView2）。ScenarioWriterWin・CacaoSoundCuesWin と同じ作り。
道具は `%LOCALAPPDATA%\com.ictcacao.cacaotunelibrarywin\tools` に置く（yt-dlp.exe、ffmpeg.exe、ffprobe.exe、deno.exe。
取得元は yt-dlp・yt-dlp/FFmpeg-Builds・denoland/deno の GitHub リリース。落とすのは Windows 付属の curl と tar）。
設定はブラウザの localStorage。Finder アイコンの処理はなく、エクスプローラが埋め込んだカバーをサムネイルに使う。

```bash
cd CacaoTuneLibraryWin
npm install
npm run tauri dev                                     # 開発モードで起動（Mac でも動く。道具は Homebrew のものを使う）
# Windows 用のインストーラを Mac で作る（brew install nsis llvm、rustup target add x86_64-pc-windows-msvc、cargo install cargo-xwin）
./make-dist.sh x64                                    # クロスビルドして ../dist/CacaoTuneLibrary-<version>-Windows-x64-setup.exe と .zip を置く
PATH="/opt/homebrew/opt/llvm/bin:$PATH" npm run tauri build -- --runner cargo-xwin --target aarch64-pc-windows-msvc --bundles nsis
./make-dist.sh arm64                                  # ARM 版 Windows 用（rustup target add aarch64-pc-windows-msvc が必要）
```

版は `./bump-version.sh` が Mac 版と一緒に上げる（package.json・tauri.conf.json・Cargo.toml）。

## ビルド

必要: Xcode、XcodeGen（`brew install xcodegen`）。

```bash
cd ~/CacaoApps/CacaoTuneLibrary
./bump-version.sh                         # 配布用ビルドのたびにバージョンを 0.0.1 上げる
xcodegen generate                         # project.yml を変えたときだけ
xcodebuild -project CacaoTuneLibrary.xcodeproj -scheme CacaoTuneLibrary -configuration Release \
  -derivedDataPath build/DerivedData build
rm -rf dist/CacaoTuneLibrary.app && cp -R build/DerivedData/Build/Products/Release/CacaoTuneLibrary.app dist/
./make-dmg.sh                             # dist/CacaoTuneLibrary-<version>.dmg
```

## 使ううえでの注意

- YouTube の利用規約は、公式の手段（YouTube Premium など）以外でのダウンロードを認めていない。自分で聴く範囲にとどめること。
- 違法にアップロードされたものだと知りながら保存するのは、日本の著作権法でも違法。公式チャンネルや演奏者本人の動画に限る。
- 保存した音源を配布する・公開する・人前で流す・公開するアプリに組み込むのは私的使用を超える。

## ライセンス

MIT License（[LICENSE](LICENSE)）。yt-dlp は Unlicense、ffmpeg は LGPL/GPL。どちらもアプリには同梱せず、Homebrew のものを使う。
