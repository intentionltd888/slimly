#!/bin/bash
# vendor-fetch.sh — 準備自帶引擎：Ghostscript（官方原始碼、SHA-512 核對、自己編成單一執行檔）→ vendor/bin/gs
#
# 為什麼自己編：Homebrew 的 gs 連著一串 /opt/homebrew 的動態庫，別人的 Mac 沒有；官方原始碼附的第三方庫
# （jpeg／png／zlib／freetype／lcms2／openjpeg／jbig2dec／tiff）全部靜態編進去，字型與 PostScript 資源也編進執行檔
# （COMPILE_INITS 預設開），成品只連 macOS 內建的 libSystem 與 libiconv——全新電腦零輔助程式就能跑。
# 用法：bash scripts/vendor-fetch.sh            （約 3 分鐘；工作區在 ~/Library/Caches/slimly-build）
#       SLIMLY_GS_FROM=<已編好的 gs> bash scripts/vendor-fetch.sh   （直接複製，會核對版本）
set -euo pipefail
cd "$(dirname "$0")/.."

GS_VER="10.08.0"
GS_TAG="gs10080"
GS_SHA512="8006e2a32d03759a905b9548bdd83d4563173041006750e17e428b9eea24ad519aa4452ceecd7c073d3c420a68bf1b07ccc9e0533b1a05935f6b39ea8d9ce875"
URL="https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/$GS_TAG/ghostscript-$GS_VER.tar.xz"
mkdir -p vendor/bin

if [ -n "${SLIMLY_GS_FROM:-}" ]; then
  v=$("$SLIMLY_GS_FROM" --version)
  [ "$v" = "$GS_VER" ] || { echo "✕ $SLIMLY_GS_FROM 是 ${v}，不是 $GS_VER"; exit 1; }
  cp "$SLIMLY_GS_FROM" vendor/bin/gs
  echo "✅ vendor/bin/gs ← ${SLIMLY_GS_FROM}（${v}）"; exit 0
fi

WORK="$HOME/Library/Caches/slimly-build/vendor-$GS_VER-$(date +%Y%m%d%H%M%S)"
mkdir -p "$WORK"
TAR="$HOME/Library/Caches/slimly-build/ghostscript-$GS_VER.tar.xz"
[ -f "$TAR" ] || curl -fsSL -o "$TAR" "$URL"
echo "$GS_SHA512  $TAR" | shasum -a 512 -c - >/dev/null || { echo "✕ SHA-512 對不上：$TAR"; exit 1; }
tar xf "$TAR" -C "$WORK"
cd "$WORK/ghostscript-$GS_VER"
export MACOSX_DEPLOYMENT_TARGET=12.0 PKG_CONFIG=/usr/bin/false      # 不准撿 Homebrew 的庫
CFLAGS="-O2 -arch arm64 -mmacosx-version-min=12.0" LDFLAGS="-arch arm64 -mmacosx-version-min=12.0" \
./configure --disable-cups --disable-dbus --disable-gtk --disable-fontconfig --disable-contrib --without-x \
  --without-tesseract --without-libidn --without-libpaper --without-ijs --without-pdftoraster --without-urf \
  --without-so --without-cal --with-drivers=FILES > configure.log 2>&1
# --with-drivers=FILES：要含 pdfwrite（只給 PNG,JPEG 會把 pdfwrite 排掉，連結時缺 arcfour）
make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1
DEPS=$(otool -L bin/gs | tail -n +2 | awk '{print $1}' | grep -v -E '^/usr/lib/|^/System/' || true)
[ -z "$DEPS" ] || { echo "✕ gs 連到系統以外的庫：$DEPS"; exit 1; }
cd - >/dev/null
cp "$WORK/ghostscript-$GS_VER/bin/gs" vendor/bin/gs
echo "✅ vendor/bin/gs（Ghostscript $(vendor/bin/gs --version)，$(du -h vendor/bin/gs | cut -f1)，只連系統庫）"
