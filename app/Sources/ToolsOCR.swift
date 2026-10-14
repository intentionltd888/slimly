// ToolsOCR.swift — 掃描檔變成可以搜尋、可以選字（macOS 的 Vision，裝置端，不上網）
//
// 每一頁照原樣畫回去，再在字的位置放一層看不見的文字（跟掃描器軟體的「可搜尋 PDF」同一種做法）。
// 已經有文字的頁不動（不是掃描的，不用辨識）。
import AppKit
import CoreText
import Foundation
import PDFKit
import Vision

enum OCR {
    struct TextLine { let text: String; let box: CGRect }    // box：0–1 的比例座標，原點左下（Vision 的慣例）

    static func langs(_ opt: String) -> [String] {
        switch opt {
        case "zh", "zh-Hant", "繁中": return ["zh-Hant", "en-US"]
        case "zh-Hans", "簡中": return ["zh-Hans", "en-US"]
        case "en", "英文": return ["en-US"]
        case "ja", "日文": return ["ja-JP", "en-US"]
        case "ko", "韓文": return ["ko-KR", "en-US"]
        default: return ["zh-Hant", "en-US"]
        }
    }

    /// 認一張圖裡的字，一行一筆
    static func lines(in img: CGImage, languages: [String] = ["zh-Hant", "en-US"]) -> [TextLine] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = languages
        let h = VNImageRequestHandler(cgImage: img, options: [:])
        do { try h.perform([req]) } catch { return [] }
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first, !c.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return TextLine(text: c.string, box: o.boundingBox)
        }
    }

    /// 在頁面上放看不見的字（位置、寬度對到原本那一行，選字時框得剛好）
    static func drawInvisible(_ ls: [TextLine], in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for l in ls {
            let r = CGRect(x: l.box.minX * size.width, y: l.box.minY * size.height, width: l.box.width * size.width, height: l.box.height * size.height)
            guard r.width > 1, r.height > 1 else { continue }
            let fs = max(2, r.height * 0.82)
            let line = Overlay.line(l.text, size: fs, color: CGColor(gray: 0, alpha: 1))
            guard line.width > 0 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.18)
            ctx.scaleBy(x: r.width / line.width, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(line.line, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// 這一頁本來有沒有字（有＝不是掃描，不用辨識）
    static func hasText(_ p: PDFPage) -> Bool {
        (p.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
    }

    /// OCR 工具：lang（zh 預設＝繁中＋英文／zh-Hans／en／ja／ko）；all＝有字的頁也重做
    static func run(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        let ls = langs(r.opt.str("lang", "zh"))
        for u in r.inputs {
            let d = try PDFs.open(u)
            let n = d.pageCount
            let todo = (0..<n).filter { r.opt.bool("all") || !(d.page(at: $0).map(hasText) ?? true) }
            guard !todo.isEmpty else { res.notes.append(L("「\(u.lastPathComponent)」每一頁本來就有文字，不用辨識", "“\(u.lastPathComponent)” already has text on every page")); continue }
            var recognized: [Int: [TextLine]] = [:]
            for (k, i) in todo.enumerated() {
                if r.isCancelled { break }
                r.progress(L("辨識第 \(i + 1) 頁（\(k + 1)／\(todo.count)）", "Reading page \(i + 1) (\(k + 1)/\(todo.count))"), Double(k) / Double(todo.count))
                guard let p = d.page(at: i), let img = Raster.page(p, dpi: 300, maxSide: 5000) else { continue }
                recognized[i] = lines(in: img, languages: ls)
            }
            let tmp = r.tmp("ocr.pdf")
            try Overlay.render(d, to: tmp) { ctx, size, i in
                if let t = recognized[i] { drawInvisible(t, in: ctx, size: size) }
            }
            try PDFs.verify(tmp, pages: n)
            let chars = recognized.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.text.count } }
            guard chars > 0 else { throw ToolError.msg(L("「\(u.lastPathComponent)」認不出字（圖太糊，或不是文字）", "No text recognized in “\(u.lastPathComponent)”")) }
            res.outputs.append(try r.place(tmp, like: u, suffix: L("（可搜尋）", " (searchable)"), ext: "pdf"))
            res.notes.append(L("辨識了 \(recognized.count) 頁、約 \(chars) 字；畫面不變，現在可以搜尋、選字", "\(recognized.count) pages, ~\(chars) characters recognized; looks the same, now searchable"))
        }
        guard !res.outputs.isEmpty else { throw ToolError.msg(res.notes.first ?? L("沒有要辨識的頁", "Nothing to recognize")) }
        return res
    }

    /// 給摘要、翻譯、Markdown 用：一頁的文字（沒有就現場辨識）
    static func pageText(_ p: PDFPage, languages: [String] = ["zh-Hant", "en-US"]) -> String {
        if hasText(p) { return PDFs.text(p) }
        guard let img = Raster.page(p, dpi: 200, maxSide: 4000) else { return "" }
        return lines(in: img, languages: languages).map(\.text).joined(separator: "\n")
    }
}
