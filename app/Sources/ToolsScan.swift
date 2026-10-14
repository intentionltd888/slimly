// ToolsScan.swift — 掃描為 PDF：手機拍的文件照片（或 iPhone「掃描文件」接力過來的）→ 找紙的四個角、拉正、提亮 → 一頁一張的 PDF
//
// iLovePDF 的「掃描為 PDF」是用手機拍；這裡一樣：Mac 的「從 iPhone 輸入 → 掃描文件／拍照」（接力相機），
// 或把手機拍好的照片丟進來。找紙＝Vision 的文件偵測（裝置端）；拉正＝Core Image 透視校正；提亮＝文件增強。
// 最後照「OCR」同一套放一層看不見的字，掃出來的就能搜尋、選字。
import AppKit
import CoreImage
import Foundation
import PDFKit
import Vision

enum Scan {
    /// look＝color（預設）／gray／bw；ocr＝true（預設）；camera＝true：從 iPhone 接力來的（檔名用日期）
    static func run(_ r: ToolRun) throws -> ToolResult {
        let look = r.opt.str("look", "color")
        let ci = CIContext()
        let tmp = r.tmp("scan.pdf")
        var mb = CGRect.zero
        guard let pdf = CGContext(tmp as CFURL, mediaBox: &mb, [kCGPDFContextCreator as String: "Slimly"] as CFDictionary) else {
            throw ToolError.msg(L("寫不出 PDF", "Couldn’t create the PDF"))
        }
        var pages = 0, straightened = 0, skipped: [String] = []
        for (k, u) in r.inputs.enumerated() {
            if r.isCancelled { break }
            r.progress(L("整理第 \(k + 1)／\(r.inputs.count) 張", "Page \(k + 1)/\(r.inputs.count)"), 0.6 * Double(k) / Double(r.inputs.count))
            // 接力相機的「掃描文件」本來就是 PDF（已經拉正過）：整份照抄
            if u.pathExtension.lowercased() == "pdf" {
                guard let d = CGPDFDocument(u as CFURL), d.numberOfPages > 0 else { skipped.append(u.lastPathComponent); continue }
                for i in 1...d.numberOfPages {
                    guard let p = d.page(at: i) else { continue }
                    var box = p.getBoxRect(.cropBox)
                    pdf.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
                    pdf.drawPDFPage(p)
                    pdf.endPDFPage()
                    pages += 1
                }
                continue
            }
            guard let (src, _) = Convert.loadImage(u) else { skipped.append(u.lastPathComponent); continue }
            var img = CIImage(cgImage: src)
            if let q = paper(in: src) { img = straighten(img, q); straightened += 1 }
            img = enhance(img, look: look)
            guard let cg = ci.createCGImage(img, from: img.extent.integral) else { skipped.append(u.lastPathComponent); continue }
            // 頁面：寬＝A4 的寬（橫的用 A4 的高），高照紙的比例（收據這種長條也照原比例）
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let pw: CGFloat = w > h ? 841.89 : 595.28
            var box = CGRect(x: 0, y: 0, width: pw, height: (pw * h / w).rounded())
            // 彩色、灰階存 JPEG（掃描不需要無損）；黑白直接畫（PDF 用無損壓縮，大片純白壓得很小）
            let pageImg = look == "bw" ? cg : (Raster.encode(cg, quality: 0.8).flatMap { Raster.jpegImage($0) } ?? cg)
            pdf.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            pdf.draw(pageImg, in: box)
            pdf.endPDFPage()
            pages += 1
        }
        pdf.closePDF()
        guard pages > 0 else { throw ToolError.msg(L("沒有讀得出來的照片或掃描檔", "No readable photos or scans")) }
        try PDFs.verify(tmp, pages: pages)
        var final = tmp
        var notes = [L("\(pages) 頁", "\(pages) pages") + (straightened > 0 ? L("；\(straightened) 張找到紙的邊，已經拉正、裁掉背景", "; \(straightened) straightened and cropped to the paper") : "")]
        // 順便辨識文字（跟「OCR」同一套），失敗不影響交件
        if r.opt.bool("ocr", true), !r.isCancelled {
            r.progress(L("辨識文字", "Recognizing text"), 0.7)
            let sub = ToolRun(id: "ocr", inputs: [tmp], options: ToolOptions(raw: ["lang": r.opt.str("lang", "zh")]), dest: r.work.appendingPathComponent("ocr", isDirectory: true), progress: nil, cancel: r.token)
            defer { sub.cleanup() }
            if let o = try? OCR.run(sub), let f = o.outputs.first { final = f; notes.append(L("可以搜尋、選字", "Searchable")) }
        }
        if !skipped.isEmpty { notes.append(L("讀不出來、跳過：\(skipped.prefix(3).joined(separator: "、"))", "Skipped: \(skipped.prefix(3).joined(separator: ", "))")) }
        let camera = r.opt.bool("camera")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let stem = camera ? L("掃描 ", "Scan ") + f.string(from: Date()) : PDFs.stem(r.inputs[0]) + (r.inputs.count > 1 ? L(" 等 \(r.inputs.count) 張", " +\(r.inputs.count - 1)") : "")
        let out = try r.place(final, like: camera ? nil : r.inputs[0], suffix: camera ? "" : L("（掃描）", " (scan)"), ext: "pdf", stem: stem)
        return ToolResult(outputs: [out], notes: notes)
    }

    /// 紙的四個角（Vision 座標：0–1、原點左下）。找不到、或找到的太小（不像一張紙）＝nil
    static func paper(in img: CGImage) -> VNRectangleObservation? {
        let h = VNImageRequestHandler(cgImage: img, options: [:])
        let seg = VNDetectDocumentSegmentationRequest()
        var best: VNRectangleObservation?
        if (try? h.perform([seg])) != nil { best = seg.results?.first }
        if best == nil {
            let rect = VNDetectRectanglesRequest()
            rect.maximumObservations = 1; rect.minimumConfidence = 0.6; rect.minimumSize = 0.3; rect.quadratureTolerance = 30
            if (try? h.perform([rect])) != nil { best = rect.results?.first }
        }
        guard let q = best, q.confidence >= 0.5 else { return nil }
        // 面積（鞋帶公式）小於畫面 20%＝不是整張紙
        let pts = [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft]
        var a: CGFloat = 0
        for i in 0..<4 { let p = pts[i], n = pts[(i + 1) % 4]; a += p.x * n.y - n.x * p.y }
        return abs(a) / 2 >= 0.2 ? q : nil
    }

    /// 透視校正：四個角拉成長方形
    static func straighten(_ img: CIImage, _ q: VNRectangleObservation) -> CIImage {
        let e = img.extent
        func pt(_ p: CGPoint) -> CIVector { CIVector(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height) }
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return img }
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(pt(q.topLeft), forKey: "inputTopLeft"); f.setValue(pt(q.topRight), forKey: "inputTopRight")
        f.setValue(pt(q.bottomLeft), forKey: "inputBottomLeft"); f.setValue(pt(q.bottomRight), forKey: "inputBottomRight")
        return f.outputImage ?? img
    }

    /// 提亮：彩色＝文件增強（紙變白、字變清楚）；灰階＝去色再增強；黑白＝灰階後二值化
    static func enhance(_ img: CIImage, look: String) -> CIImage {
        var out = img
        if look != "color", let g = CIFilter(name: "CIColorControls") {
            g.setValue(out, forKey: kCIInputImageKey); g.setValue(0, forKey: kCIInputSaturationKey); g.setValue(1.08, forKey: kCIInputContrastKey)
            out = g.outputImage ?? out
        }
        if let d = CIFilter(name: "CIDocumentEnhancer") {
            d.setValue(out, forKey: kCIInputImageKey); d.setValue(look == "color" ? 1.0 : 1.4, forKey: "inputAmount")
            out = d.outputImage ?? out
        }
        if look == "bw", let t = CIFilter(name: "CIColorThreshold") {
            t.setValue(out, forKey: kCIInputImageKey); t.setValue(0.62, forKey: "inputThreshold")
            out = t.outputImage ?? out
        }
        return out.cropped(to: img.extent)
    }
}
