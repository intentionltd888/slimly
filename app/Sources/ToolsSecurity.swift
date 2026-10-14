// ToolsSecurity.swift — 填表單、解鎖、加密、塗黑個資、比較兩版
import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// 把頁面畫成點陣（顯示方向、白底）
enum Raster {
    static func page(_ p: PDFPage, dpi: CGFloat, maxSide: Int = 6000, extra: ((CGContext, CGSize) -> Void)? = nil) -> CGImage? {
        let sz = Overlay.displaySize(p)
        var s = dpi / 72
        if max(sz.width, sz.height) * s > CGFloat(maxSide) { s = CGFloat(maxSide) / max(sz.width, sz.height) }
        let w = max(1, Int(sz.width * s)), h = max(1, Int(sz.height * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        p.draw(with: .cropBox, to: ctx)
        extra?(ctx, sz)
        return ctx.makeImage()
    }
    static func encode(_ img: CGImage, type: UTType = .jpeg, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return data as Data
    }
    /// JPEG 資料做成 CGImage：畫進 PDF 時 Quartz 會原封不動放進去（不重壓）
    static func jpegImage(_ d: Data) -> CGImage? {
        guard let prov = CGDataProvider(data: d as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum Security {
    /// 表單：list＝列出欄位（JSON）；data＝{欄位名: 值}（JSON 字串或字典）或 data_file；flatten＝填完壓平（不能再改）
    static func forms(_ r: ToolRun) throws -> ToolResult {
        let u = r.inputs[0], d = try PDFs.open(u)
        var widgets: [PDFAnnotation] = []
        for i in 0..<d.pageCount { widgets += d.page(at: i)?.annotations.filter { $0.type == "Widget" && $0.fieldName != nil } ?? [] }
        guard !widgets.isEmpty else { throw ToolError.msg(L("這份沒有可填寫的欄位（要在上面加字，用「編輯 PDF」）", "No fillable fields here (to add text, use Edit PDF)")) }
        func kind(_ a: PDFAnnotation) -> String {
            switch a.widgetFieldType {
            case .text: return "text"
            case .choice: return "choice"
            case .signature: return "signature"
            case .button: return a.widgetControlType == .checkBoxControl ? "checkbox" : a.widgetControlType == .radioButtonControl ? "radio" : "button"
            default: return "other"
            }
        }
        if r.opt.bool("list") || (!r.opt.has("data") && !r.opt.has("data_file") && r.opt.raw["data"] == nil) {
            var seen = Set<String>(), fields: [[String: Any]] = []
            for a in widgets {
                let n = a.fieldName ?? ""
                if seen.contains(n) && kind(a) != "radio" { continue }
                seen.insert(n)
                var f: [String: Any] = ["name": n, "type": kind(a), "page": (a.page.flatMap { d.index(for: $0) } ?? 0) + 1]
                if let v = a.widgetStringValue { f["value"] = v }
                if kind(a) == "checkbox" { f["value"] = a.buttonWidgetState == .onState }
                if kind(a) == "radio" { f["option"] = a.buttonWidgetStateString; f["on"] = a.buttonWidgetState == .onState }
                if let c = a.choices, !c.isEmpty { f["choices"] = c }
                fields.append(f)
            }
            let json = (try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return ToolResult(text: json, notes: [L("\(fields.count) 個欄位", "\(fields.count) fields")])
        }
        var data: [String: Any] = (r.opt.raw["data"] as? [String: Any]) ?? [:]
        if data.isEmpty {
            let src = r.opt.has("data_file") ? (try? String(contentsOfFile: (r.opt.str("data_file") as NSString).expandingTildeInPath, encoding: .utf8)) ?? "" : r.opt.str("data")
            data = (try? JSONSerialization.jsonObject(with: Data(src.utf8)) as? [String: Any]) ?? [:]
        }
        guard !data.isEmpty else { throw ToolError.msg(L("沒有要填的值", "Nothing to fill in")) }
        var filled = 0
        for a in widgets {
            guard let n = a.fieldName, let v = data[n] else { continue }
            let s = (v as? String) ?? (v as? NSNumber)?.stringValue ?? "\(v)"
            switch kind(a) {
            case "checkbox":
                let on = (v as? Bool) ?? ["1", "true", "yes", "on", "是", "✓", "v"].contains(s.lowercased())
                a.buttonWidgetState = on ? .onState : .offState
            case "radio": a.buttonWidgetState = a.buttonWidgetStateString == s ? .onState : .offState
            case "text", "choice": a.widgetStringValue = s
            default: continue
            }
            filled += 1
        }
        let tmp = r.tmp("forms.pdf")
        var wopts: [PDFDocumentWriteOption: Any]? = nil
        if r.opt.bool("flatten") {
            guard #available(macOS 13.0, *) else { throw ToolError.msg(L("壓平要 macOS 13 以上", "Flattening needs macOS 13 or later")) }
            wopts = [.burnInAnnotationsOption: true]
        }
        try PDFs.write(d, to: tmp, options: wopts)
        try PDFs.verify(tmp, pages: d.pageCount)
        return ToolResult(outputs: [try r.place(tmp, like: u, suffix: L("（已填）", " (filled)"), ext: "pdf")],
                          notes: [L("填了 \(filled) 個欄位", "\(filled) fields filled") + (r.opt.bool("flatten") ? L("；已壓平，不能再改", "; flattened") : "")])
    }

    /// 解鎖：拿掉密碼與作者設的限制。password＝開啟密碼或擁有者密碼；只從畫面的密碼框或終端機提示輸入，不寫在指令裡
    static func unlock(_ r: ToolRun) throws -> ToolResult {
        let u = r.inputs[0]
        guard let d = PDFDocument(url: u) else { throw ToolError.msg(L("「\(u.lastPathComponent)」打不開", "Can’t open “\(u.lastPathComponent)”")) }
        guard d.isEncrypted || d.isLocked else { throw ToolError.msg(L("這份本來就沒有密碼或限制", "This file isn’t protected")) }
        // 只拿掉你知道的密碼：開啟密碼照舊；作者設的限制（列印、拷貝、修改）要輸入擁有者密碼才拿得掉
        let pw = r.opt.str("password"), wasLocked = d.isLocked, wasRestricted = PDFs.restricted(d)
        if wasLocked || wasRestricted {
            guard !pw.isEmpty else {
                throw ToolError.msg(wasLocked ? L("這份要密碼才能打開：在密碼框輸入", "This file needs its password")
                                              : L("這份有作者設的限制：在密碼框輸入擁有者密碼才拿得掉", "This file has restrictions set by its author: enter the owner password"))
            }
            guard d.unlock(withPassword: pw) else { throw ToolError.msg(L("密碼不對", "Wrong password")) }
            guard !PDFs.restricted(d) else {
                throw ToolError.msg(wasLocked ? L("這是打開用的密碼。作者還設了限制（列印、拷貝、修改），要輸入擁有者密碼才拿得掉", "That’s the open password. The author also set restrictions; enter the owner password to remove them")
                                              : L("擁有者密碼不對：作者設的限制要用擁有者密碼才拿得掉", "Wrong owner password: the author’s restrictions can only be removed with it"))
            }
        }
        let note = wasLocked ? L("密碼拿掉了：以後打開不用密碼", "Password removed")
                 : wasRestricted ? L("用擁有者密碼拿掉了作者設的限制", "Restrictions removed with the owner password")
                 : L("拿掉了加密（這份沒有設任何限制）", "Encryption removed (the file had no restrictions)")
        // 直接存會連加密一起存回去（macOS 的 PDFKit 就是這樣）：頁一頁一頁抄進一份新的文件、書籤照搬，存出來才沒有加密
        let tmp = r.tmp("unlock.pdf")
        try PDFs.write(PDFs.rebuild(d), to: tmp)
        guard let o = PDFDocument(url: tmp), !o.isLocked, !o.isEncrypted, o.pageCount == d.pageCount else {
            throw ToolError.msg(L("解不開：存出來還是有保護", "Couldn’t remove the protection"))
        }
        return ToolResult(outputs: [try r.place(tmp, like: u, suffix: L("（已解鎖）", " (unlocked)"), ext: "pdf")], notes: [note])
    }

    /// 加密：password（開啟要輸入的密碼，必填）；restrict＝同時禁止列印、複製、修改（要另一個擁有者密碼才能解除，會一起給）
    static func protect(_ r: ToolRun) throws -> ToolResult {
        let pw = r.opt.str("password")
        guard pw.count >= 4 else { throw ToolError.msg(L("密碼至少 4 個字", "Use a password of at least 4 characters")) }
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            var opts: [PDFDocumentWriteOption: Any] = [.userPasswordOption: pw, .ownerPasswordOption: pw]
            if r.opt.bool("restrict") {
                let owner = r.opt.has("owner") ? r.opt.str("owner") : pw + "-" + String(UUID().uuidString.prefix(6))
                opts[.ownerPasswordOption] = owner
                opts[.accessPermissionsOption] = NSNumber(value: PDFAccessPermissions.allowsContentAccessibility.rawValue)
                if !res.notes.contains(where: { $0.contains(owner) }) {
                    res.notes.append(L("禁止列印、複製、修改；要解除限制用擁有者密碼：\(owner)（請記下來）", "Printing, copying and editing are blocked; owner password: \(owner) (write it down)"))
                }
            }
            let tmp = r.tmp("protect-\(res.outputs.count).pdf")
            try PDFs.write(d, to: tmp, options: opts)
            guard let o = PDFDocument(url: tmp), o.isLocked, o.unlock(withPassword: pw), o.pageCount == d.pageCount else {
                throw ToolError.msg(L("加密後驗不過（打不開或不用密碼就能開），沒交出去", "Encryption check failed, so it wasn’t saved"))
            }
            res.outputs.append(try r.place(tmp, like: u, suffix: L("（已加密）", " (protected)"), ext: "pdf"))
        }
        res.notes.insert(L("打開要輸入密碼；密碼 Slimly 沒有存，忘了就打不開", "Opening needs the password; Slimly doesn’t keep it"), at: 0)
        return res
    }
}

// MARK: - 塗黑個資：真的刪掉（被塗的頁換成圖＋可搜尋文字），不是蓋一塊黑

enum Redact {
    static let presets: [String: (String, String)] = [
        "phone": (#"(?<!\d)(?:09\d{2}[-\s]?\d{3}[-\s]?\d{3}|0\d{1,2}[-\s]?\d{6,8}|\+886[-\s]?9\d{2}[-\s]?\d{3}[-\s]?\d{3})(?!\d)"#, "電話"),
        "email": (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "Email"),
        "id":    (#"(?<![A-Za-z0-9])[A-Z][12]\d{8}(?!\d)"#, "身分證字號"),
        "card":  (#"(?<!\d)(?:\d{4}[-\s]?){3}\d{4}(?!\d)"#, "信用卡號"),
        "taxid": (#"(?<!\d)\d{8}(?!\d)"#, "統一編號（任何 8 位數字）"),
    ]

    static func run(_ r: ToolRun) throws -> ToolResult {
        var terms = r.opt.str("text").components(separatedBy: CharacterSet(charactersIn: ",，、\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var regs: [(NSRegularExpression, String)] = []
        for k in r.opt.str("presets").components(separatedBy: CharacterSet(charactersIn: ", ")) where !k.isEmpty {
            if let (p, name) = presets[k], let re = try? NSRegularExpression(pattern: p) { regs.append((re, name)) }
        }
        if r.opt.has("regex") {
            guard let re = try? NSRegularExpression(pattern: r.opt.str("regex")) else { throw ToolError.msg(L("規則寫法看不懂", "Invalid pattern")) }
            regs.append((re, r.opt.str("regex")))
        }
        terms = Array(Set(terms))
        guard !terms.isEmpty || !regs.isEmpty else { throw ToolError.msg(L("要寫塗黑哪些字（例：王小明, 0912-345-678），或勾電話、Email、身分證字號", "Enter words to redact, or pick phone / email / ID")) }
        let keepText = r.opt.bool("keep_text", true)
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            var boxes: [Int: [CGRect]] = [:]                   // 頁 → 要塗的框（原頁座標）
            var found: [String] = []
            func add(_ sel: PDFSelection) {
                for line in sel.selectionsByLine() {
                    for p in line.pages {
                        guard let i = d.index(for: p) as Int?, i >= 0 else { continue }
                        let b = line.bounds(for: p).insetBy(dx: -1.5, dy: -1.5)
                        if b.width > 0, b.height > 0 { boxes[i, default: []].append(b) }
                    }
                }
            }
            // 在修過部首的頁面文字裡找（長度跟原文一樣，找到的位置直接換成選取範圍）；PDFKit 的 findString 會漏掉部首碼位的字
            for i in 0..<d.pageCount {
                guard let p = d.page(at: i) else { continue }
                let s = PDFs.text(p), ns = s as NSString
                guard ns.length > 0 else { continue }
                for t in terms {
                    var from = 0
                    while from < ns.length {
                        let f = ns.range(of: PDFs.fixRadicals(t), options: [.caseInsensitive], range: NSRange(location: from, length: ns.length - from))
                        if f.location == NSNotFound { break }
                        if let sel = p.selection(for: f) { add(sel); found.append(t) }
                        from = f.location + max(1, f.length)
                    }
                }
                for (re, _) in regs {
                    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                        if let sel = p.selection(for: m.range) { add(sel); found.append(ns.substring(with: m.range)) }
                    }
                }
            }
            guard !boxes.isEmpty else { res.notes.append(L("「\(u.lastPathComponent)」裡找不到要塗的字，沒產出新檔", "Nothing to redact in “\(u.lastPathComponent)”")); continue }
            let tmp = r.tmp("redact.pdf")
            let n = d.pageCount
            try Overlay.render(d, to: tmp, progress: { r.progress(L("第 \($0 + 1)／\(n) 頁", "Page \($0 + 1)/\(n)"), Double($0) / Double(n)) }, page: { ctx, page, size, i in
                guard let bs = boxes[i] else { return false }
                // 這一頁：畫成 200 dpi 的圖、在圖上塗黑，整頁換成這張圖（原本的字與向量都不帶過來）
                guard let img = Raster.page(page, dpi: 200, extra: { c, _ in
                    c.setFillColor(CGColor(gray: 0, alpha: 1))
                    for b in bs { c.fill(Overlay.map(b, page)) }
                }), let jpg = Raster.encode(img, quality: 0.9), let ji = Raster.jpegImage(jpg) else { return false }
                ctx.draw(ji, in: CGRect(origin: .zero, size: size))
                if keepText { OCR.drawInvisible(OCR.lines(in: img), in: ctx, size: size) }   // 沒塗到的字照樣可以搜尋
                return true
            }) { _, _, _ in }
            // 驗收：塗掉的字在新檔裡要搜不到
            guard let o = PDFDocument(url: tmp), o.pageCount == n else { throw ToolError.msg(L("塗黑後的檔打不開，沒交出去", "The redacted file didn’t open")) }
            for i in 0..<n {
                let s = PDFs.text(o.page(at: i))
                for t in terms where s.range(of: PDFs.fixRadicals(t), options: .caseInsensitive) != nil {
                    throw ToolError.msg(L("第 \(i + 1) 頁塗完還搜得到「\(t)」，沒交出去", "“\(t)” is still searchable on page \(i + 1), so nothing was saved"))
                }
                for (re, name) in regs where re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil && boxes[i] != nil {
                    throw ToolError.msg(L("第 \(i + 1) 頁塗完還搜得到\(name)，沒交出去", "Page \(i + 1) still has a \(name) match, so nothing was saved"))
                }
            }
            res.outputs.append(try r.place(tmp, like: u, suffix: L("（已塗黑）", " (redacted)"), ext: "pdf"))
            let pages = boxes.keys.sorted().map { "\($0 + 1)" }.joined(separator: "、")
            res.notes.append(L("塗了 \(found.count) 處（第 \(pages) 頁）；那幾頁換成圖片，原本的字已刪掉，驗過搜不到", "\(found.count) spots on pages \(pages); those pages became images and the text is gone (verified)"))
        }
        guard !res.outputs.isEmpty else { throw ToolError.msg(res.notes.first ?? L("找不到要塗的字", "Nothing to redact")) }
        return res
    }
}

// MARK: - 比較兩版：畫面哪裡不一樣＋文字哪幾行改了，做成一份報告

enum Compare {
    static func run(_ r: ToolRun) throws -> ToolResult {
        let ua = r.inputs[0], ub = r.inputs[1]
        let a = try PDFs.open(ua), b = try PDFs.open(ub)
        let n = max(a.pageCount, b.pageCount)
        struct PageDiff { let i: Int; let frac: Double; let cells: [CGRect]; let removed: [String]; let added: [String]; let imgA: CGImage?; let imgB: CGImage? }
        var diffs: [PageDiff] = []
        for i in 0..<n {
            r.progress(L("比第 \(i + 1)／\(n) 頁", "Comparing page \(i + 1)/\(n)"), Double(i) / Double(n))
            let pa = i < a.pageCount ? a.page(at: i) : nil, pb = i < b.pageCount ? b.page(at: i) : nil
            let ia = pa.flatMap { Raster.page($0, dpi: 100) }, ib = pb.flatMap { Raster.page($0, dpi: 100) }
            var cells: [CGRect] = [], frac = 1.0
            if let ia, let ib { (frac, cells) = visual(ia, ib) }
            let la = lines(pa), lb = lines(pb)
            var rem: [String] = [], add: [String] = []
            for c in lb.difference(from: la) {
                switch c { case .remove(_, let s, _): rem.append(s); case .insert(_, let s, _): add.append(s) }
            }
            diffs.append(PageDiff(i: i, frac: frac, cells: cells, removed: rem, added: add, imgA: ia, imgB: ib))
        }
        let changed = diffs.filter { $0.frac > 0.002 || !$0.removed.isEmpty || !$0.added.isEmpty }
        // 報告：A4 橫式。第一頁摘要＋文字差異；之後每個有改的頁：左舊右新，新的那邊把變了的地方框紅
        let tmp = r.tmp("compare.pdf")
        var mb = CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let ctx = CGContext(tmp as CFURL, mediaBox: &mb, nil) else { throw ToolError.msg(L("寫不出報告", "Couldn’t write the report")) }
        let ink = CGColor(gray: 0.12, alpha: 1), mid = CGColor(gray: 0.45, alpha: 1)
        let red = CGColor(red: 0.85, green: 0.12, blue: 0.1, alpha: 1), green = CGColor(red: 0.1, green: 0.55, blue: 0.2, alpha: 1)
        var summary: [String] = []
        summary.append(L("舊：\(ua.lastPathComponent)（\(a.pageCount) 頁）", "Old: \(ua.lastPathComponent) (\(a.pageCount) pages)"))
        summary.append(L("新：\(ub.lastPathComponent)（\(b.pageCount) 頁）", "New: \(ub.lastPathComponent) (\(b.pageCount) pages)"))
        summary.append(changed.isEmpty ? L("兩份看起來一模一樣", "No differences found") : L("\(changed.count) 頁有改：", "\(changed.count) pages differ:"))
        for d in changed {
            summary.append(L("第 \(d.i + 1) 頁：畫面 \(String(format: "%.1f", d.frac * 100))% 不同；文字 −\(d.removed.count) ＋\(d.added.count) 行",
                             "Page \(d.i + 1): \(String(format: "%.1f", d.frac * 100))% of the page differs; text −\(d.removed.count) +\(d.added.count) lines"))
        }
        // 第一頁：摘要與文字差異（放得下多少放多少）
        ctx.beginPDFPage(nil)
        var y: CGFloat = 595 - 48
        func put(_ s: String, _ c: CGColor, _ size: CGFloat = 10, bold: Bool = false) {
            guard y > 36 else { return }
            let l = Overlay.line(String(s.prefix(150)), size: size, bold: bold, color: c)
            Overlay.draw(l, in: ctx, at: CGPoint(x: 40, y: y), h: -1, v: 1)
            y -= size * 1.5
        }
        put(L("Slimly 比較報告", "Slimly comparison"), ink, 16, bold: true); y -= 6
        for s in summary { put(s, ink, 10.5) }
        y -= 8
        for d in changed where !d.removed.isEmpty || !d.added.isEmpty {
            put(L("第 \(d.i + 1) 頁的文字", "Text on page \(d.i + 1)"), mid, 10, bold: true)
            for s in d.removed.prefix(12) { put("− " + s, red) }
            for s in d.added.prefix(12) { put("＋ " + s, green) }
            if d.removed.count > 12 || d.added.count > 12 { put(L("…（還有）", "… (more)"), mid) }
        }
        ctx.endPDFPage()
        for d in changed {
            ctx.beginPDFPage(nil)
            Overlay.draw(Overlay.line(L("第 \(d.i + 1) 頁：左＝舊、右＝新（紅框＝不一樣的地方）", "Page \(d.i + 1): left = old, right = new (red = changed)"), size: 11, bold: true, color: ink),
                         in: ctx, at: CGPoint(x: 40, y: 595 - 36), h: -1, v: 1)
            let slot = CGSize(width: 371, height: 500)
            func place(_ img: CGImage?, x: CGFloat) -> CGRect? {
                guard let img else { return nil }
                let k = min(slot.width / CGFloat(img.width), slot.height / CGFloat(img.height))
                let rect = CGRect(x: x, y: 30 + (slot.height - CGFloat(img.height) * k) / 2, width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
                ctx.draw(img, in: rect)
                ctx.setStrokeColor(CGColor(gray: 0.8, alpha: 1)); ctx.setLineWidth(0.5); ctx.stroke(rect)
                return rect
            }
            _ = place(d.imgA, x: 40)
            if let rb = place(d.imgB, x: 431), let ib = d.imgB {
                let kx = rb.width / CGFloat(ib.width), ky = rb.height / CGFloat(ib.height)
                ctx.setStrokeColor(red); ctx.setLineWidth(1.2)
                ctx.setFillColor(CGColor(red: 0.85, green: 0.12, blue: 0.1, alpha: 0.12))
                for c in d.cells {
                    let rr = CGRect(x: rb.minX + c.minX * kx, y: rb.minY + (CGFloat(ib.height) - c.maxY) * ky, width: c.width * kx, height: c.height * ky)
                    ctx.fill(rr); ctx.stroke(rr)
                }
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try PDFs.verify(tmp, pages: 1 + changed.count)
        let dst = try r.place(tmp, like: ua, suffix: L(" 對 \(PDFs.stem(ub))（比較）", " vs \(PDFs.stem(ub)) (comparison)"), ext: "pdf")
        return ToolResult(outputs: [dst], text: summary.joined(separator: "\n"), notes: [summary[2]])
    }

    /// 頁面文字，一行一筆（去掉空白行）
    private static func lines(_ p: PDFPage?) -> [String] {
        PDFs.text(p).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 兩張圖切 6×6 格比平均色：回傳變了的比例、變了的區塊（合併成矩形，圖的像素座標、原點左上）
    private static func visual(_ a: CGImage, _ b: CGImage) -> (Double, [CGRect]) {
        let w = a.width, h = a.height
        func pixels(_ img: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 255, count: w * h * 4)
            px.withUnsafeMutableBytes { buf in
                let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                c?.interpolationQuality = .high
                c?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return px
        }
        let pa = pixels(a), pb = pixels(b)
        let cell = 6, cw = w / cell, ch = h / cell
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: max(1, cw)), count: max(1, ch))
        var changed = 0
        for cy in 0..<ch {
            for cx in 0..<cw {
                var d = 0
                for yy in (cy * cell)..<((cy + 1) * cell) {
                    for xx in (cx * cell)..<((cx + 1) * cell) {
                        let o = (yy * w + xx) * 4
                        d += abs(Int(pa[o]) - Int(pb[o])) + abs(Int(pa[o + 1]) - Int(pb[o + 1])) + abs(Int(pa[o + 2]) - Int(pb[o + 2]))
                    }
                }
                if d / (cell * cell * 3) > 28 { grid[cy][cx] = true; changed += 1 }
            }
        }
        // 相連的格子合成矩形（一列一列往下長）
        var rects: [CGRect] = []
        var used = grid.map { $0.map { _ in false } }
        for cy in 0..<ch {
            for cx in 0..<cw where grid[cy][cx] && !used[cy][cx] {
                var x1 = cx
                while x1 + 1 < cw && grid[cy][x1 + 1] && !used[cy][x1 + 1] { x1 += 1 }
                var y1 = cy
                while y1 + 1 < ch && (cx...x1).allSatisfy({ grid[y1 + 1][$0] && !used[y1 + 1][$0] }) { y1 += 1 }
                for yy in cy...y1 { for xx in cx...x1 { used[yy][xx] = true } }
                rects.append(CGRect(x: cx * cell - 2, y: cy * cell - 2, width: (x1 - cx + 1) * cell + 4, height: (y1 - cy + 1) * cell + 4))
            }
        }
        return (Double(changed) / Double(max(1, cw * ch)), Array(rects.prefix(400)))
    }
}
