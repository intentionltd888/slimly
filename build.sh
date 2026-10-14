#!/bin/bash
# Slimly — build：編譯 → 組 .app → 介面與引擎 → icon → 簽名
# 產出 build/Slimly.app。DMG：bash scripts/make-dmg.sh　公證：bash scripts/notarize.sh　全部一次：bash release.sh
# 全程不刪檔（覆蓋式重建）。第一次建置前先跑 bash scripts/vendor-fetch.sh（編出自帶的 Ghostscript）。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Slimly"
BUILD="${SLIMLY_BUILD_DIR:-build}"
APP="$BUILD/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)
BLD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" app/Info.plist)
[ -x vendor/bin/gs ] || { echo "✕ vendor/bin/gs 還沒準備好——先跑 bash scripts/vendor-fetch.sh"; exit 1; }
[ -x vendor/bin/mutool ] || { echo "✕ vendor/bin/mutool 還沒準備好——先跑 bash scripts/vendor-mupdf.sh（2.2 起編輯器改字、搬圖、塗黑用）"; exit 1; }
mkdir -p "$MACOS" "$RES" "$BUILD"

echo "── 1/5 編譯 Swift ──"
SWIFT_DEFS=""
swiftc -O $SWIFT_DEFS app/Sources/*.swift -o "$MACOS/$APP_NAME" \
  -framework AppKit -framework WebKit -framework PDFKit -framework UserNotifications -framework UniformTypeIdentifiers \
  -target arm64-apple-macos12.0
cp app/Info.plist "$APP/Contents/Info.plist"

echo "── 2/5 介面與引擎 ──"
# 字標＝品牌正本的外框（app/brand/slimly_logotype_v1_word.path.txt，自 ../4_品牌/標準字/ 複製），組建時貼進介面，不打字
WORD_VB=$(sed -n 1p app/brand/slimly_logotype_v1_word.path.txt | sed -E 's/^viewBox="(.*)"$/\1/')
WORD_D=$(sed -n 2p app/brand/slimly_logotype_v1_word.path.txt)
for page in ui editor; do                                   # 主視窗、編輯器（2.1）
python3 - "$WORD_VB" "$WORD_D" "app/$page.html" "$RES/$page.html" <<'PY'
import sys
vb, d, src, dst = sys.argv[1:5]
s = open(src, encoding="utf-8").read().replace("%%WORD_VB%%", vb).replace("%%WORD_D%%", d)
assert "%%" not in s, src + " 還有沒換掉的 %%…%%"
open(dst, "w", encoding="utf-8").write(s)
PY
done
mkdir -p "$RES/brand" "$RES/fonts" "$RES/bin" "$RES/mu"
cp app/brand/intention_wordmark.png "$RES/brand/"          # 頁尾「Powered by」的字標
for f in app/fonts/*.ttf; do if [ -e "$f" ]; then cp "$f" "$RES/fonts/"; fi; done      # 沒有字型檔（公開版）就用系統字
if [ -f LICENSE ]; then cp LICENSE "$RES/"; fi                       # 授權全文跟著 app 走（AGPL-3.0）
for lp in app/lproj/*.lproj; do mkdir -p "$RES/$(basename "$lp")" && cp "$lp"/* "$RES/$(basename "$lp")/"; done
cp THIRD-PARTY-NOTICES.txt "$RES/"
cp vendor/bin/gs "$RES/bin/gs"
cp vendor/bin/mutool "$RES/bin/mutool"                        # 2.2：編輯器的 MuPDF（改字只刪那幾行、原圖搬移、塗黑真刪）
cp app/mu/slimly-mu.js "$RES/mu/"
chmod 755 "$RES/bin/gs" "$RES/bin/mutool"
chmod 644 "$RES/ui.html" "$RES/editor.html" "$RES/brand/"* "$RES/mu/"* "$RES/THIRD-PARTY-NOTICES.txt"
find "$RES/fonts" -type f -exec chmod 644 {} +
GSV=$(vendor/bin/gs --version)
MUV=$(vendor/bin/mutool -v 2>&1 | head -1 | sed -E 's/.*version ([0-9.]+).*/\1/')
printf "Ghostscript %s\nMuPDF %s\n" "$GSV" "$MUV" > "$RES/engine-version.txt"
echo "   引擎：Ghostscript ${GSV}、MuPDF ${MUV}"

echo "── 3/5 App icon ──"
# 每次重畫（AppKit 向量，1 秒）。只在缺檔時畫的話，改了 make-icon.swift 之後 Dock 還是舊圖
swift app/make-icon.swift "$BUILD/icon_1024.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$BUILD/icon_1024.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  dbl=$((sz * 2))
  sips -z $dbl $dbl "$BUILD/icon_1024.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
sips -z 128 128 "$BUILD/icon_1024.png" --out "$RES/brand/appicon.png" >/dev/null     # 精靈第一頁的圖示

# 防呆：覆蓋式重建會留上一輪的雜物（多一支執行檔，整個 DMG 就會被公證退件）——移進 build/stray/，不刪
STRAY=$(ls "$MACOS" | grep -v "^$APP_NAME$" || true)
if [ -n "$STRAY" ]; then
  mkdir -p "$BUILD/stray"
  for f in $STRAY; do echo "   ⚠ MacOS/ 有非預期檔案：$f → 移入 $BUILD/stray/"; mv "$MACOS/$f" "$BUILD/stray/$f-$(date +%Y%m%d-%H%M%S)"; done
fi
OK_RES="ui\.html|editor\.html|brand|fonts|bin|mu|[A-Za-z-]+\.lproj|AppIcon\.icns|THIRD-PARTY-NOTICES\.txt|LICENSE|engine-version\.txt"
STRAY_RES=$(ls "$RES" | grep -vE "^($OK_RES)$" || true)
[ -n "$STRAY_RES" ] && echo "   ⚠ Resources/ 有非預期檔案：$STRAY_RES"

echo "── 4/5 簽名 ──"
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -n "$SIGN_ID" ]; then
  echo "   Developer ID：$SIGN_ID"
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$RES/bin/gs"
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$RES/bin/mutool"
  codesign --force --options runtime --timestamp --entitlements app/Slimly.entitlements -s "$SIGN_ID" "$APP"
else
  echo "   找不到 Developer ID，退回 ad-hoc（只能自己這台用，不能給別人）"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP" && echo "   簽名驗證通過"

echo "── 5/5 完成 ──"
echo "完成 — $APP_NAME $VER ($BLD)"
echo "  app：$PWD/$APP"
