#!/usr/bin/env bash
# 构建 iTrae 手机音频接收.app
# 用法：./scripts/build.sh [输出目录，默认 ./dist]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="iTrae 手机音频接收"
OUT="${1:-dist}"
BUNDLE="$OUT/$APP.app"

mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "==> 编译 Swift 源码"
swiftc -O -target arm64-apple-macos13.0 \
  -o "$BUNDLE/Contents/MacOS/PhoneAudio" \
  "$ROOT/scripts/Main.swift"

echo "==> 拷贝资源"
cp "$ROOT/assets/icon.icns" "$BUNDLE/Contents/Resources/icon.icns"
cp "$ROOT/packaging/Info.plist" "$BUNDLE/Contents/Info.plist"

# 如果本地有 scrcpy，就打进 App（仓库本身不包含它）
SCRCPY_SRC=""
for d in "$ROOT/scrcpy/scrcpy-macos-aarch64-v5.0.1" "$ROOT/scrcpy"; do
  if [ -x "$d/scrcpy" ]; then SCRCPY_SRC="$d"; break; fi
done
if [ -n "$SCRCPY_SRC" ]; then
  echo "==> 打包 scrcpy: $SCRCPY_SRC"
  rm -rf "$BUNDLE/Contents/Resources/scrcpy"
  mkdir -p "$BUNDLE/Contents/Resources/scrcpy"
  cp -R "$SCRCPY_SRC/." "$BUNDLE/Contents/Resources/scrcpy/"
else
  echo "!! 未找到 scrcpy，App 构建完成后需按 README 把 scrcpy 放到 ~/scrcpy 或 App 内"
fi

echo "==> 临时签名"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || echo "!! codesign 失败（不影响本地运行）"

echo "==> 完成：$BUNDLE"
