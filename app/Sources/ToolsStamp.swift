// ToolsStamp.swift — 蓋在頁面上的：頁碼、浮水印、加字（編輯）、簽名
//
// 做法：每一頁用 PDFKit 畫進新檔（頁面旋轉、表單欄位的外觀一起畫進去），再在上面畫字或圖；
// 連結與書籤畫不進去，另外照頁碼搬回去。字用蘋方（中英日都有字），只把用到的字嵌進檔案。
import AppKit
import CoreText
import Foundation
import PDFKit

enum Overlay {
    /// 顯示方向（含 /Rotate）的頁面大小
    static func displaySize(_ p: PDFPage) -> CGSize {
        let b = p.bounds(for: .cropBox)
        let rot = ((p.rotation % 360) + 360) % 360
        return (rot == 90 || rot == 270) ? CGSize(width: b.height, height: b.width) : b.size
    }

    /// 畫進新檔：draw(ctx, 頁面大小, 第幾頁) 在原頁上面畫東西；回傳時連結與書籤已經搬回去
    static func render(_ src: PDFDocument, to dst: URL, progress: ((Int) -> Void)? = nil,
                       page drawPage: ((CGContext, PDFPage, CGSize, Int) -> Bool)? = nil,
                       draw: (CGContext, CGSize, Int) -> Void) throws {
        var mb = CGRect.zero
        var info: [String: Any] = [kCGPDFContextCreator as String: "Slimly \(Engine.appVersion)"]
        if let a = src.documentAttributes {
            if let t = a[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle as String] = t }
            if let t = a[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor as String] = t }
        }
        guard let ctx = CGContext(dst as CFURL, mediaBox: &mb, info as CFDictionary) else {
            throw ToolError.msg(L("寫不出新檔", "Couldn’t create the output"))
        }
        for i in 0..<src.pageCount {
            guard let page = src.page(at: i) else { continue }
            progress?(i)
            let size = displaySize(page)
            var r = CGRect(origin: .zero, size: size)
            let box = Data(bytes: &r, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
            ctx.saveGState()
            // 自己畫整頁的（塗黑：換成圖）回 true；平常照原頁畫（macOS 26 的 draw 已經套好旋轉，不能再 transform）
            if drawPage?(ctx, page, size, i) != true { page.draw(with: .cropBox, to: ctx) }
            ctx.restoreGState()
            ctx.saveGState(); draw(ctx, size, i); ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try relink(from: src, to: dst)
    }

    /// 連結、書籤照頁碼搬到新檔（座標換到新頁的顯示方向）
    static func relink(from src: PDFDocument, to dst: URL) throws {
        var hasLinks = false
        for i in 0..<src.pageCount where src.page(at: i)?.annotations.contains(where: { $0.type == "Link" }) == true { hasLinks = true; break }
        guard hasLinks || src.outlineRoot != nil, let out = PDFDocument(url: dst), out.pageCount == src.pageCount else { return }
        func index(of p: PDFPage?) -> Int? { p.flatMap { src.index(for: $0) } }
        for i in 0..<src.pageCount {
            guard let sp = src.page(at: i), let dp = out.page(at: i) else { continue }
            for a in sp.annotations where a.type == "Link" {
                let n = PDFAnnotation(bounds: map(a.bounds, sp), forType: .link, withProperties: nil)
                let border = PDFBorder(); border.lineWidth = 0; n.border = border
                if let u = a.url ?? (a.action as? PDFActionURL)?.url { n.url = u }
                else if let d = a.destination ?? (a.action as? PDFActionGoTo)?.destination, let k = index(of: d.page), let tp = out.page(at: k), let tsp = src.page(at: k) {
                    n.destination = PDFDestination(page: tp, at: mapPoint(d.point, tsp))
                } else { continue }
                dp.addAnnotation(n)
            }
        }
        if let root = src.outlineRoot {
            func copy(_ o: PDFOutline) -> PDFOutline {
                let n = PDFOutline()
                n.label = o.label
                if let d = o.destination, let k = index(of: d.page), let tp = out.page(at: k), let sp = src.page(at: k) {
                    n.destination = PDFDestination(page: tp, at: mapPoint(d.point, sp))
                }
                for c in 0..<o.numberOfChildren { if let ch = o.child(at: c) { n.insertChild(copy(ch), at: n.numberOfChildren) } }
                return n
            }
            out.outlineRoot = copy(root)
        }
        guard out.write(to: dst) else { return }
    }

    /// 原頁座標（未旋轉、含 crop 原點）→ 新頁（顯示方向、原點 0）
    static func mapPoint(_ p: CGPoint, _ page: PDFPage) -> CGPoint {
        let c = page.bounds(for: .cropBox)
        if p.x == kPDFDestinationUnspecifiedValue || p.y == kPDFDestinationUnspecifiedValue { return p }
        let x = p.x - c.minX, y = p.y - c.minY, W = c.width, H = c.height
        switch ((page.rotation % 360) + 360) % 360 {
        case 90: return CGPoint(x: y, y: W - x)
        case 180: return CGPoint(x: W - x, y: H - y)
        case 270: return CGPoint(x: H - y, y: x)
        default: return CGPoint(x: x, y: y)
        }
    }
    static func map(_ r: CGRect, _ page: PDFPage) -> CGRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY)].map { mapPoint($0, page) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // MARK: 字與圖

    static func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateWithName((bold ? "PingFangTC-Semibold" : "PingFangTC-Regular") as CFString, size, nil)
    }
    struct Line { let line: CTLine; let width: CGFloat; let ascent: CGFloat; let descent: CGFloat }
    static func line(_ s: String, size: CGFloat, bold: Bool = false, color: CGColor) -> Line {
        let attr = NSAttributedString(string: s, attributes: [.font: font(size, bold: bold), .foregroundColor: color])
        let l = CTLineCreateWithAttributedString(attr)
        var a: CGFloat = 0, d: CGFloat = 0, lead: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(l, &a, &d, &lead))
        return Line(line: l, width: w, ascent: a, descent: d)
    }
    /// 九宮格位置（tl tc tr ml mc mr bl bc br）＋邊界 → 錨點與對齊
    static func anchor(_ pos: String, _ size: CGSize, margin: CGFloat) -> (CGPoint, h: Int, v: Int) {
        let p = pos.count == 2 ? pos : "bc"
        let v = p.first == "t" ? 1 : p.first == "m" ? 0 : -1
        let h = p.last == "l" ? -1 : p.last == "c" ? 0 : 1
        let x = h < 0 ? margin : h == 0 ? size.width / 2 : size.width - margin
        let y = v > 0 ? size.height - margin : v == 0 ? size.height / 2 : margin
        return (CGPoint(x: x, y: y), h, v)
    }
    /// 在錨點畫一行字（h：-1 左齊／0 置中／1 右齊；v：1 字頂齊錨點／0 置中／-1 字底齊錨點）
    static func draw(_ l: Line, in ctx: CGContext, at p: CGPoint, h: Int, v: Int, angle: CGFloat = 0, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.translateBy(x: p.x, y: p.y)
        if angle != 0 { ctx.rotate(by: angle * .pi / 180) }
        let x = h < 0 ? 0 : h == 0 ? -l.width / 2 : -l.width
        let y = v > 0 ? -l.ascent : v == 0 ? -(l.ascent - l.descent) / 2 : l.descent
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(l.line, ctx)
        ctx.restoreGState()
    }
    static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: 4000] as CFDictionary)
    }
    static func color(_ s: String, _ d: CGColor) -> CGColor {
        switch s.lowercased() {
        case "black", "黑": return CGColor(gray: 0, alpha: 1)
        case "gray", "grey", "灰": return CGColor(gray: 0.5, alpha: 1)
        case "red", "紅": return CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        case "blue", "藍": return CGColor(red: 0, green: 0.235, blue: 1, alpha: 1)
        case "white", "白": return CGColor(gray: 1, alpha: 1)
        default:
            let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
            if h.count == 6, let v = Int(h, radix: 16) {
                return CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
            }
            return d
        }
    }
}

enum Stamp {
    static let mm: CGFloat = 72 / 25.4

    /// 頁碼：pos（bc 預設）、fmt（n／nN／page／dash）、start（第一個號碼）、from（從第幾頁開始標，封面不標就填 2）、size、margin（mm）
    static func pageNumbers(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            let n = d.pageCount
            let from = max(1, r.opt.int("from", 1)) - 1
            let start = r.opt.int("start", 1)
            let fmt = r.opt.str("fmt", "n"), pos = r.opt.str("pos", "bc")
            let size = CGFloat(r.opt.dbl("size", 10)), margin = CGFloat(r.opt.dbl("margin", 10)) * mm
            let color = Overlay.color(r.opt.str("color", "black"), CGColor(gray: 0, alpha: 1))
            let total = n - from + start - 1
            let tmp = r.tmp("number.pdf")
            try Overlay.render(d, to: tmp, progress: { r.progress(L("第 \($0 + 1)／\(n) 頁", "Page \($0 + 1)/\(n)"), Double($0) / Double(n)) }) { ctx, sz, i in
                guard i >= from else { return }
                let k = i - from + start
                let s: String
                switch fmt {
                case "nN": s = "\(k) / \(total)"
                case "page": s = L("第 \(k) 頁", "Page \(k)")
                case "dash": s = "– \(k) –"
                default: s = "\(k)"
                }
                let (p, h, v) = Overlay.anchor(pos, sz, margin: margin)
                Overlay.draw(Overlay.line(s, size: size, color: color), in: ctx, at: p, h: h, v: v)
            }
            try PDFs.verify(tmp, pages: n)
            res.outputs.append(try r.place(tmp, like: u, suffix: L("（頁碼）", " (numbered)"), ext: "pdf"))
        }
        return res
    }

    /// 浮水印：text 或 image；pos＝center（預設）／tile；angle（字預設 45）、opacity（0.2）、size（字級，預設依頁寬）、color、pages
    static func watermark(_ r: ToolRun) throws -> ToolResult {
        let text = r.opt.str("text")
        let img = r.opt.has("image") ? Overlay.image(URL(fileURLWithPath: (r.opt.str("image") as NSString).expandingTildeInPath)) : nil
        guard !text.isEmpty || img != nil else { throw ToolError.msg(L("要寫浮水印的字（例：機密），或給一張圖", "Enter watermark text or choose an image")) }
        let alpha = CGFloat(min(1, max(0.05, r.opt.dbl("opacity", 0.2))))
        let angle = CGFloat(r.opt.dbl("angle", img == nil ? 45 : 0))
        let tile = r.opt.str("pos", "center") == "tile"
        let color = Overlay.color(r.opt.str("color", "gray"), CGColor(gray: 0.5, alpha: 1))
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            let which = Set(try PDFs.pages(r.opt.str("pages", "all"), count: d.pageCount))
            let tmp = r.tmp("watermark.pdf")
            try Overlay.render(d, to: tmp, progress: { r.progress(L("第 \($0 + 1)／\(d.pageCount) 頁", "Page \($0 + 1)/\(d.pageCount)"), Double($0) / Double(d.pageCount)) }) { ctx, sz, i in
                guard which.contains(i) else { return }
                if let img {
                    let w = min(sz.width, sz.height) * CGFloat(r.opt.dbl("scale", 0.5))
                    let h = w * CGFloat(img.height) / CGFloat(max(1, img.width))
                    ctx.setAlpha(alpha)
                    let spots: [CGPoint] = tile ? grid(sz, step: w * 1.6) : [CGPoint(x: sz.width / 2, y: sz.height / 2)]
                    for c in spots {
                        ctx.saveGState(); ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: angle * .pi / 180)
                        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)); ctx.restoreGState()
                    }
                } else {
                    // 字的大小：沒指定就讓整行斜放時大約是頁面對角線的六成
                    var size = CGFloat(r.opt.dbl("size", 0))
                    if size <= 0 {
                        let probe = Overlay.line(text, size: 100, bold: true, color: color)
                        let target = hypot(sz.width, sz.height) * (tile ? 0.3 : 0.6)
                        size = max(12, min(200, 100 * target / max(1, probe.width)))
                    }
                    let l = Overlay.line(text, size: size, bold: true, color: color)
                    let spots: [CGPoint] = tile ? grid(sz, step: max(l.width, size * 4) * 1.1) : [CGPoint(x: sz.width / 2, y: sz.height / 2)]
                    for c in spots { Overlay.draw(l, in: ctx, at: c, h: 0, v: 0, angle: angle, alpha: alpha) }
                }
            }
            try PDFs.verify(tmp, pages: d.pageCount)
            res.outputs.append(try r.place(tmp, like: u, suffix: L("（浮水印）", " (watermarked)"), ext: "pdf"))
        }
        return res
    }
    private static func grid(_ sz: CGSize, step: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        let s = max(40, step)
        var y = s / 2, row = 0
        while y < sz.height + s / 2 {
            var x = (row % 2 == 0 ? s / 2 : 0)
            while x < sz.width + s / 2 { out.append(CGPoint(x: x, y: y)); x += s }
            y += s * 0.6; row += 1
        }
        return out
    }

    /// 加字（編輯的非互動版）：text、pages（預設 1）、pos（九宮格，預設 tr）或 x／y（mm，從左下角）、size、color；也可以 image
    static func text(_ r: ToolRun) throws -> ToolResult {
        let text = r.opt.str("text")
        let img = r.opt.has("image") ? Overlay.image(URL(fileURLWithPath: (r.opt.str("image") as NSString).expandingTildeInPath)) : nil
        guard !text.isEmpty || img != nil else { throw ToolError.msg(L("要寫加上去的字，或給一張圖；要自由畫線、框字，用預覽程式的標示工具", "Enter text or choose an image (for freehand markup use Preview)")) }
        let u = r.inputs[0], d = try PDFs.open(u)
        let which = Set(try PDFs.pages(r.opt.str("pages", "1"), count: d.pageCount))
        let size = CGFloat(r.opt.dbl("size", 14)), margin = CGFloat(r.opt.dbl("margin", 12)) * mm
        let color = Overlay.color(r.opt.str("color", "black"), CGColor(gray: 0, alpha: 1))
        let tmp = r.tmp("edit.pdf")
        try Overlay.render(d, to: tmp) { ctx, sz, i in
            guard which.contains(i) else { return }
            var (p, h, v) = Overlay.anchor(r.opt.str("pos", "tr"), sz, margin: margin)
            if r.opt.has("x"), r.opt.has("y") { p = CGPoint(x: CGFloat(r.opt.dbl("x", 0)) * mm, y: CGFloat(r.opt.dbl("y", 0)) * mm); h = -1; v = -1 }
            if let img {
                let w = CGFloat(r.opt.dbl("width", 40)) * mm, hgt = w * CGFloat(img.height) / CGFloat(max(1, img.width))
                let x = h < 0 ? p.x : h == 0 ? p.x - w / 2 : p.x - w
                let y = v > 0 ? p.y - hgt : v == 0 ? p.y - hgt / 2 : p.y
                ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: hgt))
                p.y += v > 0 ? -hgt - 4 : hgt + 4
            }
            if !text.isEmpty {
                // 多行：一律往下排；錨在下緣或中間時整塊往上挪，不超出頁面
                let lines = text.components(separatedBy: "\n"), lh = size * 1.35
                let top = v > 0 ? p.y : v == 0 ? p.y + CGFloat(lines.count - 1) * lh / 2 : p.y + CGFloat(lines.count - 1) * lh
                for (k, s) in lines.enumerated() {
                    Overlay.draw(Overlay.line(s, size: size, color: color), in: ctx, at: CGPoint(x: p.x, y: top - CGFloat(k) * lh), h: h, v: v)
                }
            }
        }
        try PDFs.verify(tmp, pages: d.pageCount)
        return ToolResult(outputs: [try r.place(tmp, like: u, suffix: L("（加字）", " (edited)"), ext: "pdf")])
    }

    /// 簽名：image（透明底的簽名圖，介面上畫的或選的）；page（預設最後一頁，可寫 all）、pos（br）、width（mm，預設 45）、date（旁邊加日期）
    static func sign(_ r: ToolRun) throws -> ToolResult {
        guard r.opt.has("image"), let img = Overlay.image(URL(fileURLWithPath: (r.opt.str("image") as NSString).expandingTildeInPath)) else {
            throw ToolError.msg(L("要一張簽名圖（在工具頁畫一個，或選透明底的 PNG）", "Needs a signature image (draw one, or pick a transparent PNG)"))
        }
        let u = r.inputs[0], d = try PDFs.open(u)
        let pages = Set(try PDFs.pages(r.opt.str("page", "last"), count: d.pageCount))
        let w = CGFloat(r.opt.dbl("width", 45)) * mm, margin = CGFloat(r.opt.dbl("margin", 18)) * mm
        let date = r.opt.bool("date") ? DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none) : nil
        let tmp = r.tmp("sign.pdf")
        try Overlay.render(d, to: tmp) { ctx, sz, i in
            guard pages.contains(i) else { return }
            let h = w * CGFloat(img.height) / CGFloat(max(1, img.width))
            var (p, ha, va) = Overlay.anchor(r.opt.str("pos", "br"), sz, margin: margin)
            if r.opt.has("x"), r.opt.has("y") { p = CGPoint(x: CGFloat(r.opt.dbl("x", 0)) * mm, y: CGFloat(r.opt.dbl("y", 0)) * mm); ha = -1; va = -1 }
            let x = ha < 0 ? p.x : ha == 0 ? p.x - w / 2 : p.x - w
            let y = va > 0 ? p.y - h : va == 0 ? p.y - h / 2 : p.y + (date == nil ? 0 : 14)
            ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
            if let date { Overlay.draw(Overlay.line(date, size: 9, color: CGColor(gray: 0.25, alpha: 1)), in: ctx, at: CGPoint(x: x + w / 2, y: y - 4), h: 0, v: 1) }
        }
        try PDFs.verify(tmp, pages: d.pageCount)
        return ToolResult(outputs: [try r.place(tmp, like: u, suffix: L("（已簽名）", " (signed)"), ext: "pdf")],
                          notes: [L("這是看得見的簽名圖（跟在紙上簽一樣），不是數位憑證簽章", "A visible signature image, not a certificate-based digital signature")])
    }
}
