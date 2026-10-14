#!/bin/bash
# notarize.sh — Apple 公證＋釘票：make-dmg.sh 產出 DMG 後跑，跑完才能傳給別人
# 前提：① app 是 Developer ID 簽名（build.sh 自動偵測）② notarytool 憑據已存鑰匙圈（xcrun notarytool store-credentials <profile> …）
# profile：SLIMLY_NOTARY_PROFILE → 本夾 .notary-profile（不進 git）
# 交付：DMG 正本進 ../2_版本/（檔名帶版本與 build；只留最新一顆，舊的移進 ../_archive/2_版本/，不刪）
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${SLIMLY_BUILD_DIR:-build}"
APP="$BUILD/Slimly.app"
PROFILE="${SLIMLY_NOTARY_PROFILE:-}"
[ -z "$PROFILE" ] && [ -f .notary-profile ] && PROFILE=$(tr -d '[:space:]' < .notary-profile)
[ -n "$PROFILE" ] || { echo "✕ 沒有公證 profile：設 SLIMLY_NOTARY_PROFILE，或把名字寫進 .notary-profile"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BLD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
DMG="$BUILD/Slimly-$VER.dmg"
[ -f "$DMG" ] || { echo "找不到 ${DMG}——先跑 bash scripts/make-dmg.sh"; exit 1; }

SIGN_INFO=$(codesign -dvv "$APP" 2>&1)     # 不用「codesign | grep -q」：pipefail 下會吃 SIGPIPE 誤判
echo "$SIGN_INFO" | grep -q "Developer ID Application" || { echo "app 不是 Developer ID 簽名——公證必被退件"; exit 1; }

echo "── 出貨閘：DMG 內容＝當下 app ──"
APP_CD=$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^CDHash=/ && !p {print $2; p=1}')
MNT=$(mktemp -d)
hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$DMG" >/dev/null
DMG_CD=$(codesign -dvvv "$MNT/Slimly.app" 2>&1 | awk -F= '/^CDHash=/ && !p {print $2; p=1}')
hdiutil detach "$MNT" >/dev/null
[ -n "$APP_CD" ] && [ "$APP_CD" = "$DMG_CD" ] || { echo "✗ 擋下：DMG 內的 app（${DMG_CD:-?}）≠ 現在的 ${APP}（${APP_CD:-?}）——重跑 make-dmg.sh"; exit 1; }
echo "   ✓ 同一顆（cdhash ${APP_CD}）"

echo "── 提交公證（profile：${PROFILE}）──"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
echo "── 釘票 ──"
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP" || echo "⚠ 散裝 app 釘票失敗（DMG 已釘票、出貨不受影響）"
echo "── 驗收 ──"
xcrun stapler validate "$DMG"
spctl -a -vv "$APP" && echo "✓ spctl 通過"

echo "── 交付 ──"
mkdir -p ../2_版本 ../_archive/2_版本
NEW="Slimly-$VER-build$BLD.dmg"
for old in ../2_版本/Slimly-*.dmg; do
  [ -e "$old" ] || continue
  [ "$(basename "$old")" = "$NEW" ] && cmp -s "$old" "$DMG" && continue
  if [ -e "../_archive/2_版本/$(basename "$old")" ]; then mv "$old" "../_archive/2_版本/$(basename "$old" .dmg)-$(date +%Y%m%d-%H%M%S).dmg"
  else mv "$old" ../_archive/2_版本/; fi
  echo "   2_版本 舊的 $(basename "$old") → _archive/2_版本/"
done
ditto "$DMG" "../2_版本/$NEW"
echo "完成 — 交付 DMG＝2_版本/${NEW}（已公證，可以直接傳給別人）"
