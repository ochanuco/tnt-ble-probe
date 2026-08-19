#!/bin/bash
# SwiftPM でビルドした実行ファイルを .app バンドルへ組み立てる。
#
#   ./scripts/make-app.sh                 debug ビルドで .build/BC-768.app を作る
#   ./scripts/make-app.sh release         release ビルド
#   ./scripts/make-app.sh release --install  ~/Applications へ入れる
#
# Bluetooth の許可について:
#   SwiftPM が付ける ad-hoc 署名はビルドのたびに変わる。macOS はアプリを署名で
#   識別するため、再ビルドすると許可が無効になり「Bluetooth の使用が許可されていません」
#   と出る。BC768_SIGN_IDENTITY に署名 ID を渡すと署名が安定し、この問題が起きなくなる。
#
#   例: BC768_SIGN_IDENTITY="Developer ID Application: ..." ./scripts/make-app.sh release
#
#   証明書が無い場合は --install で ~/Applications に置き、そこから起動して許可すると
#   入れ替えるまでは許可が保たれる。
set -euo pipefail

CONFIG="debug"
INSTALL="no"
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --install) INSTALL="yes" ;;
        *) echo "不明な引数: $arg" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product bc768-app

APP=".build/BC-768.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/bc768-app" "$APP/Contents/MacOS/bc768-app"
cp Sources/BC768App/Info.plist "$APP/Contents/Info.plist"

if [ -n "${BC768_SIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --sign "$BC768_SIGN_IDENTITY" "$APP"
    echo "署名しました: $BC768_SIGN_IDENTITY"
else
    echo "注意: ad-hoc 署名のままです。再ビルドすると Bluetooth の許可が外れます。"
fi

if [ "$INSTALL" = "yes" ]; then
    DEST="$HOME/Applications/BC-768.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "入れました: $DEST"
    echo "起動: open \"$DEST\""
else
    echo "作成しました: $ROOT/$APP"
    echo "起動: open $APP"
fi
