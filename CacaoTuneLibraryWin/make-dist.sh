#!/bin/zsh
# Windows 版の配布物を作る。使い方: ./make-dist.sh [x64|arm64] [--no-build]（省略時は x64）
# Mac 上で cargo-xwin を使ってクロスビルドしてから詰める（--no-build でビルドを飛ばす。
# その場合は src-tauri/target にある前回の exe をそのまま詰めるので、版がずれていないか注意）。
# → ../dist/CacaoTuneLibrary-<version>-Windows-<arch>-setup.exe（インストーラ）と
#   ../dist/CacaoTuneLibrary-<version>-Windows-<arch>.zip（exe だけ。展開してそのまま動く）
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")"
arch=x64; build=1
for a in "$@"; do
  case $a in
    x64|arm64) arch=$a ;;
    --no-build) build=0 ;;
    *) echo "使い方: ./make-dist.sh [x64|arm64] [--no-build]"; exit 1 ;;
  esac
done
case $arch in
  x64) triple=x86_64-pc-windows-msvc; note="Intel / AMD の Windows 用" ;;
  arm64) triple=aarch64-pc-windows-msvc; note="ARM 版 Windows 用（Mac の仮想マシンなど）" ;;
esac
ver=$(sed -n 's/.*"version": "\(.*\)",/\1/p' src-tauri/tauri.conf.json | head -1)
rel=src-tauri/target/$triple/release
if (( build )); then
  echo "== $arch をクロスビルド（$ver）"
  PATH="/opt/homebrew/opt/llvm/bin:$PATH" npm run tauri build -- --runner cargo-xwin --target $triple --bundles nsis
fi
# 詰める exe が今の版か確かめる（tauri.conf.json の窓タイトルが埋め込まれている）
if ! LC_ALL=C grep -aqF "Windows 版 $ver" "$rel/cacaotunelibrarywin.exe"; then
  echo "exe の版が $ver ではありません（古いビルド）。--no-build を外して作り直してください: $rel"; exit 1
fi
setup=$(ls $rel/bundle/nsis/*-setup.exe | head -1)
[[ -f "$setup" ]] || { echo "setup.exe が見つかりません（先にビルド）: $rel"; exit 1; }
mkdir -p ../dist
rm -f ../dist/CacaoTuneLibrary-*-Windows-$arch-setup.exe ../dist/CacaoTuneLibrary-*-Windows-$arch.zip
cp "$setup" "../dist/CacaoTuneLibrary-$ver-Windows-$arch-setup.exe"
tmp=$(mktemp -d)
mkdir "$tmp/CacaoTuneLibrary"
cp "$rel/cacaotunelibrarywin.exe" "$tmp/CacaoTuneLibrary/CacaoTuneLibrary.exe"
cat > "$tmp/CacaoTuneLibrary/README.txt" <<TXT
CacaoTuneLibrary $ver（Windows 版・$arch: $note）

CacaoTuneLibrary.exe をダブルクリックで起動します（インストール不要）。
Windows 10 / 11。WebView2 が必要です（Windows 11 と、更新された Windows 10 には入っています）。

最初に開くとき SmartScreen の警告が出たら「詳細情報」→「実行」を押してください（署名していないため）。
起動したら、窓の下の「GitHub から用意する」を押すと、yt-dlp・ffmpeg・deno を自動で取ってきます。

自分で聴くためだけにお使いください。
https://github.com/ICTCacao/CacaoTuneLibrary
TXT
(cd "$tmp" && zip -qr "$OLDPWD/../dist/CacaoTuneLibrary-$ver-Windows-$arch.zip" CacaoTuneLibrary)
rm -rf "$tmp"
ls -la ../dist/CacaoTuneLibrary-$ver-Windows-$arch*
