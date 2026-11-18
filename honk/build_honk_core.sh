#!/usr/bin/env bash
# sy 分支专用 build_honk_core.sh
# 与原版接口完全一致：./build_honk_core.sh [--if-needed] <arch|target_triple> [output_file] [source_dir]
# 区别：不再本地编译 Rust/Zig，而是按当前 PKG_VERSION 从上游 release 的 ipk 中提取 honk-core。
set -euo pipefail

IF_NEEDED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --if-needed) IF_NEEDED=1; shift ;;
    *) break ;;
  esac
done

TARGET_IN="${1:?usage: $0 [--if-needed] <arch|target_triple> [output_file] [source_dir]}"
OUT_FILE="${2:-}"
SRC_DIR="${3:-}"   # 兼容原接口，取 bin 模式下忽略
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$TARGET_IN" in
  x86_64|x86_64-unknown-linux-musl) ARCH=x86_64; EXPECT=x86-64 ;;
  aarch64|aarch64_generic|aarch64-unknown-linux-musl) ARCH=aarch64_generic; EXPECT=aarch64 ;;
  *) echo "ERROR: unsupported arch: $TARGET_IN" >&2; exit 1 ;;
esac

OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/files/honk-core.bin}"
case "$OUT_FILE" in /*) ;; *) OUT_FILE="$PWD/$OUT_FILE" ;; esac

# 与原版一致：已有 bin 且无 stamp，视为预编译产物，直接跳过
if [ "$IF_NEEDED" = 1 ] && [ -f "$OUT_FILE" ] && [ ! -f "$OUT_FILE.stamp" ]; then
  echo "==> using prebuilt honk-core: $OUT_FILE"
  exit 0
fi

MAKEFILE="${HONK_MAKEFILE:-$SCRIPT_DIR/Makefile}"
[ -f "$MAKEFILE" ] || { echo "ERROR: 找不到 $MAKEFILE" >&2; exit 1; }
PKG_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE" | head -n1)"
PKG_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$MAKEFILE" | head -n1)"
PKG_VERSION="${PKG_VERSION:-}"; PKG_RELEASE="${PKG_RELEASE:-1}"
[ -n "$PKG_VERSION" ] || { echo "ERROR: 读不到 PKG_VERSION" >&2; exit 1; }

RELEASE_REPO="${HONK_RELEASE_REPO:-QiuSimons/luci-app-honk}"
VER_DOT="${PKG_VERSION//\~/.}"      # 2026.11.15.a9925bd
VER_TAG="${PKG_VERSION//\~/_}"      # 2026.11.15_a9925bd
TAG="honk_${VER_TAG}-r${PKG_RELEASE}"

PAGE="https://github.com/${RELEASE_REPO}/releases/expanded_assets/$TAG"
echo "==> release: $TAG / arch: $ARCH"
ASSET_PATH="$(curl -fsSL "$PAGE" \
  | grep -o 'href="[^"]*\.ipk"' | cut -d'"' -f2 \
  | grep -F "/honk_${VER_DOT}-r${PKG_RELEASE}_${ARCH}-openwrt-" || true)"
OW_VER="${HONK_OPENWRT_VER:-}"
if [ -n "$OW_VER" ]; then
  ASSET_PATH="$(printf '%s\n' "$ASSET_PATH" | grep -F -- "-openwrt-${OW_VER}.ipk" || true)"
fi
ASSET_PATH="$(printf '%s\n' "$ASSET_PATH" | head -n1)"
[ -n "$ASSET_PATH" ] || {
  echo "ERROR: 找不到 $TAG / $ARCH 的 ipk。可能该版本 release 尚未发布。" >&2
  echo "       https://github.com/${RELEASE_REPO}/releases" >&2
  exit 1
}

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/honk-ipk"
mkdir -p "$CACHE_DIR"
IPK="$CACHE_DIR/$(basename "$ASSET_PATH")"
if [ ! -s "$IPK" ]; then
  echo "==> 下载 $(basename "$ASSET_PATH")"
  curl -fL --retry 3 --retry-delay 2 -o "$IPK.part" "https://github.com${ASSET_PATH}"
  mv "$IPK.part" "$IPK"
fi

TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT
if tar -tf "$IPK" >/dev/null 2>&1; then
  DATA_MEMBER="$(tar -tf "$IPK" | grep -E '(^|/)data\.tar\.' | head -n1)"
  BIN_MEMBER="$(tar -xOf "$IPK" "$DATA_MEMBER" | tar -tzf - | grep -E '(^|/)usr/bin/honk-core$' | head -n1)"
else
  (cd "$TMP_DIR" && ar x "$IPK")
  DATA_MEMBER="$(ls "$TMP_DIR"/data.tar.* | head -n1)"
  BIN_MEMBER="$(tar -tf "$DATA_MEMBER" | grep -E '(^|/)usr/bin/honk-core$' | head -n1)"
fi
[ -n "${BIN_MEMBER:-}" ] || { echo "ERROR: ipk 里找不到 usr/bin/honk-core" >&2; exit 1; }

mkdir -p "$(dirname "$OUT_FILE")"
tar -xOf "$IPK" "$DATA_MEMBER" | tar -xzOf - "$BIN_MEMBER" > "$OUT_FILE" \
  2>/dev/null || tar -xOf "$DATA_MEMBER" "$BIN_MEMBER" > "$OUT_FILE"
chmod +x "$OUT_FILE"
# 不生成 .stamp，这样后续 --if-needed 会持续走预编译分支
rm -f "$OUT_FILE.stamp" 2>/dev/null || true

FILE_DESC="$(file -b "$OUT_FILE")"
case "$FILE_DESC" in
  ELF*) ;;
  *) echo "ERROR: 产物不是 ELF: $FILE_DESC" >&2; exit 1 ;;
esac
case "$FILE_DESC" in
  *"$EXPECT"*) ;;
  *) echo "ERROR: 产物架构不匹配（期望 $EXPECT）: $FILE_DESC" >&2; exit 1 ;;
esac
case "$FILE_DESC" in
  *"statically linked"*) ;;
  *) echo "ERROR: 产物不是静态链接: $FILE_DESC" >&2; exit 1 ;;
esac

echo "==> 完成: $OUT_FILE"
echo "==> $FILE_DESC"
ls -lh "$OUT_FILE"
