#!/usr/bin/env bash
# 构建 TransAudio.app
# 用法：./scripts/build.sh [输出目录，默认 ./dist]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="TransAudio"
OUT="${1:-dist}"
BUNDLE="$OUT/$APP.app"

APP_BUILD="$ROOT/.build/app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$APP_BUILD"

echo "==> 编译原生 PCM 环形缓冲"
clang -std=c11 -O3 -Wall -Wextra -Werror \
  -target arm64-apple-macos13.0 \
  -c "$ROOT/scripts/PCMRingBuffer.c" \
  -o "$APP_BUILD/PCMRingBuffer.o"

echo "==> 编译 Swift 源码"
swiftc -O -target arm64-apple-macos14.0 \
  -import-objc-header "$ROOT/scripts/BridgingHeader.h" \
  -o "$BUNDLE/Contents/MacOS/PhoneAudio" \
  "$ROOT/scripts/Main.swift" \
  "$ROOT/scripts/OnboardingWindow.swift" \
  "$ROOT/scripts/DeviceStrip.swift" \
  "$ROOT/scripts/CoreAudioPlayer.swift" \
  "$APP_BUILD/PCMRingBuffer.o"

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
  if [ ! -x "$BUNDLE/Contents/Resources/scrcpy/scrcpy-coreaudio" ]; then
    echo "!! 未找到 scrcpy-coreaudio，当前包只能明确选择 Legacy"
  fi
  if [ ! -f "$BUNDLE/Contents/Resources/scrcpy/scrcpy-server" ]; then
    echo "!! 未找到官方 scrcpy-server" >&2
    exit 1
  fi
else
  echo "!! 未找到 scrcpy，App 构建完成后需按 README 把 scrcpy 放到 ~/scrcpy 或 App 内"
fi

echo "==> 由内到外临时签名"
if [ -d "$BUNDLE/Contents/Resources/scrcpy" ]; then
  for helper in adb scrcpy scrcpy-coreaudio; do
    HELPER="$BUNDLE/Contents/Resources/scrcpy/$helper"
    if [ -x "$HELPER" ]; then
      codesign --force --sign - "$HELPER" >/dev/null
    fi
  done
fi
codesign --force --sign - "$BUNDLE" >/dev/null

echo "==> 完成：$BUNDLE"
