# Slimly

[![下載 Slimly（macOS）](https://img.shields.io/badge/%E4%B8%8B%E8%BC%89-macOS-000000?style=for-the-badge&logo=apple&logoColor=white&labelColor=000000)](https://github.com/intentionltd888/slimly/releases/latest/download/Slimly.dmg)
[![最新版本](https://img.shields.io/github/v/release/intentionltd888/slimly?style=for-the-badge&label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC&labelColor=000000&color=555555)](https://github.com/intentionltd888/slimly/releases/latest)
[![下載次數](https://img.shields.io/github/downloads/intentionltd888/slimly/total?style=for-the-badge&label=%E4%B8%8B%E8%BC%89%E6%AC%A1%E6%95%B8&labelColor=000000&color=555555)](https://github.com/intentionltd888/slimly/releases)

把 PDF、照片和 Office 檔壓到寄得出去，畫質幾乎看不出差別。[English](README.en.md)

Slimly 是 macOS 上的檔案壓縮與 PDF 編輯工具。把檔案拖進來，選要多小（25、10、5 MB 或不限），按一下就好；原檔不動，壓好的另存一份。

## 它做什麼

- **壓到剛好寄得出去**：從畫質最好的那一級開始試，剛好到你選的大小就停；壓之前先告訴你大概會變多大，壓完每一頁都跟原檔比對過、可以放大前後對照。真的壓不到，可以依頁拆成幾份，每份都在上限內。
- **不只 PDF**：HEIC、JPEG、PNG 照片，以及 Word、PowerPoint、Excel 檔（只重壓裡面的圖，其他內容一個位元組都不動）。
- **監看資料夾**：丟進指定資料夾的檔自動壓好，放進裡面的「Slimly 已壓縮」。
- **PDF 編輯器**：改原本的字和圖（直排、轉 90° 的字也能改）、加字加圖、簽名、填表單、塗黑（框到的字和圖真的刪掉）、註解與回覆、附加檔案、排頁。
- **工具**：合併、拆分、抽頁、旋轉、裁切、頁碼、浮水印、加密碼、拿掉你知道的密碼、修復、PDF/A、OCR、轉 Word／PowerPoint／Excel／圖片、Office／圖片／網頁轉 PDF、比較兩版；macOS 26 起還有翻譯（另存一份、排版照原檔）和摘要，用的是你 Mac 上的模型。
- **命令列**：`Slimly --cli` 跟 app 用同一套引擎與檢查。
- 中文／English 介面，深淺色。

全部在你的 Mac 上做：沒有伺服器、沒有帳號、沒有統計。會離開這台 Mac 的只有兩種：你按「分享…」送出去的檔，以及「網頁轉 PDF」時你貼的網址（Slimly 會像瀏覽器一樣打開它）。細節見 [PRIVACY.md](PRIVACY.md)。

有作者設的權限限制（列印、拷貝、修改）的 PDF，Slimly 不會不經同意就把限制拿掉：要先用「PDF 解鎖」輸入擁有者密碼。Slimly 不破解、不猜密碼。

## 下載

[**下載 Slimly.dmg**](https://github.com/intentionltd888/slimly/releases/latest/download/Slimly.dmg)（Apple 晶片的 Mac，macOS 12 以上；已通過 Apple 公證）。打開 DMG，把 Slimly 拖進「應用程式」，或直接雙擊它。

所有版本在 [Releases](https://github.com/intentionltd888/slimly/releases)，每一版旁邊附 Ghostscript 與 MuPDF 的對應原始碼。使用前請看[使用規範](TERMS.md)。

## 自己建置需要什麼

- Apple 晶片的 Mac，macOS 12 以上
- Xcode 命令列工具（`xcode-select --install`）
- 兩個自帶引擎，從官方原始碼編成單一執行檔（核對 SHA，不進 git）：
  - Ghostscript 10.08.0：`bash scripts/vendor-fetch.sh`（約 3 分鐘）
  - MuPDF 1.28.5（`mutool`）：`bash scripts/vendor-mupdf.sh`

## 建置

```bash
bash scripts/vendor-fetch.sh          # vendor/bin/gs
bash scripts/vendor-mupdf.sh          # vendor/bin/mutool
bash build.sh                         # 組 build/Slimly.app
bash scripts/make-dmg.sh              # build/Slimly-<版本>.dmg（背景圖可用 SLIMLY_DMG_BG 指定）
bash scripts/notarize.sh              # Apple 公證＋釘票（要有 Developer ID 與 notarytool 憑據；profile 用 SLIMLY_NOTARY_PROFILE）
bash scripts/check-clean.sh           # 公開前的原始碼掃描；成品用 bash scripts/check-binary.sh build/Slimly.app
```

命令列：

```bash
build/Slimly.app/Contents/MacOS/Slimly --cli --target 10 作品集.pdf      # 壓到 10 MB 以下，存在原檔旁邊
build/Slimly.app/Contents/MacOS/Slimly --cli --help                      # 全部選項
```

## 倉的長相

```
app/Sources/   Swift：main（視窗、壓縮佇列、分享、監看）、Engine／Ladder（壓縮階梯）、Inspect、Estimate、Guard、
               ImageEngine、OfficeEngine、Editor／EditorEngine（PDF 編輯器）、Tools*（所有工具）、CLI、Installer、Prefs
app/           ui.html（主視窗）、editor.html（編輯器）、mu/slimly-mu.js（跑在 mutool 裡的編輯腳本）、lproj/、brand/（商標）
scripts/       vendor-fetch、vendor-mupdf、make-dmg、notarize、check-clean／check-binary（公開前清洗）
```

## 回報問題、權利人

請在這個倉[開一個 Issue](https://github.com/intentionltd888/slimly/issues)，我們會在 3 個工作天內回覆。

## 授權

程式碼採 AGPL-3.0（見 `LICENSE`）。Slimly 內含 Ghostscript 與 MuPDF（都是 AGPL-3.0，著作權屬於 Artifex Software），以獨立程式執行；對應原始碼放在每一版 Release 旁邊。
Slimly 的名稱、標記 ›‹、slimly 字標、app 圖示與 `app/brand/` 裡的 INTENTION® 字標是商標，不在 AGPL 範圍（見 `app/brand/TRADEMARK.md`）。
第三方元件見 `THIRD-PARTY-NOTICES.txt`；使用規範見 `TERMS.md`；隱私與權限見 `PRIVACY.md`。
