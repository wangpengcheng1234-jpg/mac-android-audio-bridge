#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
REAL_BUILD="$ROOT/.build"
BUILD_LINK="/private/tmp/itrae-mac-audio-coreaudio-build"
mkdir -p "$REAL_BUILD"
if [ -L "$BUILD_LINK" ]; then
    if [ "$(readlink "$BUILD_LINK")" != "$REAL_BUILD" ]; then
        echo "!! $BUILD_LINK 已指向其他目录，停止。" >&2
        exit 1
    fi
elif [ -e "$BUILD_LINK" ]; then
    echo "!! $BUILD_LINK 已存在且不是符号链接，停止。" >&2
    exit 1
else
    ln -s "$REAL_BUILD" "$BUILD_LINK"
fi
# FFmpeg 不支持带空格的绝对源码路径；别名不复制文件，实际占用仍只在 .build。
BUILD="$BUILD_LINK"
DOWNLOADS="$BUILD/downloads"
SOURCES="$BUILD/src"
PREFIX="$BUILD/prefix"
VENV="$BUILD/tools/venv"
PATCH="$ROOT/packaging/scrcpy-5.0.1-coreaudio.patch"
SCRCPY_VERSION=5.0.1
SDL_VERSION=3.4.18
FFMPEG_VERSION=9.0.2
MAX_KB=$((4 * 1024 * 1024))

mkdir -p "$DOWNLOADS" "$SOURCES" "$PREFIX" "$BUILD/tools"

check_budget() {
    local used
    used=$(du -sk "$REAL_BUILD" | cut -f1)
    echo "==> .build usage: ${used} KB"
    if [ "$used" -gt "$MAX_KB" ]; then
        echo "!! 构建目录超过 4GB，停止。" >&2
        exit 1
    fi
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(shasum -a 256 "$file" | cut -d ' ' -f1)
    if [ "$actual" != "$expected" ]; then
        echo "!! SHA256 不匹配：$file" >&2
        exit 1
    fi
}

download() {
    local url="$1"
    local file="$2"
    local sha256="$3"
    if [ ! -f "$file" ]; then
        curl -fLsS "$url" -o "$file"
    fi
    verify_sha256 "$file" "$sha256"
}

check_budget

if [ ! -x "$VENV/bin/meson" ] || [ ! -x "$VENV/bin/cmake" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip install --disable-pip-version-check \
        meson==1.7.2 ninja==1.13.2 cmake==3.31.6 pkgconf==2.3.0.post2
fi

PKG_CONFIG=$("$VENV/bin/python" -c 'import os, pkgconf; print(os.path.join(os.path.dirname(pkgconf.__file__), ".bin", "pkgconf"))')
export PKG_CONFIG
export PATH="$VENV/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset PKG_CONFIG_PATH || true
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
check_budget

SCRCPY_ARCHIVE="$DOWNLOADS/scrcpy-v$SCRCPY_VERSION.tar.gz"
SDL_ARCHIVE="$DOWNLOADS/sdl-$SDL_VERSION.tar.gz"
FFMPEG_ARCHIVE="$DOWNLOADS/ffmpeg-$FFMPEG_VERSION.tar.xz"
download "https://codeload.github.com/Genymobile/scrcpy/tar.gz/refs/tags/v$SCRCPY_VERSION" \
    "$SCRCPY_ARCHIVE" "a24b996ac23d0f674d3237c00b39a97829d8acbe9e1657a6c216fd51ea488ee5"
download "https://github.com/libsdl-org/SDL/archive/refs/tags/release-$SDL_VERSION.tar.gz" \
    "$SDL_ARCHIVE" "c4b08b950bd29d83caae0ab8d884298d27046a9d30700fb42841c50992665c90"
download "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
    "$FFMPEG_ARCHIVE" "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"

SCRCPY_SRC="$SOURCES/scrcpy-$SCRCPY_VERSION"
SDL_SRC="$SOURCES/sdl-$SDL_VERSION"
FFMPEG_SRC="$SOURCES/ffmpeg-$FFMPEG_VERSION"
if [ ! -d "$SCRCPY_SRC" ]; then
    tar -xf "$SCRCPY_ARCHIVE" -C "$SOURCES"
fi
if [ ! -d "$SDL_SRC" ]; then
    tar -xf "$SDL_ARCHIVE" -C "$SOURCES"
    mv "$SOURCES/SDL-release-$SDL_VERSION" "$SDL_SRC"
fi
if [ ! -d "$FFMPEG_SRC" ]; then
    tar -xf "$FFMPEG_ARCHIVE" -C "$SOURCES"
fi
check_budget

if patch -d "$SCRCPY_SRC" -p1 --batch --forward --dry-run < "$PATCH" >/dev/null 2>&1; then
    patch -d "$SCRCPY_SRC" -p1 --batch --forward < "$PATCH"
elif patch -d "$SCRCPY_SRC" -p1 --batch -R --dry-run < "$PATCH" >/dev/null 2>&1; then
    echo "==> CoreAudio patch already applied"
else
    echo "!! scrcpy 源码与固定补丁不匹配。" >&2
    exit 1
fi

# 使用独立目录，避免复用早期包含中文/空格绝对路径的 CMakeCache 和 sdl3.pc。
SDL_BUILD="$BUILD/sdl-coreaudio"
cmake -S "$SDL_SRC" -B "$SDL_BUILD" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DSDL_TESTS=OFF \
    -DBUILD_SHARED_LIBS=OFF
cmake --build "$SDL_BUILD" -j"$(getconf _NPROCESSORS_ONLN)"
cmake --install "$SDL_BUILD"
check_budget

FFMPEG_BUILD="$BUILD/ffmpeg"
mkdir -p "$FFMPEG_BUILD"
if [ ! -f "$FFMPEG_BUILD/config.h" ]; then
    (
        cd "$FFMPEG_BUILD"
        "$FFMPEG_SRC/configure" \
            --prefix="$PREFIX" \
            --pkg-config="$PKG_CONFIG" \
            --pkg-config-flags="--static" \
            --extra-cflags="-O2 -fPIC -mmacosx-version-min=13.0" \
            --extra-ldflags="-mmacosx-version-min=13.0" \
            --disable-programs \
            --disable-doc \
            --disable-debug \
            --disable-swscale \
            --disable-avfilter \
            --disable-network \
            --disable-everything \
            --disable-vulkan \
            --disable-vdpau \
            --disable-avdevice \
            --disable-vaapi \
            --enable-swresample \
            --enable-decoder=h264 \
            --enable-decoder=hevc \
            --enable-decoder=vp8 \
            --enable-decoder=vp9 \
            --enable-decoder=pcm_s16le \
            --enable-decoder=opus \
            --enable-decoder=aac \
            --enable-decoder=flac \
            --enable-decoder=png \
            --enable-protocol=file \
            --enable-demuxer=image2 \
            --enable-parser=png \
            --enable-zlib \
            --enable-muxer=matroska \
            --enable-muxer=mp4 \
            --enable-muxer=opus \
            --enable-muxer=flac \
            --enable-muxer=wav \
            --enable-videotoolbox \
            --enable-hwaccel=h264_videotoolbox \
            --enable-hwaccel=hevc_videotoolbox \
            --enable-hwaccel=vp9_videotoolbox \
            --enable-static \
            --disable-shared
    )
fi
make -C "$FFMPEG_BUILD" -j"$(getconf _NPROCESSORS_ONLN)"
make -C "$FFMPEG_BUILD" install
check_budget

CLIENT_BUILD="$BUILD/scrcpy-coreaudio"
MESON_ARGS=(
    --buildtype=release
    --strip
    -Db_lto=true
    -Dcompile_server=false
    -Dportable=true
    -Dstatic=true
    -Dusb=false
    -Dv4l2=false
    -Dvaapi=false
    -Dc_args="-I$PREFIX/include -mmacosx-version-min=13.0"
    -Dc_link_args="-L$PREFIX/lib -mmacosx-version-min=13.0"
)
if [ -f "$CLIENT_BUILD/meson-info/meson-info.json" ]; then
    meson setup "$CLIENT_BUILD" "$SCRCPY_SRC" --reconfigure "${MESON_ARGS[@]}"
else
    meson setup "$CLIENT_BUILD" "$SCRCPY_SRC" "${MESON_ARGS[@]}"
fi
ninja -C "$CLIENT_BUILD"

OUT_DIR="$ROOT/scrcpy/scrcpy-macos-aarch64-v5.0.1"
mkdir -p "$OUT_DIR"
cp "$CLIENT_BUILD/app/scrcpy" "$OUT_DIR/scrcpy-coreaudio"
file "$OUT_DIR/scrcpy-coreaudio"
otool -L "$OUT_DIR/scrcpy-coreaudio"
LINKS=$(otool -L "$OUT_DIR/scrcpy-coreaudio")
case "$LINKS" in
    *"/opt/homebrew/"*|*"/usr/local/"*)
        echo "!! 客户端仍依赖开发机动态库。" >&2
        exit 1
        ;;
esac
case "$(file "$OUT_DIR/scrcpy-coreaudio")" in
    *"arm64"*) ;;
    *)
        echo "!! 客户端不是 arm64。" >&2
        exit 1
        ;;
esac
check_budget
echo "==> 完成：$OUT_DIR/scrcpy-coreaudio"
