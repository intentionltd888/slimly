# Slimly

[![Download Slimly (macOS)](https://img.shields.io/badge/Download-macOS-000000?style=for-the-badge&logo=apple&logoColor=white&labelColor=000000)](https://github.com/intentionltd888/slimly/releases/latest/download/Slimly.dmg)
[![Latest release](https://img.shields.io/github/v/release/intentionltd888/slimly?style=for-the-badge&label=Latest&labelColor=000000&color=555555)](https://github.com/intentionltd888/slimly/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/intentionltd888/slimly/total?style=for-the-badge&label=Downloads&labelColor=000000&color=555555)](https://github.com/intentionltd888/slimly/releases)

Shrink PDFs, photos and Office files until they can be sent, with almost no visible loss. [中文](README.md)

Slimly is a file compressor and PDF editor for macOS. Drop a file in, choose how small (25, 10, 5 MB or no limit) and press once. The original stays untouched; the result is saved as a copy.

## What it does

- **Just small enough to send**: starts from the best-quality level and stops as soon as the file fits; shows an estimate before compressing, checks every page against the original afterwards, and lets you zoom into a before/after comparison. If it still won't fit, it can split the file by pages so each part is under the limit.
- **Not only PDFs**: HEIC, JPEG and PNG photos, plus Word, PowerPoint and Excel files (only the images inside are recompressed; everything else is left byte-for-byte).
- **Watched folders**: files dropped into chosen folders are compressed into “Slimly Compressed” inside them.
- **PDF editor**: change existing text and images (including vertical and 90°-rotated text), add text and images, sign, fill forms, redact (the text and images inside the box are really deleted), comment and reply, attach files, reorder pages.
- **Tools**: merge, split, extract, rotate, crop, page numbers, watermark, add a password, remove a password you know, repair, PDF/A, OCR, convert to Word/PowerPoint/Excel/images, Office/images/web pages to PDF, compare two versions; on macOS 26 also translation (saved as a copy, layout kept) and summaries, using the models on your Mac.
- **Command line**: `Slimly --cli` uses the same engine and checks as the app.
- Chinese/English interface, light and dark.

Everything happens on your Mac: no server, no account, no analytics. Only two things ever leave it: files you send with “Share…”, and the address you paste into “Web page to PDF” (Slimly opens it like a browser would). Details in [PRIVACY.md](PRIVACY.md).

For PDFs whose author set permission restrictions (printing, copying, editing), Slimly does not remove them behind your back: remove them first in Unlock PDF with the owner password. Slimly never cracks or guesses passwords.

## Download

[**Download Slimly.dmg**](https://github.com/intentionltd888/slimly/releases/latest/download/Slimly.dmg) (Mac with Apple silicon, macOS 12 or later; notarized by Apple). Open the DMG and drag Slimly into Applications, or just double-click it.

All versions are on [Releases](https://github.com/intentionltd888/slimly/releases), each with the corresponding Ghostscript and MuPDF source. Please read the [terms of use](TERMS.md) first.

## Building it yourself

- A Mac with Apple silicon, macOS 12 or later
- Xcode command line tools (`xcode-select --install`)
- Two bundled engines, built from the official source into single executables (SHA-checked, not in git):
  - Ghostscript 10.08.0: `bash scripts/vendor-fetch.sh` (about 3 minutes)
  - MuPDF 1.28.5 (`mutool`): `bash scripts/vendor-mupdf.sh`

## Build

```bash
bash scripts/vendor-fetch.sh          # vendor/bin/gs
bash scripts/vendor-mupdf.sh          # vendor/bin/mutool
bash build.sh                         # build/Slimly.app
bash scripts/make-dmg.sh              # build/Slimly-<version>.dmg (background via SLIMLY_DMG_BG)
bash scripts/notarize.sh              # Apple notarization + stapling (Developer ID and a notarytool profile in SLIMLY_NOTARY_PROFILE)
bash scripts/check-clean.sh           # source scan before publishing; for the app: bash scripts/check-binary.sh build/Slimly.app
```

Command line:

```bash
build/Slimly.app/Contents/MacOS/Slimly --cli --target 10 portfolio.pdf   # under 10 MB, saved next to the original
build/Slimly.app/Contents/MacOS/Slimly --cli --help                      # all options
```

## Layout

```
app/Sources/   Swift: main (window, queue, share, watched folders), Engine/Ladder (compression levels), Inspect, Estimate, Guard,
               ImageEngine, OfficeEngine, Editor/EditorEngine (PDF editor), Tools* (all tools), CLI, Installer, Prefs
app/           ui.html (main window), editor.html (editor), mu/slimly-mu.js (editing script run inside mutool), lproj/, brand/ (trademarks)
scripts/       vendor-fetch, vendor-mupdf, make-dmg, notarize, check-clean/check-binary (pre-publish scans)
```

## Issues and rights holders

Please [open an issue](https://github.com/intentionltd888/slimly/issues) in this repository; we reply within 3 business days.

## License

The code is licensed under AGPL-3.0 (see `LICENSE`). Slimly includes Ghostscript and MuPDF (both AGPL-3.0, copyright Artifex Software), run as separate programs; their corresponding source is posted next to each release.
The Slimly name, the ›‹ mark, the slimly wordmark, the app icon and the INTENTION® wordmark in `app/brand/` are trademarks and are not covered by the AGPL (see `app/brand/TRADEMARK.md`).
Third-party components: `THIRD-PARTY-NOTICES.txt`. Terms of use: `TERMS.md`. Privacy and permissions: `PRIVACY.md`.
