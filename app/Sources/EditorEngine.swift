// EditorEngine.swift — 編輯器 2.2 的引擎層：對齊 Acrobat 的「改字、改圖、註解、存檔」
//
// 2.1 的存檔把改過字、塗黑的頁整頁換成 300 dpi 的圖；2.2 改成跟 Acrobat 一樣動原本的內容：
//   ・改字：只刪那幾行的字形（MuPDF 的 redaction，細帶子從每個字的框中間穿過），新的字疊上去（跟原本同一種字型）
//   ・原本的圖：改內容串流裡那一個 Do（搬、縮放、轉、刪、換），圖不重新壓縮
//   ・塗黑、擦掉：框裡的字、圖的像素、整個蓋住的線真的刪掉
//   ・新加的字、圖、簽名、頁碼、浮水印：畫成一頁，當表單疊在原頁上面（原頁的連結、表單、註解都留著）
//   ・註解（螢光筆、底線、刪除線、便利貼、文字框、形狀、手寫、印章）、連結、書籤：存成真的 PDF 物件，別的軟體也能改
// 引擎＝app 內的 bin/mutool（MuPDF，AGPL，子程序）＋ mu/slimly-mu.js（我們的腳本）；PDFKit 管頁面、註解、書籤、加密。
import AppKit
import CoreText
import PDFKit

// MARK: - MuPDF

enum MuTool {
    /// 包內 mutool；測試可用 --mutool <路徑> 換掉
    static var path: String {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--mutool"), a.count > i + 1 { return a[i + 1] }
        return Bundle.main.resourceURL!.appendingPathComponent("bin/mutool").path
    }
    static var script: String { Bundle.main.resourceURL!.appendingPathComponent("mu/slimly-mu.js").path }

    /// 跑一次：mutool run slimly-mu.js <args>；回最後一行 JSON。逾時、沒結果、回 error 都丟錯（錯誤訊息照引擎講的）
    static func run(_ args: [String], timeout: TimeInterval = 180, stdin: String? = nil) throws -> [String: Any] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["run", script] + args
        let o = Pipe(), e = Pipe(), i = Pipe()
        p.standardOutput = o; p.standardError = e
        p.standardInput = stdin == nil ? FileHandle.nullDevice : i                   // 密碼只走 stdin：不上指令列（ps 看得到）、不寫進檔案
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { throw ToolError.msg(L("編輯引擎啟動不了：\(error.localizedDescription)", "The editing engine didn’t start: \(error.localizedDescription)")) }
        // 兩條輸出各用一條執行緒讀到底（讀完＝引擎結束、管子關了）：最後一行結果不會漏（舊的寫法在結束那一刻拆掉讀取，偶爾會掉最後一行），輸出很多也不會塞住
        final class Box: @unchecked Sendable { var out = Data(), err = Data() }
        let box = Box(), reads = DispatchGroup()
        reads.enter(); DispatchQueue.global(qos: .userInitiated).async { box.out = o.fileHandleForReading.readDataToEndOfFile(); reads.leave() }
        reads.enter(); DispatchQueue.global(qos: .userInitiated).async { box.err = e.fileHandleForReading.readDataToEndOfFile(); reads.leave() }
        if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)); try? i.fileHandleForWriting.close() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate(); _ = done.wait(timeout: .now() + 2); _ = reads.wait(timeout: .now() + 2)
            throw ToolError.msg(L("編輯引擎沒有回應（超過 \(Int(timeout)) 秒）", "The editing engine timed out"))
        }
        _ = reads.wait(timeout: .now() + 10)
        let od = box.out, ed = box.err.suffix(4096)
        let text = String(decoding: od, as: UTF8.self)
        guard let last = text.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let j = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any] else {
            let tail = String(decoding: ed, as: UTF8.self).split(separator: "\n").suffix(2).joined(separator: " ")
            throw ToolError.msg(L("編輯引擎沒有結果", "The editing engine returned nothing") + (tail.isEmpty ? "" : "（\(tail)）"))
        }
        if let err = j["error"] as? String { throw ToolError.msg(L("編輯引擎：\(err)", "Editing engine: \(err)")) }
        return j
    }
    static func json(_ o: Any, to u: URL) throws {
        let d = try JSONSerialization.data(withJSONObject: o)
        try d.write(to: u, options: .atomic)
    }
}

// MARK: - 字型：PDF 裡的字型名 → 這台 Mac 上最接近的字型（畫面上的 CSS 跟存檔時的 CoreText 用同一個）

enum FontMatch {
    struct M { let family: String; let weight: Int; let italic: Bool; let asc: Double; let desc: Double; let exact: Bool }
    private static var cache: [String: M] = [:]
    private static let lock = NSLock()
    static let families: Set<String> = Set(NSFontManager.shared.availableFontFamilies)

    /// 選單上的字型（這台有的才列）：中文三種、英文常用幾種
    static let menu: [String] = ["PingFang TC", "Songti TC", "Kaiti TC", "Heiti TC", "Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Avenir Next", "Futura", "Menlo", "Courier New"]
    static func menuList() -> [[String: Any]] {
        menu.filter { families.contains($0) }.map { f in
            let (a, d) = metrics(f, weight: 400, italic: false)
            return ["fam": f, "asc": a, "desc": d]
        }
    }

    static func isCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) || (0x20000...0x2FA1F).contains($0.value) }
    }

    static func match(_ raw: String, flags: Int, sample: String) -> M {
        let cjk = isCJK(sample)
        let key = "\(raw)|\(flags)|\(cjk)"
        lock.lock(); if let m = cache[key] { lock.unlock(); return m }; lock.unlock()
        var name = raw
        if let r = name.range(of: "^[A-Z]{6}\\+", options: .regularExpression) { name.removeSubrange(r) }
        var hint = ""
        if let c = name.firstIndex(of: ",") { hint = String(name[name.index(after: c)...]); name = String(name[..<c]) }
        let low = (name + " " + hint).lowercased()
        var weight = 400
        if ["black", "heavy", "extrabold", "ultrabold", "w9"].contains(where: low.contains) { weight = 800 }
        else if ["semibold", "demibold", "demi", "w6"].contains(where: low.contains) { weight = 600 }
        else if ["bold", "w7", "w8"].contains(where: low.contains) { weight = 700 }
        else if ["medium", "w5"].contains(where: low.contains) { weight = 500 }
        else if ["light", "thin", "w3", "w2", "w1"].contains(where: low.contains) { weight = 300 }
        if flags & 1 != 0 && weight < 600 { weight = 700 }
        var italic = flags & 2 != 0 || low.contains("italic") || low.contains("oblique")
        var family = "", exact = false
        // 1) 這台有同一個字型（PostScript 名稱）
        if let f = NSFont(name: name, size: 12), let fam = f.familyName, families.contains(fam) {
            family = fam; exact = true
            weight = cssWeight(NSFontManager.shared.weight(of: f))
            italic = NSFontManager.shared.traits(of: f).contains(.italicFontMask) || italic
        } else if families.contains(name) {
            family = name; exact = true
        } else {
            // 2) 沒有就照名字猜類型
            let mono = flags & 8 != 0 || ["courier", "mono", "consol", "menlo", "code"].contains(where: low.contains)
            let kai = ["kai", "楷", "biaukai"].contains(where: low.contains)
            let cjkSerif = ["ming", "mincho", "song", "sun", "明", "宋", "batang", "fangsong", "仿宋"].contains(where: low.contains) || (low.contains("serif") && !low.contains("sans") && cjk)
            let cjkName = ["jhenghei", "yahei", "gothic", "hei", "黑", "dengxian", "cjk", "source han", "pingfang", "hiragino", "noto sans tc", "noto sans sc"].contains(where: low.contains)
            let serif = ["times", "roman", "georgia", "garamond", "cambria", "book", "minion", "palatino", "baskerville", "caslon", "bodoni", "didot", "century", "charter", "merriweather", "lora", "playfair"].contains(where: low.contains)
                || (low.contains("serif") && !low.contains("sans"))
            if cjk || cjkName || kai || cjkSerif { family = kai ? "Kaiti TC" : cjkSerif ? "Songti TC" : "PingFang TC" }
            else if mono { family = "Menlo" }
            else if serif { family = "Times New Roman" }
            else { family = "Helvetica Neue" }
            if !families.contains(family) { family = cjk ? "PingFang TC" : "Helvetica Neue" }
        }
        let (a, d) = metrics(family, weight: weight, italic: italic)
        let m = M(family: family, weight: weight, italic: italic, asc: a, desc: d, exact: exact)
        lock.lock(); cache[key] = m; lock.unlock()
        return m
    }

    static func cssWeight(_ ns: Int) -> Int {
        switch ns { case ..<3: return 200; case 3...4: return 300; case 5: return 400; case 6: return 500; case 7...8: return 600; case 9: return 700; default: return 800 }
    }
    static func nsWeight(_ css: Int) -> Int {
        switch css { case ..<250: return 3; case 250..<350: return 4; case 350..<450: return 5; case 450..<550: return 6; case 550..<650: return 8; case 650..<750: return 9; default: return 10 }
    }

    /// CSS 的（字族、粗細、斜體、大小）→ CoreText 字型；中文字缺字時接蘋方（跟畫面上的 font-family 後備同一個）
    static func ctFont(_ family: String, weight: Int, italic: Bool, size: CGFloat) -> CTFont {
        let fm = NSFontManager.shared
        var f: NSFont? = fm.font(withFamily: family, traits: italic ? [.italicFontMask] : [], weight: nsWeight(weight), size: size)
        var fakeItalic = false
        if f == nil && italic { f = fm.font(withFamily: family, traits: [], weight: nsWeight(weight), size: size); fakeItalic = f != nil }
        if f == nil { f = fm.font(withFamily: "PingFang TC", traits: [], weight: nsWeight(weight), size: size) }
        let base: CTFont = (f ?? NSFont.systemFont(ofSize: size)) as CTFont
        let cjkName = weight >= 550 ? "PingFangTC-Semibold" : "PingFangTC-Regular"
        let cascade = [CTFontDescriptorCreateWithNameAndSize(cjkName as CFString, size)] as CFArray
        let desc = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [kCTFontCascadeListAttribute: cascade] as CFDictionary)
        if fakeItalic {                                                   // 沒有斜體的字族：跟瀏覽器一樣斜 12°
            var m = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
            return CTFontCreateWithFontDescriptor(desc, size, &m)
        }
        return CTFontCreateWithFontDescriptor(desc, size, nil)
    }
    static func metrics(_ family: String, weight: Int, italic: Bool) -> (Double, Double) {
        let f = ctFont(family, weight: weight, italic: italic, size: 1000)
        return (Double(CTFontGetAscent(f)) / 1000, Double(CTFontGetDescent(f)) / 1000)
    }
}

// MARK: - 頁面座標：原頁（未旋轉、含裁切原點）↔ 顯示方向（原點左上）

struct PageGeo {
    let A: CGAffineTransform           // 原頁 → 顯示方向（原點左下、y 向上）
    let Ai: CGAffineTransform
    let size: CGSize
    init(_ p: PDFPage) {
        let o = Overlay.mapPoint(CGPoint(x: 0, y: 0), p), x = Overlay.mapPoint(CGPoint(x: 1, y: 0), p), y = Overlay.mapPoint(CGPoint(x: 0, y: 1), p)
        A = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
        Ai = A.inverted()
        size = Overlay.displaySize(p)
    }
    /// 顯示方向（原點左上）→ 原頁
    func raw(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: size.height - y).applying(Ai) }
    func rawRect(_ r: CGRect) -> CGRect {
        let ps = [raw(r.minX, r.minY), raw(r.maxX, r.minY), raw(r.minX, r.maxY), raw(r.maxX, r.maxY)]
        let xs = ps.map(\.x), ys = ps.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    /// 原頁 → 顯示方向（原點左上）
    func disp(_ p: CGPoint) -> CGPoint { let q = p.applying(A); return CGPoint(x: q.x, y: size.height - q.y) }
    func dispRect(_ r: CGRect) -> CGRect {
        let ps = [disp(CGPoint(x: r.minX, y: r.minY)), disp(CGPoint(x: r.maxX, y: r.minY)), disp(CGPoint(x: r.minX, y: r.maxY)), disp(CGPoint(x: r.maxX, y: r.maxY))]
        let xs = ps.map(\.x), ys = ps.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

// MARK: - 編輯中的文件：MuPDF 讀字、讀圖、預覽（改過的頁）、既有註解

extension EditorDoc {
    /// 一頁單獨存成一份（MuPDF 讀字、畫預覽用）；頁的版本變了才重寫
    func pageFile(_ id: String) -> URL? {
        guard !closed, let i = index(id) else { return nil }
        let p = pages[i]
        let u = work.appendingPathComponent("pg-\(id)-v\(p.v).pdf")
        if FileManager.default.fileExists(atPath: u.path) { return u }
        guard let c = p.page.copy() as? PDFPage else { return nil }
        let d = PDFDocument(); d.insert(c, at: 0)
        return d.write(to: u) ? u : nil
    }

    /// 這一頁的字（逐行：每個字的框、字型對到這台的哪一個、大小、顏色）＋原本的圖（第幾張、位置）
    func pageText(_ id: String) -> [String: Any] {
        guard let i = index(id) else { return [:] }
        let key = "\(id)-v\(pages[i].v)"
        if let c = textCache[key] { return c }
        guard let f = pageFile(id), var j = try? MuTool.run(["text", f.path, "0"], timeout: 60) else { return ["lines": [], "imgs": []] }
        var lines = (j["lines"] as? [[String: Any]]) ?? []
        let inv = (j["inv"] as? Bool) ?? false
        let small = inv ? EditorDoc.raster(pages[i].page, dpi: 72, fills: []) : nil
        let sz = Overlay.displaySize(pages[i].page)
        for li in lines.indices {
            var ch = (lines[li]["ch"] as? [String]) ?? []
            ch = ch.map { PDFs.fixRadicals($0) }                   // 蘋方的康熙部首（⾏→行）：一個換一個，位置不變
            lines[li]["ch"] = ch
            var runs = (lines[li]["runs"] as? [[String: Any]]) ?? []
            for ri in runs.indices {
                let start = (runs[ri]["i"] as? Int) ?? 0, end = ri + 1 < runs.count ? ((runs[ri + 1]["i"] as? Int) ?? ch.count) : ch.count
                let sample = ch[min(start, ch.count)..<min(max(start, end), ch.count)].joined()
                let m = FontMatch.match((runs[ri]["f"] as? String) ?? "", flags: (runs[ri]["fl"] as? Int) ?? 0, sample: sample)
                runs[ri]["fam"] = m.family; runs[ri]["wt"] = m.weight; runs[ri]["it"] = m.italic
                runs[ri]["asc"] = m.asc; runs[ri]["desc"] = m.desc; runs[ri]["ex"] = m.exact
            }
            lines[li]["runs"] = runs
            if let small, let b = lines[li]["b"] as? [Double], b.count == 4 {       // 掃描的頁：改字要蓋一塊跟紙一樣的底色
                let r = CGRect(x: b[0], y: Double(sz.height) - b[3], width: b[2] - b[0], height: b[3] - b[1])
                lines[li]["bg"] = EditorDoc.background(small, r, sz)
            }
        }
        j["lines"] = lines
        textCache[key] = j
        return j
    }

    /// 原本的第 k 張圖（畫面上搬移中的圖用）
    func ximgPNG(_ id: String, _ k: Int) -> Data? {
        guard let i = index(id), let f = pageFile(id) else { return nil }
        let u = work.appendingPathComponent("xi-\(id)-v\(pages[i].v)-\(k).png")
        if !FileManager.default.fileExists(atPath: u.path) {
            guard (try? MuTool.run(["img", f.path, "0", String(k), u.path], timeout: 60)) != nil else { return nil }
        }
        return try? Data(contentsOf: u)
    }

    /// 改過的頁的預覽：改字的那幾行、搬走的圖先真的拿掉，再畫（跟存出來的一樣）
    func renderMods(_ id: String, width: CGFloat, mods: String) -> Data? {
        guard let i = index(id), let f = pageFile(id),
              let m = (try? JSONSerialization.jsonObject(with: Data(mods.utf8))) as? [String: Any] else { return render(id, width: width) }
        var h = Hasher(); h.combine(mods); let hv = String(UInt(bitPattern: h.finalize()), radix: 36)
        let outU = work.appendingPathComponent("mx-\(id)-v\(pages[i].v)-\(hv).pdf")
        if !FileManager.default.fileExists(atPath: outU.path) {
            let imgs = ((m["imgs"] as? [[String: Any]]) ?? []).map { ["k": $0["k"] ?? 0, "op": "del", "b": $0["b"] ?? []] as [String: Any] }
            let spec: [String: Any] = ["pages": [["i": 0, "bands": m["bands"] ?? [], "img": imgs] as [String: Any]]]
            let su = work.appendingPathComponent("mx-\(id)-\(hv).json")
            do { try MuTool.json(spec, to: su); _ = try MuTool.run(["apply", f.path, su.path, outU.path], timeout: 60) }
            catch { FileHandle.standardError.write(Data("MODS ERR \(id): \((error as? ToolError)?.text ?? error.localizedDescription)\n".utf8)); return render(id, width: width) }
        }
        guard let d = PDFDocument(url: outU), let p = d.page(at: 0) else { FileHandle.standardError.write(Data("MODS ERR \(id): output unreadable\n".utf8)); return render(id, width: width) }
        return EditorDoc.renderPage(p, width: width)
    }

    // MARK: 既有的註解（別的軟體或上一次存的）：畫面上當成可以改的物件

    func annotations(_ id: String) -> [[String: Any]] {
        guard let p = page(id) else { return [] }
        let geo = PageGeo(p)
        var out: [[String: Any]] = []
        let ann = p.annotations
        // PDFKit 讀不到 /IRT（回覆誰）、附加檔案的大小：有便利貼或附加檔案的來源頁才問 MuPDF（照 /Annots 的順序，跟 PDFKit 一樣含 Popup）
        let meta: [[String: Any]] = ann.contains(where: { ["Text", "FileAttachment"].contains($0.type ?? "") }) ? sourceIndex(id).map { annMeta($0) } ?? [] : []
        let aligned = meta.count == ann.count && zip(meta, ann).allSatisfy { ($0["sub"] as? String) == $1.type }
        func metaOf(_ ai: Int, _ a: PDFAnnotation) -> [String: Any]? {
            if aligned { return meta[ai] }
            guard let nm = a.value(forAnnotationKey: .name) as? String else { return nil }
            return meta.first { ($0["nm"] as? String) == nm }
        }
        func aidOf(_ k: Int) -> Int? {                                   // /Annots 的第 k 個在 PDFKit 是第幾個
            if aligned { return k }
            guard k < meta.count, let nm = meta[k]["nm"] as? String else { return nil }
            return ann.firstIndex { ($0.value(forAnnotationKey: .name) as? String) == nm }
        }
        for (ai, a) in ann.enumerated() {
            let type = a.type ?? ""
            if ["Popup", "Widget"].contains(type) { continue }
            let r = geo.dispRect(a.bounds)
            var o: [String: Any] = ["aid": ai, "sub": type, "x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height),
                                    "note": a.contents ?? "", "author": a.userName ?? "", "color": a.color.alphaComponent > 0 ? EditorDoc.hex(a.color) : ""]
            if let d = a.modificationDate { o["date"] = d.timeIntervalSince1970 }
            if let nm = a.value(forAnnotationKey: .name) as? String { o["nm"] = nm }
            let me = metaOf(ai, a)
            let origin = a.bounds.origin
            func dpt(_ v: NSPoint) -> [Double] { let q = geo.disp(CGPoint(x: origin.x + v.x, y: origin.y + v.y)); return [Double(q.x), Double(q.y)] }
            switch type {
            case "Link":
                o["t"] = "link"
                if let u = a.url ?? (a.action as? PDFActionURL)?.url { o["url"] = u.absoluteString }
                else if let d = a.destination ?? (a.action as? PDFActionGoTo)?.destination, let dp = d.page, let pi = pages.firstIndex(where: { $0.page == dp }) {
                    o["page"] = pages[pi].id
                    if d.point.y != kPDFDestinationUnspecifiedValue { o["py"] = Double(PageGeo(dp).disp(d.point).y) }
                } else { continue }
            case "Highlight", "Underline", "StrikeOut":
                o["t"] = ["Highlight": "hl", "Underline": "ul", "StrikeOut": "so"][type]!
                let q = (a.quadrilateralPoints ?? []).map { $0.pointValue }
                var quads: [[Double]] = []
                var k = 0
                while k + 3 < q.count {
                    let ps = q[k..<k + 4].map { dpt($0) }
                    let xs = ps.map { $0[0] }, ys = ps.map { $0[1] }
                    quads.append([xs.min()!, ys.min()!, xs.max()!, ys.max()!]); k += 4
                }
                if quads.isEmpty { quads = [[Double(r.minX), Double(r.minY), Double(r.maxX), Double(r.maxY)]] }
                o["quads"] = quads
            case "Text":
                // 回覆（/IRT 指到別的註解、/RT 沒寫或是 /R）：畫面上不單獨畫，收進上一層的對話裡
                if let k = me?["irt"] as? Int, ((me?["rt"] as? String) ?? "R") == "R", let pa = aidOf(k), pa != ai {
                    o["t"] = "reply"; o["parent"] = pa
                } else { o["t"] = "note"; o["icon"] = a.iconType.rawValue }
            case "FileAttachment":
                // 附加檔案：檔名、大小、有沒有內容（只有名字的＝壞的）
                o["t"] = "file"
                let f = me?["file"] as? [String: Any]
                let fs = a.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/FS")) as? [String: Any]
                let nm1 = (f?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (fs?["/UF"] as? String) ?? (fs?["/F"] as? String) ?? ""
                o["name"] = nm1
                o["size"] = (f?["size"] as? Int) ?? -1
                if let has = f?["has"] as? Bool { o["has"] = has }                 // 插入、再製的頁問不到：不標成壞的
            case "FreeText":
                o["t"] = "ftext"; o["text"] = a.contents ?? ""; o["size"] = Double(a.font?.pointSize ?? 12)
                o["tc"] = a.fontColor.map { EditorDoc.hex($0) } ?? "#1E2223"
                o["bw"] = Double(a.border?.lineWidth ?? 0)
            case "Square", "Circle":
                o["t"] = type == "Square" ? "rect" : "ellipse"; o["width"] = Double(a.border?.lineWidth ?? 1)
                if let f = a.interiorColor, f.alphaComponent > 0 { o["fill"] = EditorDoc.hex(f) }
            case "Line":
                o["t"] = a.endLineStyle == .none && a.startLineStyle == .none ? "line" : "arrow"
                let s = dpt(a.startPoint), e = dpt(a.endPoint)
                if a.endLineStyle == .none && a.startLineStyle != .none { o["x1"] = e[0]; o["y1"] = e[1]; o["x2"] = s[0]; o["y2"] = s[1] }
                else { o["x1"] = s[0]; o["y1"] = s[1]; o["x2"] = e[0]; o["y2"] = e[1] }
                o["width"] = Double(a.border?.lineWidth ?? 1)
            case "Ink":
                o["t"] = "ink"; o["width"] = Double(a.border?.lineWidth ?? 1)
                o["strokes"] = (a.paths ?? []).map { EditorAnnots.points($0).map { dpt($0) } }
            case "Stamp":
                if let nm = [a.value(forAnnotationKey: .name), a.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj"))].compactMap({ $0 as? String }).first(where: { $0.hasPrefix("slimly:stamp:") }),
                   let j = (try? JSONSerialization.jsonObject(with: Data(nm.dropFirst(13).utf8))) as? [String: Any] {
                    o["t"] = "stamp"; for (k, v) in j { o[k] = v }
                } else { o["t"] = "xann" }
            default:
                o["t"] = "xann"
            }
            out.append(o)
        }
        return out
    }

    /// 一個註解單獨畫成 PNG（畫面上顯示原樣：Acrobat 的印章、特殊外觀都照原本的）
    func annotationPNG(_ id: String, _ ai: Int, scale: CGFloat = 3) -> Data? {
        guard let p = page(id), ai < p.annotations.count else { return nil }
        let a = p.annotations[ai], geo = PageGeo(p), r = geo.dispRect(a.bounds)
        let W = max(1, min(4000, Int((r.width * scale).rounded(.up)))), H = max(1, min(4000, Int((r.height * scale).rounded(.up))))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -r.minX, y: -(geo.size.height - r.maxY))
        ctx.concatenate(geo.A)
        let mb = p.bounds(for: .mediaBox)
        ctx.translateBy(x: mb.minX, y: mb.minY)
        let was = a.shouldDisplay; a.shouldDisplay = true
        a.draw(with: .mediaBox, in: ctx)
        a.shouldDisplay = was
        guard let img = ctx.makeImage() else { return nil }
        return Raster.encode(img, type: .png)
    }
}

// MARK: - 註解、連結：存成真的 PDF 物件（PDFKit 寫外觀，預覽程式、Acrobat 都看得到、改得到）

/// Slimly 的印章：自己畫外觀（PDFKit 內建的「Approved」存出來是空框）
final class SlimlyStamp: PDFAnnotation {
    var label = "", sub = "", tint = NSColor.systemRed, imageURL: URL?
    override func draw(with box: PDFDisplayBox, in ctx: CGContext) {
        ctx.saveGState()
        let b = bounds
        let rot = CGFloat(((page?.rotation ?? 0) % 360 + 360) % 360)
        ctx.translateBy(x: b.midX, y: b.midY)
        if rot != 0 { ctx.rotate(by: rot * .pi / 180) }                  // 轉過的頁：印章在畫面上還是正的
        let w = rot == 90 || rot == 270 ? b.height : b.width, h = rot == 90 || rot == 270 ? b.width : b.height
        let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        if let u = imageURL, let img = Convert.loadAnyImage(u) {
            ctx.interpolationQuality = .high; ctx.draw(img, in: r)
        } else {
            let c = tint.cgColor
            let lw = max(1.2, min(w, h) * 0.045)
            ctx.setStrokeColor(c); ctx.setLineWidth(lw)
            let path = CGPath(roundedRect: r.insetBy(dx: lw, dy: lw), cornerWidth: min(w, h) * 0.18, cornerHeight: min(w, h) * 0.18, transform: nil)
            ctx.addPath(path); ctx.strokePath()
            let main = sub.isEmpty ? h * 0.46 : h * 0.36
            let f1 = FontMatch.ctFont("PingFang TC", weight: 600, italic: false, size: main)
            let l1 = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: f1, .foregroundColor: tint]))
            var a1: CGFloat = 0, d1: CGFloat = 0, g: CGFloat = 0
            var tw = CGFloat(CTLineGetTypographicBounds(l1, &a1, &d1, &g))
            let fit = min(1, (w - lw * 6) / max(1, tw))
            ctx.saveGState(); ctx.scaleBy(x: fit, y: 1)
            let y1 = sub.isEmpty ? -(a1 - d1) / 2 : h * 0.02
            ctx.textPosition = CGPoint(x: -tw / 2, y: y1); CTLineDraw(l1, ctx)
            ctx.restoreGState()
            if !sub.isEmpty {
                let f2 = FontMatch.ctFont("PingFang TC", weight: 400, italic: false, size: h * 0.2)
                let l2 = CTLineCreateWithAttributedString(NSAttributedString(string: sub, attributes: [.font: f2, .foregroundColor: tint]))
                tw = CGFloat(CTLineGetTypographicBounds(l2, &a1, &d1, &g))
                let fit2 = min(1, (w - lw * 6) / max(1, tw))
                ctx.saveGState(); ctx.scaleBy(x: fit2, y: 1)
                ctx.textPosition = CGPoint(x: -tw / 2, y: -h * 0.32); CTLineDraw(l2, ctx)
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }
}

enum EditorAnnots {
    static let types: Set<String> = ["hl", "ul", "so", "note", "ftext", "rect", "ellipse", "line", "arrow", "ink", "stamp", "xann", "link", "xfield", "reply", "file"]
    /// 畫面上物件的代號 → 存進檔案的 /NM（新加的回覆、被回覆的新註解、附加檔案；存檔時 MuPDF 照這個接上）
    static func nmId(_ ui: String) -> String { "s" + ui.filter { $0.isLetter || $0.isNumber || $0 == "-" } }
    /// 被回覆的既有註解沒有 /NM：補一個固定的（PDFKit 那份與 MuPDF 照同一個名字找）
    static func parentNM(_ pageId: String, _ aid: Int) -> String { "slimly-\(pageId)-\(aid)" }

    static func d(_ o: [String: Any], _ k: String, _ def: CGFloat = 0) -> CGFloat { EditorDraw.d(o, k, def) }
    static func color(_ o: [String: Any], _ k: String, _ def: String) -> NSColor {
        let s = (o[k] as? String) ?? def
        return NSColor(cgColor: EditorDraw.color(s.isEmpty ? def : s)) ?? .systemRed
    }
    /// 路徑的點（相對註解框）
    static func points(_ path: NSBezierPath) -> [NSPoint] {
        var out: [NSPoint] = []
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<path.elementCount {
            let e = path.element(at: i, associatedPoints: &pts)
            switch e {
            case .moveTo, .lineTo: out.append(pts[0])
            case .curveTo, .cubicCurveTo: out.append(pts[2])
            case .quadraticCurveTo: out.append(pts[1])
            default: break
            }
        }
        return out
    }

    /// 一頁的註解照畫面改：gone＝刪掉的既有註解（序號）；有 aid 且 dirty 的＝改過（換成新的一個）；沒有 aid 的＝新加的
    static func apply(_ p: PDFPage, objs: [[String: Any]], gone: [Int], images: [String: URL], pageOf: (String) -> PDFPage?, author: String, pageId: String = "") {
        let geo = PageGeo(p)
        let ex = p.annotations
        var remove = Set<Int>(gone.filter { $0 >= 0 && $0 < ex.count })
        var adds: [PDFAnnotation] = [], made: [String: PDFAnnotation] = [:]
        let subj = PDFAnnotationKey(rawValue: "/Subj")
        let parents = Set(objs.compactMap { $0["t"] as? String == "reply" ? $0["pref"] as? String : nil })   // 有人回覆的新註解：名字要固定（MuPDF 照它接回覆）
        for o in objs {
            guard let t = o["t"] as? String, types.contains(t), t != "reply" else { continue }
            if let ai = o["aid"] as? Int {
                guard ai >= 0, ai < ex.count, (o["dirty"] as? Bool) == true else { continue }
                if t == "xann" || t == "xfield" || t == "file" {              // 不認得的註解、既有的表單欄位、附加檔案：只搬位置、改內容，其他照原樣
                    let a = ex[ai]
                    a.bounds = geo.rawRect(CGRect(x: d(o, "x"), y: d(o, "y"), width: d(o, "w"), height: d(o, "h")))
                    if t != "xfield", let n = o["note"] as? String { a.contents = n }
                    a.modificationDate = Date()
                    continue
                }
                remove.insert(ai)
            }
            if let a = make(o, t, geo: geo, images: images, pageOf: pageOf, author: (o["author"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? author) {
                // 新加的都標記：存檔時 MuPDF 只從 PDFKit 那份搬這些過去（原檔其他註解原樣留著）；標記之後搬進 /NM（fixNames）
                if let id = o["id"] as? String, parents.contains(id) || o["aid"] != nil { a.setValue("slimly:new:" + nmId(id), forAnnotationKey: subj); made[id] = a }   // 有人回覆的、改過重做的：名字固定
                else if (a.value(forAnnotationKey: subj) as? String)?.hasPrefix("slimly:") != true { a.setValue("slimly:new:" + UUID().uuidString.prefix(8), forAnnotationKey: subj) }
                adds.append(a)
            }
        }
        // 回覆：既有的只改字（位置跟著上一層）；新的先畫成一張便利貼（位置＝上一層），MuPDF 存檔時接上 /IRT
        for o in objs where o["t"] as? String == "reply" {
            if let ai = o["aid"] as? Int {
                guard ai >= 0, ai < ex.count, (o["dirty"] as? Bool) == true, let n = o["note"] as? String else { continue }
                ex[ai].contents = n; ex[ai].modificationDate = Date(); continue
            }
            guard let id = o["id"] as? String else { continue }
            var parent: PDFAnnotation?
            if let pa = o["paid"] as? Int, pa >= 0, pa < ex.count {
                parent = ex[pa]
                if parent?.value(forAnnotationKey: .name) == nil { parent?.setValue(parentNM(pageId, pa), forAnnotationKey: .name) }
            } else if let pr = o["pref"] as? String { parent = made[pr] }
            guard let par = parent else { continue }
            let a = PDFAnnotation(bounds: par.bounds, forType: .text, withProperties: nil)
            a.iconType = .comment
            a.color = par.color.alphaComponent > 0 ? par.color : color(o, "color", "#FFE066")
            a.contents = (o["note"] as? String) ?? ""
            a.userName = (o["author"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? author
            a.modificationDate = Date()
            a.setValue("slimly:new:" + nmId(id), forAnnotationKey: subj)
            adds.append(a)
        }
        for ai in remove.sorted(by: >) {
            let a = ex[ai]
            if let pop = a.popup { p.removeAnnotation(pop) }
            p.removeAnnotation(a)
        }
        for a in adds { p.addAnnotation(a) }
    }

    static func make(_ o: [String: Any], _ t: String, geo: PageGeo, images: [String: URL], pageOf: (String) -> PDFPage?, author: String) -> PDFAnnotation? {
        let rect = CGRect(x: d(o, "x"), y: d(o, "y"), width: max(1, d(o, "w")), height: max(1, d(o, "h")))
        let note = (o["note"] as? String) ?? ""
        var a: PDFAnnotation
        switch t {
        case "hl", "ul", "so":
            let quads = (o["quads"] as? [[Double]]) ?? []
            guard !quads.isEmpty else { return nil }
            var raws: [[CGPoint]] = []
            for q in quads where q.count == 4 {
                raws.append([geo.raw(q[0], q[1]), geo.raw(q[2], q[1]), geo.raw(q[0], q[3]), geo.raw(q[2], q[3])])
            }
            let xs = raws.flatMap { $0.map(\.x) }, ys = raws.flatMap { $0.map(\.y) }
            let b = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            a = PDFAnnotation(bounds: b, forType: t == "hl" ? .highlight : t == "ul" ? .underline : .strikeOut, withProperties: nil)
            a.quadrilateralPoints = raws.flatMap { $0.map { NSValue(point: NSPoint(x: $0.x - b.minX, y: $0.y - b.minY)) } }
            a.color = color(o, "color", t == "hl" ? "#FFE066" : "#E0301E")
        case "note":
            let b = geo.rawRect(CGRect(x: d(o, "x"), y: d(o, "y"), width: 20, height: 20))
            a = PDFAnnotation(bounds: b, forType: .text, withProperties: nil)
            a.iconType = PDFTextAnnotationIconType(rawValue: (o["icon"] as? Int) ?? 0) ?? .comment
            a.color = color(o, "color", "#FFE066")
        case "ftext":
            a = PDFAnnotation(bounds: geo.rawRect(rect), forType: .freeText, withProperties: nil)
            a.contents = (o["text"] as? String) ?? ""
            a.font = NSFont(name: "PingFangTC-Regular", size: max(4, d(o, "size", 12)))
            a.fontColor = color(o, "tc", "#1E2223")
            a.color = (o["fill"] as? String).flatMap { $0.isEmpty ? nil : NSColor(cgColor: EditorDraw.color($0)) } ?? .clear
            let br = PDFBorder(); br.lineWidth = d(o, "bw", 0); a.border = br
            a.userName = author; a.modificationDate = Date()
            return a
        case "rect", "ellipse":
            a = PDFAnnotation(bounds: geo.rawRect(rect), forType: t == "rect" ? .square : .circle, withProperties: nil)
            a.color = color(o, "color", "#E0301E")
            if let f = o["fill"] as? String, !f.isEmpty { a.interiorColor = NSColor(cgColor: EditorDraw.color(f)) }
            let br = PDFBorder(); br.lineWidth = d(o, "width", 2); a.border = br
        case "line", "arrow":
            let p1 = geo.raw(d(o, "x1"), d(o, "y1")), p2 = geo.raw(d(o, "x2"), d(o, "y2"))
            let lw = d(o, "width", 2), pad = max(6, lw * 5)
            let b = CGRect(x: min(p1.x, p2.x) - pad, y: min(p1.y, p2.y) - pad, width: abs(p2.x - p1.x) + pad * 2, height: abs(p2.y - p1.y) + pad * 2)
            a = PDFAnnotation(bounds: b, forType: .line, withProperties: nil)
            a.startPoint = NSPoint(x: p1.x - b.minX, y: p1.y - b.minY); a.endPoint = NSPoint(x: p2.x - b.minX, y: p2.y - b.minY)
            if t == "arrow" { a.endLineStyle = .closedArrow }
            a.color = color(o, "color", "#E0301E")
            if t == "arrow" { a.interiorColor = a.color }
            let br = PDFBorder(); br.lineWidth = lw; a.border = br
        case "ink":
            var strokes = (o["strokes"] as? [[[Double]]]) ?? []
            if strokes.isEmpty, let pts = o["pts"] as? [[Double]] { strokes = [pts] }
            let raw = strokes.map { $0.compactMap { $0.count >= 2 ? geo.raw(CGFloat($0[0]), CGFloat($0[1])) : nil } }.filter { !$0.isEmpty }
            guard !raw.isEmpty else { return nil }
            let lw = d(o, "width", 2.5), xs = raw.flatMap { $0.map(\.x) }, ys = raw.flatMap { $0.map(\.y) }
            let b = CGRect(x: xs.min()! - lw * 2, y: ys.min()! - lw * 2, width: xs.max()! - xs.min()! + lw * 4, height: ys.max()! - ys.min()! + lw * 4)
            a = PDFAnnotation(bounds: b, forType: .ink, withProperties: nil)
            for s in raw {
                let path = NSBezierPath()
                let P = s.map { NSPoint(x: $0.x - b.minX, y: $0.y - b.minY) }
                path.move(to: P[0])
                if P.count == 1 { path.line(to: NSPoint(x: P[0].x + 0.1, y: P[0].y)) }
                else if P.count == 2 { path.line(to: P[1]) }
                else {
                    for i in 1..<(P.count - 1) {
                        let m = NSPoint(x: (P[i].x + P[i + 1].x) / 2, y: (P[i].y + P[i + 1].y) / 2)
                        path.curve(to: m, controlPoint1: NSPoint(x: path.currentPoint.x + (P[i].x - path.currentPoint.x) * 2 / 3, y: path.currentPoint.y + (P[i].y - path.currentPoint.y) * 2 / 3),
                                   controlPoint2: NSPoint(x: m.x + (P[i].x - m.x) * 2 / 3, y: m.y + (P[i].y - m.y) * 2 / 3))
                    }
                    path.line(to: P[P.count - 1])
                }
                a.add(path)
            }
            a.color = color(o, "color", "#1E2223")
            let br = PDFBorder(); br.lineWidth = lw; a.border = br
        case "stamp":
            let s = SlimlyStamp(bounds: geo.rawRect(rect), forType: .stamp, withProperties: nil)
            s.label = (o["label"] as? String) ?? ""; s.sub = (o["sub"] as? String) ?? ""
            s.tint = color(o, "color", "#D0342C")
            if let tok = o["src"] as? String, let u = images[tok] { s.imageURL = u }
            var meta: [String: Any] = ["label": s.label, "sub": s.sub, "color": (o["color"] as? String) ?? "#D0342C"]
            if s.imageURL != nil { meta["img"] = 1 }
            if let j = try? JSONSerialization.data(withJSONObject: meta), let js = String(data: j, encoding: .utf8) {
                // PDFKit 不寫 /NM：標記先放 /Subj，存檔時 MuPDF 搬到 /NM（slimly-mu.js 的 fixNames）
                s.setValue("slimly:stamp:" + js, forAnnotationKey: PDFAnnotationKey(rawValue: "/Subj"))
            }
            s.contents = note.isEmpty ? s.label : note
            a = s
        case "link":
            a = PDFAnnotation(bounds: geo.rawRect(rect), forType: .link, withProperties: nil)
            let br = PDFBorder(); br.lineWidth = 0; a.border = br
            if let u = o["url"] as? String, !u.isEmpty, let url = URL(string: u.contains(":") ? u : "https://" + u) { a.url = url }
            else if let pid = o["page"] as? String, let tp = pageOf(pid) {
                let g = PageGeo(tp)
                a.destination = PDFDestination(page: tp, at: g.raw(0, d(o, "py", 0)))
            } else { return nil }
            return a
        default:
            return nil
        }
        a.contents = note.isEmpty ? a.contents : note
        a.userName = author
        a.modificationDate = Date()
        return a
    }

    /// 書籤：畫面上的樹 → PDFKit 的 outline
    static func outline(_ items: [[String: Any]], pageOf: (String) -> PDFPage?) -> PDFOutline {
        let root = PDFOutline()
        func add(_ list: [[String: Any]], to parent: PDFOutline) {
            for it in list {
                let o = PDFOutline()
                o.label = (it["title"] as? String) ?? ""
                if let pid = it["page"] as? String, let p = pageOf(pid) {
                    let g = PageGeo(p)
                    o.destination = PDFDestination(page: p, at: g.raw(0, CGFloat((it["y"] as? Double) ?? 0)))
                }
                parent.insertChild(o, at: parent.numberOfChildren)
                add((it["kids"] as? [[String: Any]]) ?? [], to: o)
            }
        }
        add(items, to: root)
        return root
    }
}

// MARK: - 疊上去的內容：段落、打勾、頁首頁尾、背景

extension EditorDraw {
    /// 段落（新加的字、改過的原本的字）：畫面量好的每一行、每一段樣式的位置 → 一段一段畫（位置跟畫面一樣）
    static func para(_ ctx: CGContext, _ o: [String: Any], _ sz: CGSize) {
        if let cover = o["cover"] as? String, !cover.isEmpty, let rs = o["rects"] as? [[Double]] {   // 掃描的頁：原本那幾行蓋上紙色
            ctx.setFillColor(color(cover))
            for r in rs where r.count == 4 { ctx.fill(CGRect(x: r[0] - 1, y: Double(sz.height) - r[3] - 1, width: r[2] - r[0] + 2, height: r[3] - r[1] + 2)) }
        }
        if (o["vert"] as? Bool) == true { vpara(ctx, o, sz); return }                       // 直排
        var lines = (o["lines"] as? [[String: Any]]) ?? []
        if lines.isEmpty, let runs = o["runs"] as? [[String: Any]], let r0 = runs.first {
            // 畫面沒量（命令列、測試直接給字）：照第一段的樣式，一行一行由上往下排（行高＝字級 × lh，跟 CSS 的算法一樣置中）
            let text = runs.map { ($0["t"] as? String) ?? "" }.joined()
            let size = max(1, d(r0, "s", 12)), lh = size * d(o, "lh", 1.25)
            let f = FontMatch.ctFont((r0["f"] as? String) ?? "PingFang TC", weight: (r0["wt"] as? Int) ?? 400, italic: (r0["it"] as? Bool) ?? false, size: size)
            let A = CTFontGetAscent(f), D = CTFontGetDescent(f)
            for (i, t) in text.components(separatedBy: "\n").enumerated() {
                var seg = r0; seg["t"] = t; seg["x"] = Double(d(o, "x"))
                lines.append(["b": Double(d(o, "y") + CGFloat(i) * lh + (lh - (A + D)) / 2 + A), "segs": [seg]])
            }
        }
        let rot = d(o, "rot")
        if rot != 0 {
            // 轉向的原本的字（ro＝tl）繞框的左上角轉，跟畫面的 transform-origin: 0 0 一樣；其他的繞中心
            let tl = (o["ro"] as? String) == "tl"
            let cx = tl ? d(o, "x") : d(o, "x") + d(o, "w") / 2, cy = tl ? sz.height - d(o, "y") : sz.height - (d(o, "y") + d(o, "h") / 2)
            ctx.translateBy(x: cx, y: cy); ctx.rotate(by: -rot * .pi / 180); ctx.translateBy(x: -cx, y: -cy)
        }
        for l in lines {
            let base = sz.height - d(l, "b")
            var pen: CGFloat? = nil                                  // 這一行上一段畫到哪
            for s in (l["segs"] as? [[String: Any]]) ?? [] {
                let text = (s["t"] as? String) ?? ""
                guard !text.isEmpty else { continue }
                let size = max(1, d(s, "s", 12))
                let f = FontMatch.ctFont((s["f"] as? String) ?? "PingFang TC", weight: (s["wt"] as? Int) ?? 400, italic: (s["it"] as? Bool) ?? false, size: size)
                let c = color((s["c"] as? String) ?? "#1E2223")
                var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: c]))
                let want = d(s, "w"), just = (s["j"] as? Bool) == true
                var have = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                if just, want - have > 0.4, let jl = CTLineCreateJustifiedLine(line, 1.0, Double(want)) { line = jl; have = want }   // 只撐開、不擠（擠會讓字疊在一起）
                // 畫面量到的起點對齊整數像素：同一行接在上一段後面的，用上一段真的字寬接著畫（字距才均勻）
                var x = d(s, "x")
                if !just, let p = pen, abs(x - p) < max(2.5, size * 0.3) { x = p }
                ctx.textPosition = CGPoint(x: x, y: base)
                CTLineDraw(line, ctx)
                pen = x + have
                if (s["u"] as? Bool) == true {
                    let up = CTFontGetUnderlinePosition(f), th = max(0.5, CTFontGetUnderlineThickness(f))
                    ctx.setFillColor(c); ctx.fill(CGRect(x: x, y: base + up - th / 2, width: have, height: th))
                }
                if (s["k"] as? Bool) == true {                                                      // 刪除線
                    let th = max(0.5, CTFontGetUnderlineThickness(f)), xh = CTFontGetXHeight(f)
                    ctx.setFillColor(c); ctx.fill(CGRect(x: x, y: base + xh / 2 - th / 2, width: have, height: th))
                }
            }
        }
    }

    /// 全形標點 → Unicode 直排標點（U+FE10–FE19、U+FE30–FE44）：直排時正立畫就是對的樣子
    static let vertPunct: [Character: Character] = [
        "，": "︐", "、": "︑", "。": "︒", "：": "︓", "；": "︔", "！": "︕", "？": "︖", "〖": "︗", "〗": "︘", "…": "︙", "‥": "︰",
        "—": "︱", "–": "︲", "＿": "︳", "（": "︵", "）": "︶", "｛": "︷", "｝": "︸", "〔": "︹", "〕": "︺", "【": "︻", "】": "︼",
        "《": "︽", "》": "︾", "〈": "︿", "〉": "﹀", "「": "﹁", "」": "﹂", "『": "﹃", "』": "﹄"]

    /// 直排的段落：畫面量到每個字的框（正立，欄由右往左）→ 一個字一個字畫在框的正中間；
    /// 字一律正立（跟畫面的 text-orientation: upright 一樣），全形標點換成直排標點字元
    static func vpara(_ ctx: CGContext, _ o: [String: Any], _ sz: CGSize) {
        func n(_ v: Any?) -> CGFloat { CGFloat((v as? Double) ?? (v as? NSNumber)?.doubleValue ?? 0) }
        var chars = (o["vchars"] as? [[Any]]) ?? []
        if chars.isEmpty, let runs = o["runs"] as? [[String: Any]], let r0 = runs.first {
            // 畫面沒量（命令列、測試直接給字）：從框的右上角往下排，一欄寫到底或遇到換行就換左邊那欄
            let size = max(1, d(r0, "s", 12)), colW = size * d(o, "lh", 1.25), bottom = d(o, "y") + max(d(o, "h"), size)
            var cx = d(o, "x") + d(o, "w") - colW / 2, y = d(o, "y")
            for ch in runs.map({ ($0["t"] as? String) ?? "" }).joined() {
                if ch == "\n" || y + size > bottom + 0.5 { cx -= colW; y = d(o, "y"); if ch == "\n" { continue } }
                chars.append([String(ch), Double(cx - size / 2), Double(y), Double(cx + size / 2), Double(y + size),
                              (r0["f"] as? String) ?? "PingFang TC", (r0["wt"] as? Int) ?? 400, (r0["it"] as? Bool) ?? false, Double(size), (r0["c"] as? String) ?? "#1E2223", false, false])
                y += size
            }
        }
        let rot = d(o, "rot")
        if rot != 0 {                                                                         // 跟著整頁轉過：繞中心轉（同橫排的段落）
            let cx = d(o, "x") + d(o, "w") / 2, cy = sz.height - (d(o, "y") + d(o, "h") / 2)
            ctx.translateBy(x: cx, y: cy); ctx.rotate(by: -rot * .pi / 180); ctx.translateBy(x: -cx, y: -cy)
        }
        for c in chars where c.count >= 10 {
            guard let s = c[0] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let x0 = n(c[1]), y0 = n(c[2]), x1 = n(c[3]), y1 = n(c[4]), size = max(1, n(c[8]))
            let wt = Int(n(c[6]) == 0 ? 400 : n(c[6])), it = (c[7] as? Bool) ?? false
            let f = FontMatch.ctFont((c[5] as? String) ?? "PingFang TC", weight: wt, italic: it, size: size)
            let col = color((c[9] as? String) ?? "#1E2223")
            // 字一律正立畫；全形標點換成 Unicode 的直排標點（，→︐、。→︒、：→︓、「→﹁…），跟畫面上 vertical-rl 的直排字形同一個樣子。
            // 不用 CoreText 的直排字形（kCTVerticalFormsAttributeName）：它要畫布轉 90°，而且換出來的標點字形沒有 Unicode 對應，
            // 存出來再讀變成「�」（實測）；直排標點字元讀回來還是標點（搜尋照 NFKD 比對，找得到）
            let t = String(s.map { EditorDraw.vertPunct[$0] ?? $0 })
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: col]))
            var A: CGFloat = 0, D: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &A, &D, nil))
            let cx = (x0 + x1) / 2, cy = sz.height - (y0 + y1) / 2                          // 字框的中心（PDF 座標，y 往上）
            ctx.textPosition = CGPoint(x: cx - w / 2, y: cy - (A - D) / 2)
            CTLineDraw(line, ctx)
            if c.count >= 12, (c[10] as? Bool) == true {                                      // 直排的底線畫在字的右邊
                let th = max(0.5, CTFontGetUnderlineThickness(f)); ctx.setFillColor(col); ctx.fill(CGRect(x: x1 - th, y: sz.height - y1, width: th, height: y1 - y0))
            }
            if c.count >= 12, (c[11] as? Bool) == true {                                      // 刪除線：從字中間直直穿過
                let th = max(0.5, CTFontGetUnderlineThickness(f)); ctx.setFillColor(col); ctx.fill(CGRect(x: cx - th / 2, y: sz.height - y1, width: th, height: y1 - y0))
            }
        }
    }

    /// 填寫與簽名的符號：打勾、打叉、圓點、橫線
    static func mark(_ ctx: CGContext, _ o: [String: Any], _ sz: CGSize) {
        let r = CGRect(x: d(o, "x"), y: sz.height - d(o, "y") - d(o, "h"), width: d(o, "w"), height: d(o, "h"))
        let c = color((o["color"] as? String) ?? "#1E2223")
        ctx.setStrokeColor(c); ctx.setFillColor(c); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let lw = max(0.8, min(r.width, r.height) * 0.12)
        ctx.setLineWidth(lw)
        switch (o["k"] as? String) ?? "check" {
        case "cross":
            let i = r.insetBy(dx: r.width * 0.18, dy: r.height * 0.18)
            ctx.move(to: CGPoint(x: i.minX, y: i.minY)); ctx.addLine(to: CGPoint(x: i.maxX, y: i.maxY))
            ctx.move(to: CGPoint(x: i.minX, y: i.maxY)); ctx.addLine(to: CGPoint(x: i.maxX, y: i.minY)); ctx.strokePath()
        case "dot":
            ctx.fillEllipse(in: r.insetBy(dx: r.width * 0.25, dy: r.height * 0.25))
        case "line":
            ctx.setLineWidth(max(0.8, d(o, "lw", 1.2)))
            ctx.move(to: CGPoint(x: r.minX, y: r.midY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.midY)); ctx.strokePath()
        default:
            ctx.move(to: CGPoint(x: r.minX + r.width * 0.14, y: r.minY + r.height * 0.5))
            ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.4, y: r.minY + r.height * 0.2))
            ctx.addLine(to: CGPoint(x: r.maxX - r.width * 0.12, y: r.maxY - r.height * 0.16)); ctx.strokePath()
        }
    }

    /// 頁首頁尾（六個位置、代號 <<n>> <<N>> <<date>> <<file>> <<bates>>）
    static func headerFooter(_ ctx: CGContext, _ sz: CGSize, n: Int, total: Int, file: String, _ hf: [String: Any]) {
        let from = max(1, (hf["from"] as? Int) ?? 1)
        guard n >= from else { return }
        let start = (hf["start"] as? Int) ?? 1, k = start + (n - from), all = start + (total - from)
        let size = max(4, d(hf, "size", 10)), c = color((hf["color"] as? String) ?? "#262626")
        let mt = d(hf, "mt", 28), mb = d(hf, "mb", 28), ml = d(hf, "ml", 36), mr = d(hf, "mr", 36)
        let date = { () -> String in let f = DateFormatter(); f.dateFormat = (hf["dfmt"] as? String) ?? "yyyy/MM/dd"; return f.string(from: Date()) }()
        let bp = (hf["bprefix"] as? String) ?? "", bs = (hf["bsuffix"] as? String) ?? "", bd = max(1, (hf["bdigits"] as? Int) ?? 6), bstart = (hf["bstart"] as? Int) ?? 1
        let bates = bp + String(format: "%0\(bd)d", bstart + (n - from)) + bs
        func fill(_ s: String) -> String {
            s.replacingOccurrences(of: "<<n>>", with: "\(k)").replacingOccurrences(of: "<<N>>", with: "\(all)").replacingOccurrences(of: "<<date>>", with: date)
             .replacingOccurrences(of: "<<file>>", with: file).replacingOccurrences(of: "<<bates>>", with: bates)
        }
        let f = FontMatch.ctFont((hf["font"] as? String) ?? "PingFang TC", weight: 400, italic: false, size: size)
        for (key, h, v) in [("tl", -1, 1), ("tc", 0, 1), ("tr", 1, 1), ("bl", -1, -1), ("bc", 0, -1), ("br", 1, -1)] {
            guard let raw = hf[key] as? String, !raw.isEmpty else { continue }
            let s = fill(raw)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c]))
            var a: CGFloat = 0, dd: CGFloat = 0, g: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &a, &dd, &g))
            let x = h < 0 ? ml : h == 0 ? (sz.width - w) / 2 : sz.width - mr - w
            let y = v > 0 ? sz.height - mt - a : mb + dd
            ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
        }
    }

    /// 背景：整頁一個顏色（畫在原本內容的下面）
    static func background(_ ctx: CGContext, _ sz: CGSize, _ bg: [String: Any]) {
        ctx.setFillColor(color((bg["color"] as? String) ?? "#FFFFFF", alpha: CGFloat((bg["opacity"] as? Double) ?? 1)))
        ctx.fill(CGRect(origin: .zero, size: sz))
    }

    /// 圖片浮水印：置中、照比例、半透明
    static func imageWatermark(_ ctx: CGContext, _ sz: CGSize, _ wm: [String: Any], images: [String: URL]) {
        guard let tok = wm["src"] as? String, let u = images[tok], let img = Convert.loadAnyImage(u) else { return }
        let scale = CGFloat((wm["scale"] as? Double) ?? 0.5)
        let w0 = CGFloat(img.width), h0 = CGFloat(img.height)
        let k = min(sz.width * scale / max(1, w0), sz.height * scale / max(1, h0))
        let w = w0 * k, h = h0 * k
        ctx.saveGState()
        ctx.setAlpha(CGFloat((wm["opacity"] as? Double) ?? 0.2))
        ctx.translateBy(x: sz.width / 2, y: sz.height / 2)
        ctx.rotate(by: CGFloat((wm["angle"] as? Double) ?? 0) * .pi / 180)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }
}
