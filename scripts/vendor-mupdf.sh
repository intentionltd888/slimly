#!/bin/bash
# vendor-mupdf.sh — 準備自帶引擎之二：MuPDF 的 mutool（官方原始碼、SHA-256 核對、自己編成單一執行檔）→ vendor/bin/mutool
#
# 用途（2.2 編輯器對齊 Acrobat）：
#   ・真正的塗黑與改字：一個字一個字把框到的字形從內容裡刪掉，其他字、線、圖原樣保留向量（不用把整頁變成圖）
#   ・之後的物件層操作（連結、書籤、欄位、清除隱藏資訊）
# 為什麼是 MuPDF：Artifex 出的（跟 Ghostscript 同一家、同一種 AGPL 授權，Slimly 已經照這個授權附原始碼聲明）；
# 它的 redaction 就是 Acrobat「套用塗黑」那一套：只刪框到的字形、圖片被框到的像素清掉。
# 第三方庫全部用原始碼包附的版本靜態編進去，成品只連 macOS 內建的庫。
# 字型：只留基本 14 種＋基本中日韓（顯示用不到，算字寬、畫註解外觀才需要），其他語系的 Noto 不編進去（體積）。
# 用法：bash scripts/vendor-mupdf.sh           （約 5 分鐘；工作區在 ~/Library/Caches/slimly-build）
set -euo pipefail
cd "$(dirname "$0")/.."

MU_VER="1.28.5"
MU_SHA256="98a5c10cda20c3992cdf76ff6b2a1149c32bd79cc796d3f703230b1185b7e934"
URL="https://casper.mupdf.com/downloads/archive/mupdf-$MU_VER-source.tar.gz"
mkdir -p vendor/bin

WORK="$HOME/Library/Caches/slimly-build/mupdf-$MU_VER-$(date +%Y%m%d%H%M%S)"
mkdir -p "$WORK"
TAR="$HOME/Library/Caches/slimly-build/mupdf-$MU_VER-source.tar.gz"
[ -f "$TAR" ] || curl -fsSL -o "$TAR" "$URL"
echo "$MU_SHA256  $TAR" | shasum -a 256 -c - >/dev/null || { echo "✕ SHA-256 對不上：$TAR"; exit 1; }
tar xzf "$TAR" -C "$WORK"
cd "$WORK/mupdf-$MU_VER-source"
export MACOSX_DEPLOYMENT_TARGET=12.0 PKG_CONFIG=/usr/bin/false
FLAGS="-O2 -arch arm64 -mmacosx-version-min=12.0 -DTOFU_CJK_EXT -DTOFU_CJK_LANG -DTOFU_EMOJI -DTOFU_HISTORIC -DTOFU_SYMBOL -DTOFU_SIL -DFZ_ENABLE_BARCODE=0"
make -j"$(sysctl -n hw.ncpu)" build=release HAVE_X11=no HAVE_GLUT=no HAVE_LIBCRYPTO=no HAVE_TESSERACT=no HAVE_LEPTONICA=no HAVE_CURL=no \
  HAVE_OBJCOPY=no USE_SYSTEM_LIBS=no XCFLAGS="$FLAGS" XLDFLAGS="-arch arm64 -mmacosx-version-min=12.0" tools > make.log 2>&1 || { tail -40 make.log; exit 1; }
DEPS=$(otool -L build/release/mutool | tail -n +2 | awk '{print $1}' | grep -v -E '^/usr/lib/|^/System/' || true)
[ -z "$DEPS" ] || { echo "✕ mutool 連到系統以外的庫：$DEPS"; exit 1; }
cd - >/dev/null
cp "$WORK/mupdf-$MU_VER-source/build/release/mutool" vendor/bin/mutool
strip -x vendor/bin/mutool 2>/dev/null || true
echo "✅ vendor/bin/mutool（MuPDF ${MU_VER}，$(du -h vendor/bin/mutool | cut -f1)，只連系統庫）"
