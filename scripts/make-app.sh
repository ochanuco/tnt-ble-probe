#!/bin/bash
# SwiftPM でビルドした実行ファイルを .app バンドルへ組み立てる。
# Finder から起動できるようになり、Bluetooth の許可もアプリ単位で扱える。
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG" --product bc768-app

APP=".build/BC-768.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/bc768-app" "$APP/Contents/MacOS/bc768-app"
cp Sources/BC768App/Info.plist "$APP/Contents/Info.plist"

echo "作成しました: $ROOT/$APP"
echo "起動: open $APP"
