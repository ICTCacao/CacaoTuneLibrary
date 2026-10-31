#!/bin/zsh
# バージョンを 0.0.1 上げる（例: 1.0.0 → 1.0.1）。配布用ビルド（dist に置くもの）の前に毎回実行する。
# 引数でバージョンを指定すればその値にする（例: ./bump-version.sh 2.0.0）。
set -euo pipefail
cd "$(dirname "$0")"
cur=$(sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml | head -1)
if [[ $# -ge 1 ]]; then
  new=$1
else
  parts=(${(s:.:)cur})
  new="${parts[1]}.${parts[2]}.$(( parts[3] + 1 ))"
fi
sed -i '' "s/\"$cur\"/\"$new\"/" project.yml
[[ -f CacaoTuneLibrary/Resources/Info.plist ]] && sed -i '' "s|<string>$cur</string>|<string>$new</string>|" CacaoTuneLibrary/Resources/Info.plist
# Windows 版（Tauri）も同じ版に
W=CacaoTuneLibraryWin
[[ -f $W/package.json ]] && sed -i '' "s/\"version\": \"$cur\"/\"version\": \"$new\"/" $W/package.json
[[ -f $W/src-tauri/tauri.conf.json ]] && sed -i '' -e "s/\"version\": \"$cur\"/\"version\": \"$new\"/" -e "s/Windows 版 $cur/Windows 版 $new/" $W/src-tauri/tauri.conf.json
[[ -f $W/src-tauri/Cargo.toml ]] && sed -i '' "s/^version = \"$cur\"/version = \"$new\"/" $W/src-tauri/Cargo.toml
echo "$cur → $new"
