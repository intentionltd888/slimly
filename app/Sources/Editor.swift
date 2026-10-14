// Editor.swift — PDF 編輯器（2.1）：一份 PDF 一個視窗，像 Acrobat／預覽程式
//
// 畫面（editor.html）管看跟改；這個檔管：
//   開檔（有密碼先問、打不開先修）→ 頁面（排序、轉向、刪、插、複製、裁白邊、辨識文字；一律可以復原）
//   → 畫頁面的圖（自訂網址 slimly://page/…，捲到哪畫到哪）→ 讀字（改原本的字、找個資）
//   → 存檔：照畫面把字、圖、簽名、標註疊上去；有塗黑或改過原本文字的頁，換成 300 dpi 的圖＋原本的字（看不見的字層），舊字才真的消失。
// 原檔永遠不動：第一次存＝另存一份「（已編輯）」，同一個視窗之後再存就更新那一份。
import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers
import WebKit

// MARK: - 編輯中的文件（所有 PDFKit 的讀寫都在 q 上，一次一件）

final class EditorDoc {
    struct Page { let page: PDFPage; let id: String; var v: Int }
    struct Snap { let page: PDFPage; let id: String; let v: Int; let rotation: Int; let crop: CGRect }
    enum OpenResult { case ok, locked, restricted, damaged }

    let original: URL
    let work: URL
    private(set) var doc = PDFDocument()
    private(set) var pages: [Page] = []
    private var undoStack: [[Snap]] = [], redoStack: [[Snap]] = []
    var password: String?                 // 打開時輸入的密碼（存檔時可以照原本的鎖回去）
    var output: URL?                      // 這個視窗第一次存出來的那一份；之後再存就更新它
    // 目前這份是從哪個檔讀進來的（原檔、修好的副本或上次存出來的）：PDFKit 存檔會丟掉的附件、JavaScript、頁碼標籤…存檔時從這裡補回去
    private(set) var source: URL
    private var sourcePassword: String?
    private var sourcePages: [PDFPage] = []
    private(set) var sourceKeeps = false
    private var coverCache: [Int: Double]?    // 來源檔第幾頁被圖蓋住多少（掃描頁判斷用）
    var images: [String: URL] = [:]       // 畫面上用到的圖：代號 → 檔案（只給畫面讀這些，不讓它讀任意路徑）
    var files: [String: URL] = [:]        // 這次附加的檔（附加檔案註解）：代號 → 檔案
    private var metaCache: [[[String: Any]]]?   // MuPDF 讀的來源檔每頁註解資訊（回覆誰、附加檔案）：一份檔讀一次
    let q = DispatchQueue(label: "ltd.intention.slimly.editor", qos: .userInitiated)
    var textCache: [String: [String: Any]] = [:]   // MuPDF 讀的字（頁代號＋版本）
    private var seq = 0

    init(_ url: URL) {
        original = url; source = url
        work = FileManager.default.temporaryDirectory.appendingPathComponent("Slimly-Edit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    var closed = false                    // 視窗關了：背景的工作不要再往工作夾寫東西（不然收不乾淨）
    func cleanup() { closed = true; try? FileManager.default.removeItem(at: work) }
    private func newId() -> String { seq += 1; return "p\(seq)" }

    func open(password pw: String? = nil) -> OpenResult {
        guard let d = PDFDocument(url: original), d.pageCount > 0 else { return .damaged }
        if d.isLocked {
            guard let pw, !pw.isEmpty, d.unlock(withPassword: pw) else { return .locked }
            password = pw
        }
        // 作者設了限制（列印、拷貝、修改）：要用擁有者密碼打開才能改（存檔會重寫整份，限制會不見）
        if PDFs.restricted(d) {
            guard let pw, !pw.isEmpty, d.unlock(withPassword: pw), !PDFs.restricted(d) else { return .restricted }
            password = pw
        }
        // 有加密的：編輯用一份沒有加密的副本（PDFKit 存檔會把加密原樣帶回去）
        load(d.isEncrypted ? PDFs.rebuild(d) : d, from: original, password: pw)
        return .ok
    }
    func load(_ d: PDFDocument, from u: URL? = nil, password pw: String? = nil) {
        doc = d
        textCache = [:]
        pages = (0..<d.pageCount).compactMap { d.page(at: $0) }.map { Page(page: $0, id: newId(), v: 0) }
        undoStack = []; redoStack = []
        if let u { source = u; sourcePassword = (pw?.isEmpty ?? true) ? nil : pw; sourceKeeps = Self.catalogKeeps(u, password: sourcePassword) }
        sourcePages = pages.map(\.page); coverCache = nil; metaCache = nil
    }
    /// 這一頁在來源檔是第幾頁（插入、新加的頁：nil）
    func sourceIndex(_ id: String) -> Int? { guard let p = page(id) else { return nil }; return sourcePages.firstIndex { $0 === p } }
    var sourceStdin: String? { sourcePassword.map { "\($0)\n" } }
    /// 來源檔第 j 頁的註解（照 /Annots 的順序）：種類、/NM、回覆第幾個、附加檔案（PDFKit 讀不到 /IRT）
    func annMeta(_ j: Int) -> [[String: Any]] {
        if metaCache == nil {
            let r = try? MuTool.run(["annmeta", source.path], timeout: 60, stdin: sourceStdin)
            metaCache = (r?["pages"] as? [[[String: Any]]]) ?? []
        }
        guard let m = metaCache, j >= 0, j < m.count else { return [] }
        return m[j]
    }
    /// 這個檔的目錄裡有沒有 PDFKit 存檔會丟、但要留著的東西
    static func catalogKeeps(_ u: URL, password: String?) -> Bool {
        guard let d = CGPDFDocument(u as CFURL) else { return false }
        if d.isEncrypted, !d.isUnlocked { guard let pw = password, d.unlockWithPassword(pw) else { return false } }
        guard let cat = d.catalog else { return false }
        var names: CGPDFDictionaryRef?, sub: CGPDFDictionaryRef?, obj: CGPDFObjectRef?
        if CGPDFDictionaryGetDictionary(cat, "Names", &names), let n = names,
           CGPDFDictionaryGetDictionary(n, "EmbeddedFiles", &sub) || CGPDFDictionaryGetDictionary(n, "JavaScript", &sub) { return true }
        for k in ["AF", "OpenAction", "PageLabels", "Lang"] where CGPDFDictionaryGetObject(cat, k, &obj) { return true }
        return false
    }
    func page(_ id: String) -> PDFPage? { pages.first { $0.id == id }?.page }
    func index(_ id: String) -> Int? { pages.firstIndex { $0.id == id } }

    /// 給畫面的頁清單：代號、顯示大小（含旋轉）、版本（轉了、裁了、換了就 +1，畫面才會重抓圖）
    func list() -> [[String: Any]] {
        pages.map { p in
            let s = Overlay.displaySize(p.page)
            return ["id": p.id, "w": Double(s.width), "h": Double(s.height), "v": p.v, "rot": p.page.rotation]
        }
    }
    /// 沒有字的頁（掃描的）：給「辨識文字」提示用
    /// 掃描的頁：幾乎沒有字，而且被圖蓋住一半以上（空白頁、封面、放一張小照片的頁不算；不然提示會叫人去辨識一頁本來就有字或根本沒字的頁）
    func scannedIds() -> [String] {
        let cand = pages.filter { !OCR.hasText($0.page) }
        guard !cand.isEmpty else { return [] }
        let idx = cand.compactMap { c in sourcePages.firstIndex { $0 === c.page } }
        if coverCache == nil, !idx.isEmpty {
            let j = try? MuTool.run(["scan", source.path, idx.map(String.init).joined(separator: ",")], timeout: 60, stdin: sourcePassword.map { "\($0)\n" })
            var m: [Int: Double] = [:]
            for (k, v) in (j?["cover"] as? [String: Any]) ?? [:] { if let i = Int(k), let d = (v as? NSNumber)?.doubleValue { m[i] = d } }
            coverCache = m
        }
        return cand.filter { c in
            guard let i = sourcePages.firstIndex(where: { $0 === c.page }), let cov = coverCache?[i] else { return true }   // 不是從來源檔來的頁：照舊（沒字＝掃描的）
            return cov >= 0.5
        }.map(\.id)
    }

    // MARK: 頁面操作（每一次都先存一張快照，復原就是換回快照）

    private func snap() -> [Snap] {
        pages.map { Snap(page: $0.page, id: $0.id, v: $0.v, rotation: $0.page.rotation, crop: $0.page.bounds(for: .cropBox)) }
    }
    private func restore(_ s: [Snap]) {
        while doc.pageCount > 0 { doc.removePage(at: doc.pageCount - 1) }
        pages = []
        for (i, x) in s.enumerated() {
            doc.insert(x.page, at: i)
            x.page.rotation = x.rotation
            x.page.setBounds(x.crop, for: .cropBox)
            pages.append(Page(page: x.page, id: x.id, v: x.v))
        }
    }
    private func setOrder(_ order: [Page]) {
        while doc.pageCount > 0 { doc.removePage(at: doc.pageCount - 1) }
        for (i, p) in order.enumerated() { doc.insert(p.page, at: i) }
        pages = order
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    func undo() { guard let s = undoStack.popLast() else { return }; redoStack.append(snap()); restore(s) }
    func redo() { guard let s = redoStack.popLast() else { return }; undoStack.append(snap()); restore(s) }

    /// 做一個頁面操作；回傳新加的頁（畫面要選到它們）
    @discardableResult
    func apply(_ op: String, _ a: [String: Any]) throws -> [String] { try applyEx(op, a).added }
    struct OpResult { var added: [String] = []; var shift: [String: [Double]] = [:] }
    func applyEx(_ op: String, _ a: [String: Any]) throws -> OpResult {
        let ids = (a["ids"] as? [String]) ?? []
        let before = snap()
        var added: [String] = []
        var shift: [String: [Double]] = [:]
        let at = (a["after"] as? String).flatMap { index($0) }.map { $0 + 1 } ?? pages.count
        switch op {
        case "rotate":
            let by = (a["by"] as? Int) ?? 90
            for i in pages.indices where ids.contains(pages[i].id) {
                pages[i].page.rotation = ((pages[i].page.rotation + by) % 360 + 360) % 360
                pages[i].v += 1
            }
        case "delete":
            let keep = pages.filter { !ids.contains($0.id) }
            guard !keep.isEmpty else { throw ToolError.msg(L("至少要留一頁", "Keep at least one page")) }
            setOrder(keep)
        case "move":
            let moving = pages.filter { ids.contains($0.id) }
            var rest = pages.filter { !ids.contains($0.id) }
            let to = max(0, min(rest.count, (a["to"] as? Int) ?? rest.count))
            rest.insert(contentsOf: moving, at: to)
            setOrder(rest)
        case "dup":
            var order = pages
            for id in ids.reversed() {
                guard let i = order.firstIndex(where: { $0.id == id }), let c = order[i].page.copy() as? PDFPage else { continue }
                let n = Page(page: c, id: newId(), v: 0)
                order.insert(n, at: i + 1); added.append(n.id)
            }
            setOrder(order)
        case "blank":
            let ref = at > 0 ? pages[at - 1].page : pages.first?.page
            let size = ref.map { Overlay.displaySize($0) } ?? CGSize(width: 595.28, height: 841.89)
            let p = PDFPage()
            p.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
            p.setBounds(CGRect(origin: .zero, size: size), for: .cropBox)
            let n = Page(page: p, id: newId(), v: 0)
            var order = pages; order.insert(n, at: at); setOrder(order); added = [n.id]
        case "insertFiles":
            let urls = ((a["paths"] as? [String]) ?? []).map { URL(fileURLWithPath: $0) }
            var order = pages, pos = at
            for u in urls {
                let src: PDFDocument
                if u.pathExtension.lowercased() == "pdf" {
                    guard let d = PDFDocument(url: u), d.pageCount > 0 else { throw ToolError.msg(L("「\(u.lastPathComponent)」打不開", "Couldn’t open “\(u.lastPathComponent)”")) }
                    guard !d.isLocked else { throw ToolError.msg(L("「\(u.lastPathComponent)」有密碼：先用編輯器打開它、存一份沒密碼的", "“\(u.lastPathComponent)” is password-protected")) }
                    guard !PDFs.restricted(d) else { throw ToolError.msg(PDFs.restrictedMsg(u)) }
                    src = d
                } else {
                    guard let d = EditorDoc.imagePages([u]) else { throw ToolError.msg(L("「\(u.lastPathComponent)」讀不出來", "Couldn’t read “\(u.lastPathComponent)”")) }
                    src = d
                }
                for i in 0..<src.pageCount {
                    guard let c = src.page(at: i)?.copy() as? PDFPage else { continue }
                    let n = Page(page: c, id: newId(), v: 0)
                    order.insert(n, at: pos); pos += 1; added.append(n.id)
                }
            }
            setOrder(order)
        case "crop" where a["rect"] is [Double]:
            // 裁切工具：在參考頁上框的範圍 → 四邊的邊界，套到每一頁（Acrobat 的「裁切頁面」）
            guard let rr = a["rect"] as? [Double], rr.count == 4, let refP = (a["ref"] as? String).flatMap({ page($0) }) else { break }
            let rs = Overlay.displaySize(refP)
            let ml = CGFloat(rr[0]), mt = CGFloat(rr[1]), mr = rs.width - CGFloat(rr[0] + rr[2]), mb = rs.height - CGFloat(rr[1] + rr[3])
            var changed = 0
            for i in pages.indices where ids.contains(pages[i].id) {
                let p = pages[i].page, geo = PageGeo(p), sz = geo.size
                let d = CGRect(x: max(0, ml), y: max(0, mt), width: sz.width - max(0, ml) - max(0, mr), height: sz.height - max(0, mt) - max(0, mb))
                guard d.width > 18, d.height > 18 else { continue }
                let box = geo.rawRect(d).intersection(p.bounds(for: .mediaBox))
                guard box.width > 18, box.height > 18 else { continue }
                p.setBounds(box, for: .cropBox)
                shift[pages[i].id] = [Double(d.minX), Double(d.minY)]
                pages[i].v += 1; changed += 1
            }
            guard changed > 0 else { throw ToolError.msg(L("框的範圍太小", "The area is too small")) }
        case "crop":
            let mm = 72.0 / 25.4
            var changed = 0
            for i in pages.indices where ids.contains(pages[i].id) {
                let p = pages[i].page, media = p.bounds(for: .mediaBox)
                guard let content = PageTools.contentBounds(p) else { continue }
                let box = content.insetBy(dx: -CGFloat(4 * mm), dy: -CGFloat(4 * mm)).intersection(media)
                guard box.width > 36, box.height > 36, box != p.bounds(for: .cropBox) else { continue }
                // 裁掉之後畫面上的東西要跟著移：同一個點在舊、新顯示座標（左上原點）的差
                let pt = CGPoint(x: box.midX, y: box.midY), oldH = Overlay.displaySize(p).height
                let o1 = Overlay.mapPoint(pt, p)
                p.setBounds(box, for: .cropBox)
                let o2 = Overlay.mapPoint(pt, p), newH = Overlay.displaySize(p).height
                shift[pages[i].id] = [Double(o1.x - o2.x), Double((oldH - o1.y) - (newH - o2.y))]
                pages[i].v += 1; changed += 1
            }
            guard changed > 0 else { throw ToolError.msg(L("找不到可以裁的白邊", "No margins to crop")) }
        case "replace":
            // 辨識文字做好的頁換進來（同一個代號，畫面上的東西位置不變）
            guard let m = a["pages"] as? [String: PDFPage] else { break }
            var order = pages
            for i in order.indices { if let np = m[order[i].id] { order[i] = Page(page: np, id: order[i].id, v: order[i].v + 1) } }
            setOrder(order)
        default:
            throw ToolError.msg(L("不認得的頁面操作：\(op)", "Unknown page operation: \(op)"))
        }
        undoStack.append(before); redoStack = []
        if undoStack.count > 60 { undoStack.removeFirst() }
        return OpResult(added: added, shift: shift)
    }

    /// 圖片做成頁（照片塞進 A4、直橫照圖）
    static func imagePages(_ urls: [URL]) -> PDFDocument? {
        let data = NSMutableData()
        var mb = CGRect.zero
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &mb, nil) else { return nil }
        var n = 0
        for u in urls {
            guard let (img, px) = Convert.loadImage(u) else { continue }
            var page = CGSize(width: 595.28, height: 841.89)
            if px.width > px.height { page = CGSize(width: page.height, height: page.width) }
            var r = CGRect(origin: .zero, size: page)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &r, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            let k = min(page.width / px.width, page.height / px.height, 1)
            let w = px.width * k, h = px.height * k
            ctx.draw(img, in: CGRect(x: (page.width - w) / 2, y: (page.height - h) / 2, width: w, height: h))
            ctx.endPDFPage(); n += 1
        }
        ctx.closePDF()
        return n > 0 ? PDFDocument(data: data as Data) : nil
    }

    // MARK: 畫頁面的圖（表單欄位不畫：畫面上有自己的輸入框）

    func render(_ id: String, width: CGFloat, annots: Bool = false) -> Data? {
        guard let p = page(id) else { return nil }
        return EditorDoc.renderPage(p, width: width, annots: annots)
    }
    /// 畫一頁：註解不畫（畫面上每個註解是自己的物件，可以選、搬、改）；表單欄位也不畫（畫面上有輸入框）。縮圖（annots）照原樣全畫
    static func renderPage(_ p: PDFPage, width: CGFloat, annots: Bool = false) -> Data? {
        let sz = Overlay.displaySize(p)
        let scale = min(max(width, 40), 4000) / max(1, sz.width)
        let W = max(1, Int((sz.width * scale).rounded())), H = max(1, Int((sz.height * scale).rounded()))
        let hide = annots ? [] : p.annotations.filter { $0.type != "Link" }
        let was = hide.map(\.shouldDisplay)
        hide.forEach { $0.shouldDisplay = false }
        defer { zip(hide, was).forEach { $0.shouldDisplay = $1 } }
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        p.draw(with: .cropBox, to: ctx)
        guard let img = ctx.makeImage() else { return nil }
        return Raster.encode(img, quality: 0.86)
    }

    /// 一頁畫成點陣（存檔時塗黑、改字的頁用）；座標＝顯示方向的點、原點左下
    static func raster(_ p: PDFPage, dpi: CGFloat, fills: [(CGRect, CGColor)]) -> CGImage? {
        let sz = Overlay.displaySize(p), k = dpi / 72
        let W = Int((sz.width * k).rounded()), H = Int((sz.height * k).rounded())
        guard W > 0, H > 0, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: k, y: k)
        p.draw(with: .cropBox, to: ctx)
        for (r, c) in fills { ctx.setFillColor(c); ctx.fill(r) }
        return ctx.makeImage()
    }

    // MARK: 顏色、底色（掃描的頁改字時蓋的紙色）

    static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "#1E2223" }
        return String(format: "#%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }
    /// 一行字旁邊最常見的顏色（紙的顏色）：沿著框外一圈取樣
    static func background(_ img: CGImage, _ r: CGRect, _ sz: CGSize) -> String {
        guard let data = img.dataProvider?.data, let px = CFDataGetBytePtr(data) else { return "#FFFFFF" }
        let W = img.width, H = img.height, bpr = img.bytesPerRow
        let kx = CGFloat(W) / sz.width, ky = CGFloat(H) / sz.height
        var counts: [Int: Int] = [:]
        func sample(_ x: CGFloat, _ y: CGFloat) {
            let ix = Int(x * kx), iy = Int((sz.height - y) * ky)          // 點陣第 0 列在上面
            guard ix >= 0, iy >= 0, ix < W, iy < H else { return }
            let o = iy * bpr + ix * 4
            let key = (Int(px[o]) / 8) << 10 | (Int(px[o + 1]) / 8) << 5 | (Int(px[o + 2]) / 8)
            counts[key, default: 0] += 1
        }
        let e = r.insetBy(dx: -2, dy: -2)
        for i in 0...20 {
            let t = CGFloat(i) / 20
            sample(e.minX + t * e.width, e.minY); sample(e.minX + t * e.width, e.maxY)
            sample(e.minX, e.minY + t * e.height); sample(e.maxX, e.minY + t * e.height)
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return "#FFFFFF" }
        let rr = ((best >> 10) & 31) * 8 + 4, gg = ((best >> 5) & 31) * 8 + 4, bb = (best & 31) * 8 + 4
        if rr > 240 && gg > 240 && bb > 240 { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", min(255, rr), min(255, gg), min(255, bb))
    }

    // MARK: 表單欄位（畫面上放輸入框）

    func fields() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for p in pages {
            let sz = Overlay.displaySize(p.page)
            for (ai, a) in p.page.annotations.enumerated() where a.type == "Widget" {
                guard let name = a.fieldName else { continue }
                let r = Overlay.map(a.bounds, p.page)
                var f: [String: Any] = ["page": p.id, "ai": ai, "name": name, "x": Double(r.minX), "y": Double(sz.height - r.maxY), "w": Double(r.width), "h": Double(r.height)]
                if a.widgetFieldType == .signature { f["type"] = "sig"; out.append(f); continue }
                switch a.widgetFieldType {
                case .text: f["type"] = "text"; f["value"] = a.widgetStringValue ?? ""; f["multi"] = a.isMultiline
                case .choice: f["type"] = "choice"; f["value"] = a.widgetStringValue ?? ""; f["choices"] = a.choices ?? []
                case .button:
                    if a.widgetControlType == .checkBoxControl { f["type"] = "check"; f["value"] = a.buttonWidgetState == .onState }
                    else if a.widgetControlType == .radioButtonControl { f["type"] = "radio"; f["option"] = a.buttonWidgetStateString; f["value"] = a.buttonWidgetState == .onState }
                    else { continue }
                default: continue
                }
                out.append(f)
            }
        }
        return out
    }
    func fill(_ values: [String: Any]) {
        guard !values.isEmpty else { return }
        for p in pages {
            for a in p.page.annotations where a.type == "Widget" {
                guard let n = a.fieldName, let v = values[n] else { continue }
                let s = (v as? String) ?? (v as? NSNumber)?.stringValue ?? "\(v)"
                switch a.widgetFieldType {
                case .text, .choice: if a.widgetStringValue != s { a.widgetStringValue = s }
                case .button:
                    if a.widgetControlType == .checkBoxControl { a.buttonWidgetState = ((v as? Bool) ?? (s == "true" || s == "1")) ? .onState : .offState }
                    // 選項按鈕不在這裡設：PDFKit 會把群組的值寫成空的名字（選的就不見了），存檔時交給 MuPDF（compose 的 radios）
                default: break
                }
            }
        }
    }

    // MARK: 尋找（⌘F）：每頁的字先修部首（蘋方的⾏→行），找到的位置照行回報

    /// matchCase＝大小寫相符；wholeWord＝全字相符（英文字母、數字前後不能連著別的英文字母或數字；中文、假名每個字都算一個字，不擋）
    func search(_ q: String, matchCase: Bool = false, wholeWord: Bool = false) -> [[String: Any]] {
        let needle = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var opts: NSString.CompareOptions = [.diacriticInsensitive, .widthInsensitive]
        if !matchCase { opts.insert(.caseInsensitive) }
        var out: [[String: Any]] = []
        Quiet.stderr {
            for p in pages {
                let s = PDFs.text(p.page) as NSString
                guard s.length > 0 else { continue }
                let geo = PageGeo(p.page)
                var rects: [[String: Double]] = []
                var r = NSRange(location: 0, length: s.length)
                while true {
                    let m = s.range(of: needle, options: opts, range: r)
                    guard m.location != NSNotFound, m.length > 0 else { break }
                    if wholeWord && !Self.wholeWord(s, m) { r = NSRange(location: m.location + 1, length: s.length - m.location - 1); continue }
                    if let sel = p.page.selection(for: m) {
                        for l in sel.selectionsByLine() {
                            let b = geo.dispRect(l.bounds(for: p.page))
                            if b.width > 0 && b.height > 0 { rects.append(["x": Double(b.minX), "y": Double(b.minY), "w": Double(b.width), "h": Double(b.height)]) }
                        }
                    }
                    r = NSRange(location: m.location + m.length, length: s.length - m.location - m.length)
                    if rects.count > 2000 { break }
                }
                if !rects.isEmpty { out.append(["id": p.id, "rects": rects]) }
            }
        }
        return out
    }

    static func isWordChar(_ c: Character?) -> Bool {
        guard let c = c, let u = c.unicodeScalars.first else { return false }
        if u.properties.isIdeographic || (0x3040...0x30FF).contains(u.value) || (0x31F0...0x31FF).contains(u.value) || (0xFF66...0xFF9F).contains(u.value) { return false }
        return c.isLetter || c.isNumber || c == "_"
    }
    static func wholeWord(_ s: NSString, _ m: NSRange) -> Bool {
        let w = s.substring(with: m), end = m.location + m.length
        let prev: Character? = m.location > 0 ? s.substring(with: s.rangeOfComposedCharacterSequence(at: m.location - 1)).first : nil
        let next: Character? = end < s.length ? s.substring(with: s.rangeOfComposedCharacterSequence(at: end)).first : nil
        return !(isWordChar(prev) && isWordChar(w.first)) && !(isWordChar(next) && isWordChar(w.last))
    }

    // MARK: 找個資（塗黑用）：電話、Email、身分證字號、信用卡號、自己打的字

    func find(presets: [String], terms: [String]) -> [[String: Any]] {
        var regs: [NSRegularExpression] = presets.compactMap { Redact.presets[$0].flatMap { try? NSRegularExpression(pattern: $0.0) } }
        for t in terms where !t.isEmpty { if let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: t)) { regs.append(re) } }
        var out: [[String: Any]] = []
        Quiet.stderr {
            for p in pages {
                let s = PDFs.text(p.page) as NSString
                guard s.length > 0 else { continue }
                let sz = Overlay.displaySize(p.page)
                var rects: [[String: Double]] = []
                for re in regs {
                    for m in re.matches(in: s as String, range: NSRange(location: 0, length: s.length)) {
                        guard let sel = p.page.selection(for: m.range) else { continue }
                        for l in sel.selectionsByLine() {
                            let r = Overlay.map(l.bounds(for: p.page), p.page).insetBy(dx: -1.5, dy: -1.5)
                            guard r.width > 0, r.height > 0 else { continue }
                            rects.append(["x": Double(r.minX), "y": Double(sz.height - r.maxY), "w": Double(r.width), "h": Double(r.height)])
                        }
                    }
                }
                if !rects.isEmpty { out.append(["id": p.id, "rects": rects]) }
            }
        }
        return out
    }

    // MARK: 存檔（2.2）：原頁不動，改的地方交給 MuPDF 真的改；新加的東西疊一層；註解存成真的註解

    /// spec：pages＝[{id, objs:[…], gone:[既有註解序號]}]、forms、pn、hf、wm、bg、outline、meta、sanitize、perms。座標＝顯示方向的點、原點左上
    /// ownerPassword：限制列印／拷貝／修改時的擁有者密碼（只在 app 裡打）
    func compose(_ spec: [String: Any], to out: URL, password: String?, ownerPassword: String? = nil, progress: ((Double) -> Void)? = nil) throws {
        let forms = (spec["forms"] as? [String: Any]) ?? [:]
        fill(forms)
        var radios: [String: String] = [:]                  // 選項按鈕選了哪一個（MuPDF 設）
        for p in pages { for a in p.page.annotations where a.type == "Widget" && a.widgetControlType == .radioButtonControl { if let n = a.fieldName, let v = forms[n] as? String { radios[n] = v } } }
        var pspec: [String: [String: Any]] = [:]
        for x in (spec["pages"] as? [[String: Any]]) ?? [] { if let id = x["id"] as? String { pspec[id] = x } }
        let pn = spec["pn"] as? [String: Any], wm = spec["wm"] as? [String: Any], hf = spec["hf"] as? [String: Any], bg = spec["bg"] as? [String: Any]
        let pnFrom = max(1, (pn?["from"] as? Int) ?? 1)
        progress?(0.05)
        // E1：存出來的檔由 MuPDF 從來源檔（原檔、修好的副本或上次存的）直接改，不再整份經過 PDFKit 寫一次。
        // 每一頁從哪來：來源檔第 s 頁（帶旋轉、裁切），或 PDFKit 那份的第 d 頁（新加的空白頁、插入的檔、再製、辨識後換掉的頁）
        var pagemap: [[String: Any]] = [], foreign = false
        for (i, p) in pages.enumerated() {
            if let j = sourcePages.firstIndex(where: { $0 === p.page }) {
                let cb = p.page.bounds(for: .cropBox)
                pagemap.append(["s": j, "rot": p.page.rotation, "crop": [Double(cb.minX), Double(cb.minY), Double(cb.maxX), Double(cb.maxY)]])
            } else { pagemap.append(["d": i]); foreign = true }
        }
        // 註解的變動（只對來源檔的頁）：刪掉的、改過的（新的那個從 PDFKit 那份搬）用「種類＋位置」對到原檔那一個；既有的表單欄位、不認得的註解只搬位置
        var annops: [[String: Any]] = [], adds = false
        for (i, p) in pages.enumerated() where pagemap[i]["s"] != nil {
            guard let s = pspec[p.id] else { continue }
            let objs = (s["objs"] as? [[String: Any]]) ?? [], gone = (s["gone"] as? [Int]) ?? []
            let ex = p.page.annotations, geo = PageGeo(p.page)
            func sig(_ a: PDFAnnotation, _ k: Int) -> [String: Any] {          // 種類＋位置＋/NM＋第幾個：回覆跟它回的那一個同位置，只看位置會找錯
                let b = a.bounds
                var x: [String: Any] = ["sub": a.type ?? "", "r": [Double(b.minX), Double(b.minY), Double(b.maxX), Double(b.maxY)], "k": k]
                if let nm = a.value(forAnnotationKey: .name) as? String { x["nm"] = nm }
                return x
            }
            var rm: [[String: Any]] = [], mv: [[String: Any]] = [], add = false
            for ai in gone where ai >= 0 && ai < ex.count { rm.append(sig(ex[ai], ai)) }
            for o in objs {
                guard let t = o["t"] as? String, EditorAnnots.types.contains(t) else { continue }
                if let ai = o["aid"] as? Int {
                    guard ai >= 0, ai < ex.count, (o["dirty"] as? Bool) == true else { continue }
                    if t == "reply" {                                           // 既有的回覆：只改字
                        var m = sig(ex[ai], ai); m["to"] = m["r"]
                        if let n = o["note"] as? String { m["note"] = n }
                        mv.append(m); continue
                    }
                    if t == "xann" || t == "xfield" || t == "file" {
                        var m = sig(ex[ai], ai)
                        let r = geo.rawRect(CGRect(x: EditorDraw.d(o, "x"), y: EditorDraw.d(o, "y"), width: EditorDraw.d(o, "w"), height: EditorDraw.d(o, "h")))
                        m["to"] = [Double(r.minX), Double(r.minY), Double(r.maxX), Double(r.maxY)]
                        if t != "xfield", let n = o["note"] as? String { m["note"] = n }
                        mv.append(m); continue
                    }
                    var m = sig(ex[ai], ai)
                    if let id = o["id"] as? String { m["re"] = EditorAnnots.nmId(id) }     // 改過＝重做：底下的回覆改指新的那個
                    rm.append(m)
                }
                if t == "file" { continue }                                     // 新的附加檔案：MuPDF 直接放（linkThreads），不經 PDFKit
                add = true
            }
            if rm.isEmpty && mv.isEmpty && !add { continue }
            var op: [String: Any] = ["i": i]
            if !rm.isEmpty { op["rm"] = rm }
            if !mv.isEmpty { op["mv"] = mv }
            if add { op["add"] = true; adds = true }
            annops.append(op)
        }
        // 回覆串與附加檔案：每一頁新的回覆接到哪一個、新的附加檔案放哪裡（E1 與舊做法都交給 MuPDF 的 linkThreads）
        var threads: [[String: Any]] = []
        for (i, p) in pages.enumerated() {
            guard let s = pspec[p.id] else { continue }
            let ex = p.page.annotations
            var reps: [[String: Any]] = [], fl: [[String: Any]] = []
            let all = (s["objs"] as? [[String: Any]]) ?? []
            for o in all where o["aid"] == nil {
                guard let t = o["t"] as? String, let id = o["id"] as? String else { continue }
                if t == "reply" {
                    var par: [String: Any]
                    let po = (o["re"] as? String).flatMap { re in all.first { ($0["id"] as? String) == re } }
                    if let po, po["aid"] != nil, (po["dirty"] as? Bool) == true, let pt = po["t"] as? String, !["xann", "xfield", "file", "reply"].contains(pt), let re = po["id"] as? String {
                        par = ["new": EditorAnnots.nmId(re)]                                  // 上一層這次改過（重做）：接到新的那個
                    } else if let pa = o["paid"] as? Int, pa >= 0, pa < ex.count {
                        let b = ex[pa].bounds
                        par = ["sub": ex[pa].type ?? "", "r": [Double(b.minX), Double(b.minY), Double(b.maxX), Double(b.maxY)], "k": pa,
                               "nm": (ex[pa].value(forAnnotationKey: .name) as? String) ?? EditorAnnots.parentNM(p.id, pa)]
                    } else if let pr = o["pref"] as? String { par = ["new": EditorAnnots.nmId(pr)] } else { continue }
                    reps.append(["rid": EditorAnnots.nmId(id), "parent": par])
                } else if t == "file", let tok = o["tok"] as? String, let u = files[tok] {
                    let x = EditorDraw.d(o, "x"), y = EditorDraw.d(o, "y"), w = max(8, EditorDraw.d(o, "w", 16)), h = max(8, EditorDraw.d(o, "h", 20))
                    fl.append(["fid": EditorAnnots.nmId(id), "rect": [Double(x), Double(y), Double(x + w), Double(y + h)], "path": u.path,
                               "name": (o["name"] as? String) ?? u.lastPathComponent, "mime": UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                               "note": (o["note"] as? String) ?? "", "author": (o["author"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName(), "icon": "Paperclip"])
                }
            }
            if !reps.isEmpty || !fl.isEmpty { threads.append(["i": i, "replies": reps, "files": fl]) }
        }
        let tag = String(UUID().uuidString.prefix(6))
        let base = work.appendingPathComponent("base-\(tag).pdf")
        // PDFKit 那份（只在要搬新註解、或有不是來源檔的頁時才寫；E1 失敗時退回舊做法也用它）
        var donorReady = false
        func makeDonor() throws {
            guard !donorReady else { return }
            guard let data = doc.dataRepresentation(), let copy = PDFDocument(data: data), copy.pageCount == pages.count else {
                throw ToolError.msg(L("存檔失敗（這份的結構寫不回去）", "Couldn’t save"))
            }
            let author = NSFullUserName()
            let pageOf: (String) -> PDFPage? = { id in self.index(id).flatMap { copy.page(at: $0) } }
            for (i, p) in pages.enumerated() {
                guard let cp = copy.page(at: i), let s = pspec[p.id] else { continue }
                let objs = (s["objs"] as? [[String: Any]]) ?? [], gone = (s["gone"] as? [Int]) ?? []
                if !gone.isEmpty || objs.contains(where: { EditorAnnots.types.contains(($0["t"] as? String) ?? "") }) {
                    EditorAnnots.apply(cp, objs: objs, gone: gone, images: images, pageOf: pageOf, author: author, pageId: p.id)
                }
            }
            if let meta = spec["meta"] as? [String: Any] {
                var attrs = copy.documentAttributes ?? [:]
                for (k, key) in [("title", PDFDocumentAttribute.titleAttribute), ("author", .authorAttribute), ("subject", .subjectAttribute)] {
                    if let v = meta[k] as? String { attrs[key] = v }
                }
                if let v = meta["keywords"] as? String { attrs[PDFDocumentAttribute.keywordsAttribute] = v.split(whereSeparator: { ",，、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) } }
                copy.documentAttributes = attrs
            }
            guard copy.write(to: base) else { throw ToolError.msg(L("存檔失敗（磁碟空間不夠，或這份的結構寫不回去）", "Couldn’t save")) }
            donorReady = true
        }
        let needDonor = foreign || adds || forms.keys.contains { !radios.keys.contains($0) }   // 填表單：外觀用 PDFKit 畫的（會嵌字型）
        if needDonor { try makeDonor() }
        progress?(0.3)
        // 2) 新加的內容：每頁畫成一頁（原頁的座標），存檔時當表單疊上去；背景畫在下面
        let ovU = work.appendingPathComponent("ov-\(tag).pdf"), unU = work.appendingPathComponent("un-\(tag).pdf")
        var ov: CGContext?, un: CGContext?, ovN = 0, unN = 0
        var mu: [[String: Any]] = []
        let file = PDFs.stem(original)
        func inRange(_ o: [String: Any]?, _ i: Int) -> Bool {
            guard let o else { return false }
            let from = max(1, (o["from"] as? Int) ?? 1), to = (o["to"] as? Int) ?? Int.max
            return i + 1 >= from && i + 1 <= to
        }
        func begin(_ c: inout CGContext?, _ u: URL, _ p: PDFPage) throws -> CGContext {
            if c == nil {
                var mb = CGRect.zero
                c = CGContext(u as CFURL, mediaBox: &mb, [kCGPDFContextCreator as String: "Slimly \(Engine.appVersion)"] as CFDictionary)
            }
            guard let ctx = c else { throw ToolError.msg(L("寫不出新檔", "Couldn’t create the output")) }
            var r = p.bounds(for: .mediaBox)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &r, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            return ctx
        }
        func arr(_ o: [String: Any]) -> [Double] {
            let x = EditorDraw.d(o, "x"), y = EditorDraw.d(o, "y"), w = EditorDraw.d(o, "w"), h = EditorDraw.d(o, "h")
            return [Double(x), Double(y), Double(x + w), Double(y + h)]
        }
        for (i, p) in pages.enumerated() {
            progress?(0.3 + 0.4 * Double(i) / Double(max(1, pages.count)))
            let objs = (pspec[p.id]?["objs"] as? [[String: Any]]) ?? []
            let geo = PageGeo(p.page)
            var mp: [String: Any] = ["i": i]
            var bands: [[Double]] = [], white: [[Double]] = [], redact: [[Double]] = [], img: [[String: Any]] = []
            for o in objs {
                switch (o["t"] as? String) ?? "" {
                case "para": bands += (o["bands"] as? [[Double]]) ?? []
                case "white": white.append(arr(o))
                case "redact": redact.append(arr(o))
                case "ximg":
                    guard let k = o["k"] as? Int, let b = o["b0"] as? [Double] else { continue }
                    if (o["del"] as? Bool) == true { img.append(["k": k, "op": "del", "b": b]); continue }
                    let T = (o["T"] as? [Double]) ?? [1, 0, 0, 1, 0, 0]
                    if let tok = o["rep"] as? String, let u = images[tok] {
                        // 換圖：MuPDF 讀得了 PNG／JPEG；其他格式（HEIC…）先轉 PNG
                        var src = u
                        if !["png", "jpg", "jpeg"].contains(u.pathExtension.lowercased()), let im = Convert.loadAnyImage(u), let png = Raster.encode(im, type: .png) {
                            src = work.appendingPathComponent("rep-\(tag)-\(k).png"); try? png.write(to: src)
                        }
                        img.append(["k": k, "op": "rep", "b": b, "T": T, "file": src.path]); continue
                    }
                    let ident = zip(T, [1.0, 0, 0, 1, 0, 0]).allSatisfy { abs($0 - $1) < 1e-4 }
                    if !ident { img.append(["k": k, "op": "move", "b": b, "T": T]) }
                default: break
                }
            }
            var fields: [[String: Any]] = []
            for o in objs where (o["t"] as? String) == "field" {
                var f: [String: Any] = [:]
                f["ft"] = (o["ft"] as? String) ?? "text"
                f["name"] = (o["name"] as? String) ?? "field"
                f["r"] = arr(o)
                f["fs"] = (o["fs"] as? Double) ?? 11.0
                f["req"] = (o["req"] as? Bool) ?? false
                f["multi"] = (o["multi"] as? Bool) ?? false
                if let v = o["opts"] as? [String] { f["opts"] = v }
                if let v = o["ev"] as? String { f["ev"] = v }
                if let v = o["val"] as? String, !v.isEmpty { f["val"] = v }
                fields.append(f)
            }
            if !fields.isEmpty { mp["fields"] = fields }
            let content = objs.filter { ["para", "image", "sig", "ini", "mark", "white", "redact"].contains(($0["t"] as? String) ?? "") }
            let pnOn = pn != nil && i + 1 >= pnFrom
            let behind = (wm?["behind"] as? Bool) ?? false
            let wmOn = wm != nil && inRange(wm, i)
            if !content.isEmpty || pnOn || hf != nil || (wmOn && !behind) {
                let ctx = try begin(&ov, ovU, p.page)
                ctx.saveGState(); ctx.concatenate(geo.Ai)
                for o in content where (o["t"] as? String) != "redact" { ctx.saveGState(); EditorDraw.object(ctx, o, geo.size, images: images); ctx.restoreGState() }
                for o in content where (o["t"] as? String) == "redact" { ctx.saveGState(); EditorDraw.object(ctx, o, geo.size, images: images); ctx.restoreGState() }
                if let pn, pnOn { ctx.saveGState(); EditorDraw.pageNumber(ctx, geo.size, n: i + 1, total: pages.count, pn); ctx.restoreGState() }
                if let hf { ctx.saveGState(); EditorDraw.headerFooter(ctx, geo.size, n: i + 1, total: pages.count, file: file, hf); ctx.restoreGState() }
                if let wm, wmOn, !behind { ctx.saveGState(); if wm["src"] != nil { EditorDraw.imageWatermark(ctx, geo.size, wm, images: images) } else { EditorDraw.watermark(ctx, geo.size, wm) }; ctx.restoreGState() }
                ctx.restoreGState(); ctx.endPDFPage()
                mp["over"] = ovN; ovN += 1
            }
            if (bg != nil && inRange(bg, i)) || (wmOn && behind) {
                let ctx = try begin(&un, unU, p.page)
                ctx.saveGState(); ctx.concatenate(geo.Ai)
                if let bg, inRange(bg, i) { EditorDraw.background(ctx, geo.size, bg) }
                if let wm, wmOn, behind { ctx.saveGState(); if wm["src"] != nil { EditorDraw.imageWatermark(ctx, geo.size, wm, images: images) } else { EditorDraw.watermark(ctx, geo.size, wm) }; ctx.restoreGState() }
                ctx.restoreGState(); ctx.endPDFPage()
                mp["under"] = unN; unN += 1
            }
            if !bands.isEmpty { mp["bands"] = bands }
            if !white.isEmpty { mp["white"] = white }
            if !redact.isEmpty { mp["redact"] = redact }
            if !img.isEmpty { mp["img"] = img }
            if mp.count > 1 { mu.append(mp) }
        }
        ov?.closePDF(); un?.closePDF()
        progress?(0.72)
        // 3) MuPDF：搬圖、刪字、疊上去、表單欄位、清除隱藏資訊、加密（AES-256；權限：列印、拷貝、註解與表單、修改）
        var result = base
        let sanitize = spec["sanitize"] as? [String: Any]
        let perms = spec["perms"] as? [String: Any]
        let owner = ownerPassword.flatMap { $0.isEmpty ? nil : $0 }
        let user = password.flatMap { $0.isEmpty ? nil : $0 }
        let encrypt = user != nil || (perms != nil && owner != nil)
        // 書籤（畫面上改過才有）：頁代號 → 第幾頁，交給 MuPDF 整棵寫
        var outline: [[String: Any]]? = nil
        if let ol = spec["outline"] as? [[String: Any]] {
            func conv(_ list: [[String: Any]]) -> [[String: Any]] {
                var out: [[String: Any]] = []
                for it in list {
                    var x: [String: Any] = [:]
                    x["title"] = (it["title"] as? String) ?? ""
                    var pi = -1
                    if let pid = it["page"] as? String, let k = self.index(pid) { pi = k }
                    x["page"] = pi
                    x["y"] = (it["y"] as? Double) ?? 0.0
                    x["open"] = !((it["closed"] as? Bool) ?? false)
                    x["kids"] = conv((it["kids"] as? [[String: Any]]) ?? [])
                    out.append(x)
                }
                return out
            }
            outline = conv(ol)
        }
        var ms: [String: Any] = ["pages": mu]
        let same = pages.count == sourcePages.count && zip(pages, sourcePages).allSatisfy { $0.page === $1 }
        ms["src"] = ["path": source.path, "same": same, "pw": sourcePassword != nil, "keep": sourceKeeps] as [String: Any]
        if !radios.isEmpty { ms["radios"] = radios }
        if !threads.isEmpty { ms["threads"] = threads }
        if let outline { ms["outline"] = outline }
        if ovN > 0 { ms["overlay"] = ovU.path }
        if unN > 0 { ms["underlay"] = unU.path }
        if let sanitize { ms["sanitize"] = sanitize }
        if encrypt {
            // PDF 權限位元：3 列印、4 修改、5 拷貝、6 註解、9 填表單、10 無障礙擷取、11 組頁、12 高品質列印；7-8、13-32 固定為 1
            var bits: UInt32 = 0xFFFF_F0C0
            let pm = perms ?? [:], all = perms == nil
            if all || (pm["print"] as? Bool) == true { bits |= 4 | 2048 }
            if all || (pm["edit"] as? Bool) == true { bits |= 8 | 1024 }
            if all || (pm["copy"] as? Bool) == true { bits |= 16 | 512 }
            if all || (pm["comment"] as? Bool) == true { bits |= 32 | 256 }
            ms["encrypt"] = ["perms": Int(Int32(bitPattern: bits))]
        }
        let lines = (sourcePassword.map { "\($0)\n" } ?? "") + (encrypt ? "\(user ?? "")\n\(owner ?? user ?? "")\n" : "")
        func runMu(_ m: [String: Any], _ input: URL, _ name: String) throws -> URL {
            let su = work.appendingPathComponent("spec-\(tag)-\(name).json"), o1 = work.appendingPathComponent("mu-\(tag)-\(name).pdf")
            try MuTool.json(m, to: su)
            _ = try MuTool.run(["apply", input.path, su.path, o1.path], timeout: 900, stdin: lines.isEmpty ? nil : lines)
            return o1
        }
        // E1：從來源檔直接改（頁的順序、旋轉、裁切；註解只動有變的；表單的值、文件資訊也由 MuPDF 寫）
        var e1 = ms
        e1["e1"] = true; e1["pagemap"] = pagemap; e1["donor"] = needDonor
        if !annops.isEmpty { e1["annops"] = annops }
        let fv = forms.filter { !radios.keys.contains($0.key) }
        if !fv.isEmpty { e1["forms"] = fv }
        if let meta = spec["meta"] as? [String: Any] {
            var info: [String: String] = [:]
            for (k, key) in [("title", "Title"), ("author", "Author"), ("subject", "Subject"), ("keywords", "Keywords")] { if let v = meta[k] as? String { info[key] = v } }
            if !info.isEmpty { e1["meta"] = info }
        }
        do {
            result = try runMu(e1, needDonor ? base : source, "e1")
        } catch {
            // 退回舊做法（PDFKit 那份當底、MuPDF 修補）：存得出來最要緊
            FileHandle.standardError.write(Data("E1 FALLBACK: \((error as? ToolError)?.text ?? error.localizedDescription)\n".utf8))
            try makeDonor()
            result = try runMu(ms, base, "old")
        }
        progress?(0.9)
        let final = result
        guard let check = PDFDocument(url: final) else { throw ToolError.msg(L("存出來的檔打不開，沒交出去", "The result didn’t open")) }
        if let pw = password, !pw.isEmpty {
            guard check.isLocked, check.unlock(withPassword: pw) else { throw ToolError.msg(L("加密後驗不過，沒交出去", "Encryption check failed")) }
        }
        guard check.pageCount == pages.count else { throw ToolError.msg(L("存出來 \(check.pageCount) 頁、應該 \(pages.count) 頁，沒交出去", "Page count mismatch")) }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: final, to: out)
        for u in [base, ovU, unU] where u != final { try? FileManager.default.removeItem(at: u) }
    }

    /// 存好之後：編輯器改開存出來的那一份（加上去的字、圖變成頁面內容，之後用「改字」「改圖」繼續改；註解變成既有的註解）
    func reload(from u: URL, password pw: String?) -> Bool {
        guard let d = PDFDocument(url: u), d.pageCount > 0 else { return false }
        if d.isLocked { guard let pw, d.unlock(withPassword: pw) else { return false } }
        load(d.isEncrypted ? PDFs.rebuild(d) : d, from: u, password: d.isEncrypted ? pw : nil)
        return true
    }

    /// 書籤樹（畫面左邊「書籤」）
    func outlineTree() -> [[String: Any]] {
        guard let root = doc.outlineRoot else { return [] }
        func conv(_ o: PDFOutline) -> [String: Any] {
            var x: [String: Any] = ["title": o.label ?? ""]
            if let d = o.destination ?? (o.action as? PDFActionGoTo)?.destination, let dp = d.page, let pi = pages.firstIndex(where: { $0.page == dp }) {
                x["page"] = pages[pi].id
                if d.point.y != kPDFDestinationUnspecifiedValue { x["y"] = Double(PageGeo(dp).disp(d.point).y) }
            }
            x["kids"] = (0..<o.numberOfChildren).compactMap { o.child(at: $0) }.map(conv)
            return x
        }
        return (0..<root.numberOfChildren).compactMap { root.child(at: $0) }.map(conv)
    }
    /// 文件資訊（標題、作者、主旨、關鍵字）
    func meta() -> [String: Any] {
        let a = doc.documentAttributes ?? [:]
        let kw = (a[PDFDocumentAttribute.keywordsAttribute] as? [String])?.joined(separator: ", ") ?? (a[PDFDocumentAttribute.keywordsAttribute] as? String) ?? ""
        return ["title": (a[PDFDocumentAttribute.titleAttribute] as? String) ?? "", "author": (a[PDFDocumentAttribute.authorAttribute] as? String) ?? "",
                "subject": (a[PDFDocumentAttribute.subjectAttribute] as? String) ?? "", "keywords": kw,
                "creator": (a[PDFDocumentAttribute.creatorAttribute] as? String) ?? "", "producer": (a[PDFDocumentAttribute.producerAttribute] as? String) ?? "",
                "version": "\(doc.majorVersion).\(doc.minorVersion)", "bytes": PDFs.fileSize(original)]
    }
}

// MARK: - 把畫面上的東西畫進 PDF（跟 editor.html 用同一套座標與字型）

enum EditorDraw {
    static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return CGColor(gray: 0.12, alpha: alpha) }
        return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: alpha)
    }
    static func d(_ o: [String: Any], _ k: String, _ def: CGFloat = 0) -> CGFloat { CGFloat((o[k] as? Double) ?? (o[k] as? NSNumber)?.doubleValue ?? Double(def)) }

    static func object(_ ctx: CGContext, _ o: [String: Any], _ sz: CGSize, images: [String: URL]) {
        let t = (o["t"] as? String) ?? ""
        let x = d(o, "x"), y = d(o, "y"), w = d(o, "w"), h = d(o, "h")
        let r = CGRect(x: x, y: sz.height - y - h, width: w, height: h)
        let rot = d(o, "rot")
        if rot != 0, ["image", "sig", "ini", "mark"].contains(t) {                     // 跟著頁面轉過的圖：繞中心轉（畫面上是順時針）
            ctx.translateBy(x: r.midX, y: r.midY); ctx.rotate(by: -rot * .pi / 180); ctx.translateBy(x: -r.midX, y: -r.midY)
        }
        switch t {
        case "para":
            para(ctx, o, sz)
        case "mark":
            mark(ctx, o, sz)
        case "image", "sig", "ini":
            guard let token = o["src"] as? String, let u = images[token], let img = Convert.loadAnyImage(u) else { return }
            ctx.setAlpha(d(o, "opacity", 1))
            ctx.interpolationQuality = .high
            ctx.draw(img, in: r)
        case "hl":
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(color((o["color"] as? String) ?? "#FFE066"))
            ctx.fill(r)
        case "white":
            ctx.setFillColor(color((o["color"] as? String) ?? "#FFFFFF")); ctx.fill(r)
        case "redact":
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(r)
        case "rect", "ellipse":
            let lw = d(o, "width", 2)
            ctx.setLineWidth(lw)
            ctx.setStrokeColor(color((o["color"] as? String) ?? "#E0301E"))
            let rr = r.insetBy(dx: lw / 2, dy: lw / 2)
            if t == "rect" { ctx.stroke(rr) } else { ctx.strokeEllipse(in: rr) }
        case "line", "arrow":
            let lw = d(o, "width", 2)
            let a = CGPoint(x: d(o, "x1"), y: sz.height - d(o, "y1")), b = CGPoint(x: d(o, "x2"), y: sz.height - d(o, "y2"))
            let c = color((o["color"] as? String) ?? "#E0301E")
            ctx.setStrokeColor(c); ctx.setFillColor(c); ctx.setLineWidth(lw); ctx.setLineCap(.round)
            var end = b
            if t == "arrow" {
                let ang = atan2(b.y - a.y, b.x - a.x), L = max(8, lw * 4.5), spread: CGFloat = 0.45
                let p1 = CGPoint(x: b.x - L * cos(ang - spread), y: b.y - L * sin(ang - spread))
                let p2 = CGPoint(x: b.x - L * cos(ang + spread), y: b.y - L * sin(ang + spread))
                ctx.move(to: b); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath(); ctx.fillPath()
                end = CGPoint(x: b.x - L * 0.8 * cos(ang), y: b.y - L * 0.8 * sin(ang))
            }
            ctx.move(to: a); ctx.addLine(to: end); ctx.strokePath()
        case "ink":
            guard let pts = o["pts"] as? [[Double]], pts.count > 0 else { return }
            let lw = d(o, "width", 2.5)
            ctx.setStrokeColor(color((o["color"] as? String) ?? "#1E2223")); ctx.setLineWidth(lw)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let P = pts.map { CGPoint(x: $0[0], y: Double(sz.height) - $0[1]) }
            ctx.move(to: P[0])
            if P.count == 1 { ctx.addLine(to: CGPoint(x: P[0].x + 0.1, y: P[0].y)) }
            for i in 1..<max(1, P.count - 1) where P.count > 2 {
                let m = CGPoint(x: (P[i].x + P[i + 1].x) / 2, y: (P[i].y + P[i + 1].y) / 2)
                ctx.addQuadCurve(to: m, control: P[i])
            }
            if P.count > 1 { ctx.addLine(to: P[P.count - 1]) }
            ctx.strokePath()
        default: break
        }
    }

    /// 一段字（可以多行）：行高 1.25 倍、上緣對齊——跟畫面上的 CSS 同一套排法，存出來位置才對得上
    static func text(_ ctx: CGContext, _ s: String, topLeft: CGPoint, size: CGFloat, bold: Bool, color: CGColor) {
        let f = Overlay.font(size, bold: bold)
        let A = CTFontGetAscent(f), D = CTFontGetDescent(f), lh = size * 1.25
        for (i, line) in s.components(separatedBy: "\n").enumerated() {
            guard !line.isEmpty else { continue }
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: f, .foregroundColor: color]))
            let baseline = topLeft.y - CGFloat(i) * lh - ((lh - (A + D)) / 2 + A)
            ctx.textPosition = CGPoint(x: topLeft.x, y: baseline)
            CTLineDraw(l, ctx)
        }
    }

    /// 頁碼（跟「加頁碼」工具同一套：九宮格位置、10 mm 邊界）
    static func pageNumber(_ ctx: CGContext, _ sz: CGSize, n: Int, total: Int, _ pn: [String: Any]) {
        let from = max(1, (pn["from"] as? Int) ?? 1), start = (pn["start"] as? Int) ?? 1
        let k = start + (n - from), all = start + (total - from)
        let s: String
        switch (pn["fmt"] as? String) ?? "n" {
        case "nN": s = "\(k) / \(all)"
        case "page": s = L("第 \(k) 頁", "Page \(k)")
        case "dash": s = "– \(k) –"
        default: s = "\(k)"
        }
        let size = CGFloat((pn["size"] as? Double) ?? 10)
        let (p, hh, vv) = Overlay.anchor((pn["pos"] as? String) ?? "bc", sz, margin: 10 * 72 / 25.4)
        Overlay.draw(Overlay.line(s, size: size, color: CGColor(gray: 0.15, alpha: 1)), in: ctx, at: p, h: hh, v: vv)
    }

    /// 浮水印：一行字，置中或鋪滿、斜放、半透明
    static func watermark(_ ctx: CGContext, _ sz: CGSize, _ wm: [String: Any]) {
        let text = (wm["text"] as? String) ?? ""
        guard !text.isEmpty else { return }
        let alpha = CGFloat((wm["opacity"] as? Double) ?? 0.2), angle = CGFloat((wm["angle"] as? Double) ?? 45)
        let tile = (wm["tile"] as? Bool) ?? false
        let size = CGFloat((wm["size"] as? Double) ?? 0) > 0 ? CGFloat((wm["size"] as? Double) ?? 0) : min(sz.width, sz.height) / (tile ? 14 : 7)
        let line = Overlay.line(text, size: size, bold: true, color: CGColor(gray: 0.35, alpha: 1))
        if tile {
            let stepX = line.width + size * 3, stepY = size * 4
            var y: CGFloat = -stepY, row = 0
            while y < sz.height + stepY {
                var x: CGFloat = row % 2 == 0 ? -line.width / 2 : stepX / 2 - line.width / 2
                while x < sz.width + stepX { Overlay.draw(line, in: ctx, at: CGPoint(x: x, y: y), h: 0, v: 0, angle: angle, alpha: alpha); x += stepX }
                y += stepY; row += 1
            }
        } else {
            Overlay.draw(line, in: ctx, at: CGPoint(x: sz.width / 2, y: sz.height / 2), h: 0, v: 0, angle: angle, alpha: alpha)
        }
    }
}

// MARK: - 視窗

final class EditorWebView: WKWebView {
    var onFiles: (([URL], CGPoint) -> Void)?
    var onKey: ((String) -> Void)?
    var textFocus = false                   // 頁面上有輸入框在打字：⌘C ⌘V ⌘X ⌘A 交給輸入框
    private func fileURLs(_ s: NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { fileURLs(s).isEmpty ? super.draggingEntered(s) : .copy }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { fileURLs(s).isEmpty ? super.draggingUpdated(s) : .copy }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { fileURLs(s).isEmpty ? super.prepareForDragOperation(s) : true }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let urls = fileURLs(s)
        guard !urls.isEmpty else { return super.performDragOperation(s) }
        let p = convert(s.draggingLocation, from: nil)
        onFiles?(urls, CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y))
        return true
    }
    override func concludeDragOperation(_ s: NSDraggingInfo?) { if let s, !fileURLs(s).isEmpty { return }; super.concludeDragOperation(s) }
    /// ⌘Z ⌘⇧Z ⌘S ⌘= ⌘- ⌘0 交給頁面（不然會被選單吃掉）；頁面自己判斷是在輸入框裡（交給輸入框復原）還是編輯器的復原
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, e.modifierFlags.contains(.command), window?.isKeyWindow == true else { return super.performKeyEquivalent(with: e) }
        let shift = e.modifierFlags.contains(.shift)
        let name: String?
        switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "z": name = shift ? "redo" : "undo"
        case "s": name = "save"
        case "=", "+": name = "zoomIn"
        case "-": name = "zoomOut"
        case "0": name = "zoomFit"
        case "f": name = "find"
        case "p": name = "print"
        case "d": name = textFocus ? nil : "dup"
        case "c": name = textFocus ? nil : "copy"
        case "x": name = textFocus ? nil : "cut"
        case "v": name = textFocus ? nil : "paste"
        case "a": name = textFocus ? nil : "selectAll"
        default: name = nil
        }
        guard let name else { return super.performKeyEquivalent(with: e) }
        onKey?(name)
        return true
    }
}

/// 設定檔會強留住訊息處理與自訂網址處理：隔一層弱參照，視窗關了才放得掉
private final class WeakHandler: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
    weak var target: EditorWindowController?
    init(_ t: EditorWindowController) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.receive(m) }
    func webView(_ w: WKWebView, start t: WKURLSchemeTask) { if let c = target { c.start(t) } else { t.didFailWithError(URLError(.cancelled)) } }
    func webView(_ w: WKWebView, stop t: WKURLSchemeTask) { target?.stop(t) }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    let doc: EditorDoc
    private(set) var web: EditorWebView!
    private var ready = false
    private var dirty = false
    private var live = Set<ObjectIdentifier>()
    private var busy: ToolCancel?
    private var clipCount = -1
    var onClose: ((EditorWindowController) -> Void)?
    var onCompress: ((URL) -> Void)?
    var isTest = false
    private var testPicks: [String] = []    // 測試模式：下一次「選檔」直接用這些檔，不開選檔視窗
    private var testDest: URL?               // 測試模式：「存出附件」直接存進這個資料夾，不開存檔視窗
    static let attachMax: Int64 = 100_000_000, attachWarn: Int64 = 10_000_000   // 附加檔案：超過 100 MB 不收；超過 10 MB 提醒 PDF 會變大（跟編輯器顯示的大小同一個單位：1000 進位）
    var pendingInsert: [URL] = []           // 一次打開好幾份：第一份開好後，其他的接在後面（＝合併）

    init(url: URL) {
        doc = EditorDoc(url)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = url.lastPathComponent
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Const.materialColor
        w.minSize = NSSize(width: 900, height: 600)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("SlimlyEditor")
        if !w.setFrameUsingName("SlimlyEditor") { w.center() }
        let cfg = WKWebViewConfiguration()
        let h = WeakHandler(self)
        cfg.userContentController.add(h, name: "ed")
        cfg.setURLSchemeHandler(h, forURLScheme: "slimly")
        web = EditorWebView(frame: w.contentView?.bounds ?? .zero, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        if web.responds(to: Selector(("setInspectable:"))) { web.setValue(true, forKey: "inspectable") }
        web.onFiles = { [weak self] urls, p in self?.dropped(urls, at: p) }
        web.onKey = { [weak self] k in self?.emit(["type": "key", "name": k]) }
        w.contentView = web
        if let ui = Bundle.main.url(forResource: "editor", withExtension: "html") { web.loadFileURL(ui, allowingReadAccessTo: ui.deletingLastPathComponent()) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    // MARK: 關視窗（還沒存的先問）

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty, !isTest else { return true }
        let a = NSAlert()
        a.messageText = L("改過的地方還沒存", "You have unsaved changes")
        a.informativeText = L("原檔不會被改到。存的話會另存一份「\(PDFs.stem(doc.original))（已編輯）.pdf」。", "The original stays as it is. Saving creates “\(PDFs.stem(doc.original)) (edited).pdf”.")
        a.addButton(withTitle: L("存檔", "Save"))
        a.addButton(withTitle: L("不存", "Don’t Save"))
        a.addButton(withTitle: L("取消", "Cancel"))
        switch a.runModal() {
        case .alertFirstButtonReturn: emit(["type": "key", "name": "saveClose"]); return false
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func windowWillClose(_ n: Notification) {
        busy?.cancel()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ed")
        doc.closed = true
        doc.q.async { self.doc.cleanup() }
        onClose?(self)
    }

    // MARK: 畫面 → Swift

    func emit(_ payload: [String: Any]) {
        guard ready || payload["type"] as? String == "ready",
              let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.web?.evaluateJavaScript("window.edEvent && window.edEvent(\(json))") }
    }
    private func fail(_ e: Error, _ what: String) {
        let text = (e as? ToolError)?.text ?? e.localizedDescription
        if isTest { print("FAIL \(what): \(text)") }                // 驗收的紀錄看得到（畫面上只有一閃而過的提示）
        emit(["type": "error", "what": what, "text": text])
    }
    private func sendDoc(reload: Bool = false) {
        doc.q.async {
            let pages = self.doc.list(), fields = self.doc.fields()
            var annots: [String: Any] = [:]
            for p in self.doc.pages { let a = self.doc.annotations(p.id); if !a.isEmpty { annots[p.id] = a } }
            let info: [String: Any] = ["type": "doc", "reload": reload, "name": self.doc.original.lastPathComponent, "stem": PDFs.stem(self.doc.original), "pages": pages, "fields": fields,
                                       "annots": annots, "outline": self.doc.outlineTree(), "meta": self.doc.meta(), "fonts": FontMatch.menuList(), "user": NSFullUserName(),
                                       "hadPassword": self.doc.password != nil, "saveName": L("\(PDFs.stem(self.doc.original))（已編輯）.pdf", "\(PDFs.stem(self.doc.original)) (edited).pdf"),
                                       "saveDir": (Prefs.effectivePlace == "folder" ? L("放在「", "In “") : L("原檔旁邊（", "Next to the original (")) + self.saveDir().lastPathComponent + (Prefs.effectivePlace == "folder" ? L("」", "”") : L("）", ")")),
                                       "ai": { if #available(macOS 26.0, *) { return true } else { return false } }()]
            self.emit(info)
            let scanned = self.doc.scannedIds()
            if !scanned.isEmpty { self.emit(["type": "scanned", "ids": scanned]) }
        }
    }
    private func sendPages(_ added: [String] = [], shift: [String: [Double]] = [:], op: String = "", fresh: [String] = []) {
        doc.q.async {
            let l = self.doc.list(), u = self.doc.canUndo, r = self.doc.canRedo
            // 新加進來的頁、換掉的頁：它們原本的註解也要變成畫面上的物件
            var annots: [String: Any] = [:]
            for id in added + fresh { annots[id] = self.doc.annotations(id) }
            self.emit(["type": "pages", "pages": l, "added": added, "shift": shift, "op": op, "canUndo": u, "canRedo": r, "annots": annots, "fresh": fresh])
        }
    }
    private func saveDir() -> URL { Compressor.destination(for: doc.original, override: nil).dir }

    func receive(_ m: WKScriptMessage) {
        guard let b = m.body as? [String: Any], let action = b["action"] as? String else { return }
        switch action {
        case "ready":
            ready = true
            emit(["type": "prefs", "lang": Lang.isEn ? "en" : "zh", "theme": Prefs.theme])
            doc.q.async {
                switch self.doc.open() {
                case .ok:
                    self.sendDoc()
                    let more = self.pendingInsert; self.pendingInsert = []
                    if !more.isEmpty {
                        do { let added = try self.doc.apply("insertFiles", ["paths": more.map(\.path)]); self.sendPages(added) } catch { self.fail(error, "pageOp") }
                    }
                case .locked: self.emit(["type": "locked", "name": self.doc.original.lastPathComponent])
                case .restricted: self.emit(["type": "locked", "name": self.doc.original.lastPathComponent, "owner": true])
                case .damaged: self.emit(["type": "damaged", "name": self.doc.original.lastPathComponent])
                }
            }
        case "unlock":
            let pw = (b["password"] as? String) ?? ""
            doc.q.async {
                switch self.doc.open(password: pw) {
                case .ok: self.sendDoc()
                case .restricted: self.emit(["type": "locked", "name": self.doc.original.lastPathComponent, "wrong": true, "owner": true])
                default: self.emit(["type": "locked", "name": self.doc.original.lastPathComponent, "wrong": true])
                }
            }
        case "repair":
            // 打不開的：先用「修復」救一份到暫存，再打開那一份（原檔不動）
            emit(["type": "busy", "text": L("修復中…", "Repairing…")])
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Tools.run("repair", inputs: [self.doc.original], options: [:], dest: self.doc.work)
                self.doc.q.async {
                    if case .success(let res) = r, let u = res.outputs.first, let d = PDFDocument(url: u), d.pageCount > 0 {
                        self.doc.load(d, from: u); self.sendDoc()
                    } else { self.emit(["type": "damaged", "name": self.doc.original.lastPathComponent, "failed": true]) }
                }
            }
        case "text":
            guard let id = b["id"] as? String else { return }
            doc.q.async { self.emit(["type": "text", "id": id, "data": self.doc.pageText(id)]) }
        case "pageOp":
            guard let op = b["op"] as? String else { return }
            if op == "insertPick" { pickInsert(after: b["after"] as? String); return }
            if op == "ocr" { ocr(ids: (b["ids"] as? [String]) ?? []); return }
            doc.q.async {
                do { let r = try self.doc.applyEx(op, b); self.sendPages(r.added, shift: r.shift, op: op) } catch { self.fail(error, "pageOp"); self.sendPages() }
            }
        case "pageUndo": doc.q.async { self.doc.undo(); self.sendPages() }
        case "pageRedo": doc.q.async { self.doc.redo(); self.sendPages() }
        case "dirty": dirty = (b["on"] as? Bool) ?? false; window?.isDocumentEdited = dirty
        case "testPick":
            if isTest { testPicks = (b["paths"] as? [String]) ?? [] }
        case "testDest":
            if isTest, let d = b["path"] as? String { testDest = URL(fileURLWithPath: d) }
        case "pickFile":
            // 附加檔案註解：選一個檔（任何種類）
            if isTest { if testPicks.isEmpty { print("PICK none") } else { attachFile(URL(fileURLWithPath: testPicks.removeFirst())) }; return }
            let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false; p.prompt = L("附加", "Attach")
            guard let w = window else { return }
            p.beginSheetModal(for: w) { r in
                guard r == .OK, let u = p.url else { return }
                self.attachFile(u)
            }
        case "saveAttachment":
            // 附加檔案存出來：既有的從來源檔取出（MuPDF），這次才附加的直接拷貝；同名不覆蓋
            let pid = (b["pid"] as? String) ?? "", aid = b["aid"] as? Int, tok = b["token"] as? String
            let name = ((b["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("附件", "Attachment")).replacingOccurrences(of: "/", with: "-")
            if isTest { let d = testDest ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]; doc.q.async { self.extract(pid: pid, aid: aid, token: tok, into: d, name: name) }; return }
            let sp = NSSavePanel(); sp.nameFieldStringValue = name; sp.prompt = L("存出", "Save")
            sp.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard let w = window else { return }
            sp.beginSheetModal(for: w) { r in
                guard r == .OK, let u = sp.url else { return }
                self.doc.q.async { self.extract(pid: pid, aid: aid, token: tok, into: u.deletingLastPathComponent(), name: u.lastPathComponent) }
            }
        case "pickImage":
            let purpose = (b["purpose"] as? String) ?? "image"
            let use: (URL) -> Void = { u in
                if ["sigfile", "inifile"].contains(purpose) {
                    // 選一張現成的簽名圖當「我的簽名／縮寫」：轉成 PNG 存起來
                    let which = purpose == "inifile" ? "ini" : "sig"
                    if let img = Convert.loadAnyImage(u), let png = Raster.encode(img, type: .png) { try? png.write(to: Self.signatureURL(self.isTest, which), options: .atomic) }
                    self.emitSignature(); return
                }
                self.addImage(u, purpose: purpose)
            }
            if isTest { if testPicks.isEmpty { print("PICK none") } else { use(URL(fileURLWithPath: testPicks.removeFirst())) }; return }
            let p = NSOpenPanel(); p.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .pdf]; p.prompt = L("用這張", "Use")
            guard let w = window else { return }
            p.beginSheetModal(for: w) { r in
                guard r == .OK, let u = p.url else { return }
                use(u)
            }
        case "signature":
            emitSignature()
        case "saveSignature":
            if let s = b["data"] as? String, let comma = s.firstIndex(of: ","), let data = Data(base64Encoded: String(s[s.index(after: comma)...])) {
                try? data.write(to: Self.signatureURL(isTest, (b["which"] as? String) == "ini" ? "ini" : "sig"), options: .atomic)
            }
            emitSignature()
        case "focus": web.textFocus = (b["text"] as? Bool) ?? false
        case "search":
            let q = (b["q"] as? String) ?? "", mc = (b["mc"] as? Bool) ?? false, ww = (b["ww"] as? Bool) ?? false
            doc.q.async { let hits = self.doc.search(q, matchCase: mc, wholeWord: ww); self.emit(["type": "searched", "q": q, "hits": hits]) }
        case "clip":
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString((b["text"] as? String) ?? "", forType: .string)
            clipCount = pb.changeCount
        case "paste":
            let pb = NSPasteboard.general
            if pb.changeCount == clipCount { emit(["type": "paste", "internal": true]); return }
            if let img = NSImage(pasteboard: pb), let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
                let u = doc.work.appendingPathComponent("paste-\(UUID().uuidString.prefix(6)).png")
                if (try? png.write(to: u)) != nil { addImage(u, purpose: "paste") }
                return
            }
            if let s = pb.string(forType: .string), !s.isEmpty { emit(["type": "paste", "text": s]) }
        case "print":
            guard let spec = b["spec"] as? [String: Any] else { return }
            printDoc(spec)
        case "find":
            let presets = (b["presets"] as? [String]) ?? [], terms = (b["terms"] as? [String]) ?? []
            doc.q.async { let hits = self.doc.find(presets: presets, terms: terms); self.emit(["type": "found", "hits": hits]) }
        case "save":
            save(b)
        case "run":
            runDocTool(b)
        case "stop": busy?.cancel()
        case "reveal":
            if let p = b["path"] as? String, FileManager.default.fileExists(atPath: p) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        case "open":
            if let p = b["path"] as? String, FileManager.default.fileExists(atPath: p) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        case "share":
            let files = ((b["files"] as? [String]) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
            guard !files.isEmpty else { return }
            if isTest { print("SHARE \(files.count)"); return }
            var r = NSRect(x: web.bounds.width - 80, y: web.bounds.height - 40, width: 1, height: 1)
            if let d = b["rect"] as? [String: Any], let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue {
                r = NSRect(x: x, y: web.isFlipped ? y : web.bounds.height - y - 20, width: 1, height: 1)
            }
            NSSharingServicePicker(items: files.map { URL(fileURLWithPath: $0) }).show(relativeTo: r, of: web, preferredEdge: .minY)
        case "compress":
            if let p = b["path"] as? String { onCompress?(URL(fileURLWithPath: p)) }
        case "copyText":
            if let t = b["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
        case "close": window?.performClose(nil)
        default: break
        }
    }

    static func signatureURL(_ test: Bool, _ which: String = "sig") -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Slimly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = which == "ini" ? "initials" : "signature"
        return dir.appendingPathComponent(test ? "\(base)-test.png" : "\(base).png")
    }
    /// 我的簽名、縮寫（存在這台 Mac 的 Application Support）
    private func emitSignature() {
        doc.q.async {
            var ev: [String: Any] = ["type": "signature"]
            for which in ["sig", "ini"] {
                let u = Self.signatureURL(self.isTest, which)
                guard FileManager.default.fileExists(atPath: u.path), let img = NSImage(contentsOf: u) else { continue }
                self.doc.images[which] = u                                       // 右邊預覽「我的簽名」用的
                // 放到頁上的用當下那張的副本：之後重簽，已經放好的不會跟著換
                var token = which
                let copy = self.doc.work.appendingPathComponent("\(which)-\(UUID().uuidString.prefix(8)).png")
                if !self.doc.closed, (try? FileManager.default.copyItem(at: u, to: copy)) != nil { token = copy.deletingPathExtension().lastPathComponent; self.doc.images[token] = copy }
                ev[which] = ["token": token, "w": Double(img.size.width), "h": Double(img.size.height), "t": Date().timeIntervalSince1970]
            }
            self.emit(ev)
        }
    }
    /// 附加檔案註解：先擋資料夾、讀不到的、太大的（畫面照實講），通過就給畫面一個代號
    private func attachFile(_ u: URL) {
        let fm = FileManager.default, name = u.lastPathComponent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { emit(["type": "fileErr", "code": "missing", "name": name]); return }
        if isDir.boolValue { emit(["type": "fileErr", "code": "folder", "name": name]); return }
        guard fm.isReadableFile(atPath: u.path), let h = FileHandle(forReadingAtPath: u.path) else { emit(["type": "fileErr", "code": "unreadable", "name": name]); return }
        try? h.close()
        let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > Self.attachMax { emit(["type": "fileErr", "code": "toobig", "name": name, "size": size]); return }
        let token = "f" + String(UUID().uuidString.prefix(8))
        doc.q.async {
            self.doc.files[token] = u
            self.emit(["type": "file", "token": token, "name": name, "size": size, "big": size > Self.attachWarn])
        }
    }
    /// 附加檔案存出來（在 doc.q 上跑）：先寫到工作夾，再搬進目的地（同名加「 2」，絕不覆蓋）
    private func extract(pid: String, aid: Int?, token: String?, into dir: URL, name: String) {
        let fm = FileManager.default, tmp = doc.work.appendingPathComponent("att-\(UUID().uuidString.prefix(6))")
        defer { try? fm.removeItem(at: tmp) }
        do {
            if let token, let u = doc.files[token] { try fm.copyItem(at: u, to: tmp) }
            else if let aid, let j = doc.sourceIndex(pid) {
                do { _ = try MuTool.run(["extract", doc.source.path, String(j), String(aid), tmp.path], timeout: 300, stdin: doc.sourceStdin) }
                catch { if ((error as? ToolError)?.text ?? "").hasSuffix("empty") { emit(["type": "fileErr", "code": "empty", "name": name]); return }; throw error }
            } else { emit(["type": "fileErr", "code": "notsaved", "name": name]); return }
            let out = try Files.moveNoClobber(tmp, into: dir, name: name)
            emit(["type": "extracted", "path": out.path, "name": out.lastPathComponent, "dir": dir.lastPathComponent])
        } catch {
            emit(["type": "fileErr", "code": "extract", "name": name, "text": (error as? ToolError)?.text ?? error.localizedDescription])
        }
    }

    private func addImage(_ u: URL, purpose: String, at: CGPoint? = nil) {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return }
        var w: Double = 400, h: Double = 300
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? w
            h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? h
            if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 { swap(&w, &h) }
        }
        let token = "i" + String(UUID().uuidString.prefix(8))
        doc.q.async {
            self.doc.images[token] = u
            var ev: [String: Any] = ["type": "image", "token": token, "w": w, "h": h, "name": u.lastPathComponent, "purpose": purpose]
            if let at { ev["x"] = Double(at.x); ev["y"] = Double(at.y) }
            self.emit(ev)
        }
    }

    // MARK: 加頁（其他 PDF、圖片）、拖進來的檔

    private func pickInsert(after: String?) {
        if isTest {
            let paths = testPicks; testPicks = []
            doc.q.async {
                do { let added = try self.doc.apply("insertFiles", ["paths": paths, "after": after as Any]); self.sendPages(added) }
                catch { self.fail(error, "pageOp") }
            }
            return
        }
        let p = NSOpenPanel(); p.allowsMultipleSelection = true
        p.allowedContentTypes = [.pdf, .png, .jpeg, .heic, .tiff]; p.prompt = L("加進來", "Add")
        p.message = L("選 PDF 或圖片：頁會加在目前這頁後面", "Choose PDFs or images to insert after the current page")
        guard let w = window else { return }
        p.beginSheetModal(for: w) { r in
            guard r == .OK else { return }
            let paths = p.urls.map(\.path)
            self.doc.q.async {
                do { let added = try self.doc.apply("insertFiles", ["paths": paths, "after": after as Any]); self.sendPages(added) }
                catch { self.fail(error, "pageOp") }
            }
        }
    }
    /// 拖進編輯器：PDF＝加頁（放在滑鼠下那頁的後面）；圖片＝放在那一頁上
    private func dropped(_ urls: [URL], at p: CGPoint) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let imgs = urls.filter { Tools.IMG.contains($0.pathExtension.lowercased()) }
        if !imgs.isEmpty { for u in imgs { addImage(u, purpose: "drop", at: p) } }
        if !pdfs.isEmpty {
            web.evaluateJavaScript("window.edPageAt ? window.edPageAt(\(p.x), \(p.y)) : ''") { r, _ in
                let after = r as? String
                self.doc.q.async {
                    do { let added = try self.doc.apply("insertFiles", ["paths": pdfs.map(\.path), "after": (after?.isEmpty == false ? after : nil) as Any]); self.sendPages(added) }
                    catch { self.fail(error, "pageOp") }
                }
            }
        }
    }

    // MARK: 辨識文字（掃描的頁）：做好換進來，畫面上的東西位置不變

    private func ocr(ids: [String]) {
        let cancel = ToolCancel(); busy = cancel
        emit(["type": "busy", "text": L("辨識文字…", "Recognizing text…")])
        doc.q.async {
            let tmp = self.doc.work.appendingPathComponent("ocr-src-\(UUID().uuidString.prefix(6)).pdf")
            let want = ids.isEmpty ? self.doc.scannedIds() : ids
            let order = self.doc.pages.map(\.id)
            guard self.doc.doc.write(to: tmp) else { self.emit(["type": "busyDone"]); return }
            let r = Tools.run("ocr", inputs: [tmp], options: [:], dest: self.doc.work, progress: { t, f in self.emit(["type": "progress", "text": t, "frac": f]) }, cancel: cancel)
            self.busy = nil
            guard case .success(let res) = r, let u = res.outputs.first, let od = PDFDocument(url: u), od.pageCount == order.count else {
                if case .failure(let e) = r { self.fail(e, "ocr") }
                self.emit(["type": "busyDone"]); return
            }
            var m: [String: PDFPage] = [:]
            for (i, id) in order.enumerated() where want.contains(id) { if let p = od.page(at: i)?.copy() as? PDFPage { m[id] = p } }
            do { try self.doc.apply("replace", ["pages": m]); self.sendPages(fresh: Array(m.keys)); self.emit(["type": "ocrDone", "count": m.count, "notes": res.notes]) }
            catch { self.fail(error, "ocr") }
            self.emit(["type": "busyDone"])
        }
    }

    // MARK: 存檔

    private func save(_ b: [String: Any]) {
        guard let spec = b["spec"] as? [String: Any] else { if isTest { print("FAIL save: 沒有收到內容") }; return }
        let pw = (b["password"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ((b["keepPassword"] as? Bool) == true ? doc.password : nil)
        let owner = (b["ownerPassword"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let asNew = (b["asNew"] as? Bool) ?? false
        emit(["type": "busy", "text": L("存檔中…", "Saving…")])
        doc.q.async {
            do {
                let dir = self.saveDir()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                guard FileManager.default.isWritableFile(atPath: dir.path) else {
                    throw ToolError.msg(L("存不進「\(dir.path)」（唯讀或沒有權限）", "Can’t write to “\(dir.path)”"))
                }
                let tmp = self.doc.work.appendingPathComponent("save-\(UUID().uuidString.prefix(6)).pdf")
                try self.doc.compose(spec, to: tmp, password: pw, ownerPassword: owner) { f in self.emit(["type": "progress", "text": L("存檔中…", "Saving…"), "frac": f]) }
                var dst: URL
                if let out = self.doc.output, !asNew, FileManager.default.fileExists(atPath: out.path) {
                    _ = try FileManager.default.replaceItemAt(out, withItemAt: tmp)
                    dst = out
                } else {
                    dst = try Files.moveNoClobber(tmp, into: dir, name: L("\(PDFs.stem(self.doc.original))（已編輯）.pdf", "\(PDFs.stem(self.doc.original)) (edited).pdf"))
                    self.doc.output = dst
                }
                Prefs.remember(["name": dst.lastPathComponent, "out": dst.path, "before": PDFs.fileSize(self.doc.original), "after": PDFs.fileSize(dst),
                                "at": Date().timeIntervalSince1970, "tool": "edit"])
                DispatchQueue.main.async { self.dirty = false; self.window?.isDocumentEdited = false }
                // 接著改存出來的那一份：加上去的東西變成頁面內容（用「改字」「改圖」繼續改），註解變成既有的註解
                if (b["close"] as? Bool) != true, self.doc.reload(from: dst, password: pw) {
                    if pw != nil { self.doc.password = pw }
                    self.sendDoc(reload: true)
                }
                self.emit(["type": "saved", "path": dst.path, "name": dst.lastPathComponent, "bytes": PDFs.fileSize(dst), "locked": pw != nil,
                           "close": (b["close"] as? Bool) ?? false, "compress": (b["compress"] as? Bool) ?? false])
                if (b["close"] as? Bool) == true { DispatchQueue.main.async { self.window?.close() } }
                if (b["compress"] as? Bool) == true { DispatchQueue.main.async { self.onCompress?(dst) } }
            } catch { self.fail(error, "save"); self.emit(["type": "busyDone"]) }
        }
    }

    /// 列印（⌘P）：照目前的樣子存一份暫存，交給系統的列印面板
    private func printDoc(_ spec: [String: Any]) {
        emit(["type": "busy", "text": L("準備列印…", "Preparing to print…")])
        doc.q.async {
            let tmp = self.doc.work.appendingPathComponent("print-\(UUID().uuidString.prefix(6)).pdf")
            do { try self.doc.compose(spec, to: tmp, password: nil) } catch { self.fail(error, "print"); self.emit(["type": "busyDone"]); return }
            self.emit(["type": "busyDone"])
            DispatchQueue.main.async {
                guard !self.isTest, let d = PDFDocument(url: tmp), let w = self.window else { if self.isTest { print("PRINT \(tmp.lastPathComponent)") }; return }
                let info = NSPrintInfo.shared.copy() as! NSPrintInfo
                info.jobDisposition = .spool
                guard let op = d.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
                op.jobTitle = PDFs.stem(self.doc.original)
                op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
            }
        }
    }

    /// 整份文件的工具（匯出成 Word…、翻譯、摘要、比較）：先照目前的樣子存一份暫存，再交給工具引擎
    private func runDocTool(_ b: [String: Any]) {
        guard let tool = b["tool"] as? String, let spec = b["spec"] as? [String: Any] else { return }
        let cancel = ToolCancel(); busy = cancel
        emit(["type": "busy", "text": (b["label"] as? String) ?? L("處理中…", "Working…")])
        var extra: [URL] = []
        if tool == "compare" {
            let p = NSOpenPanel(); p.allowedContentTypes = [.pdf]; p.prompt = L("跟這份比", "Compare")
            p.message = L("選另一版（舊的或新的都可以）", "Choose the other version")
            guard p.runModal() == .OK, let u = p.url else { busy = nil; emit(["type": "busyDone"]); return }
            extra = [u]
        }
        doc.q.async {
            let src = self.doc.work.appendingPathComponent("run-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            let tmp = src.appendingPathComponent(PDFs.stem(self.doc.original) + ".pdf")
            do { try self.doc.compose(spec, to: tmp, password: nil) } catch { self.fail(error, tool); self.emit(["type": "busyDone"]); self.busy = nil; return }
            let inputs = tool == "compare" ? [extra[0], tmp] : [tmp]
            let dest = self.saveDir()
            let r = Tools.run(tool, inputs: inputs, options: (b["options"] as? [String: Any]) ?? [:], dest: dest,
                              progress: { t, f in self.emit(["type": "progress", "text": t, "frac": f]) }, cancel: cancel)
            self.busy = nil
            switch r {
            case .success(let res):
                for o in res.outputs { Prefs.remember(["name": o.lastPathComponent, "out": o.path, "before": 0, "after": PDFs.fileSize(o), "at": Date().timeIntervalSince1970, "tool": tool]) }
                self.emit(["type": "ran", "tool": tool, "ok": true, "outputs": res.outputs.map { ["path": $0.path, "name": $0.lastPathComponent] }, "notes": res.notes, "text": res.text ?? ""])
            case .failure(let e):
                self.emit(["type": "ran", "tool": tool, "ok": false, "error": e.text, "stopped": cancel.isCancelled])
            }
            try? FileManager.default.removeItem(at: src)
        }
    }

    // MARK: 自訂網址：頁面的圖、用到的圖片

    func start(_ task: WKURLSchemeTask) {
        guard let url = task.request.url, let host = url.host else { task.didFailWithError(URLError(.badURL)); return }
        let key = ObjectIdentifier(task)
        live.insert(key)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = url.lastPathComponent
        doc.q.async {
            var data: Data?, mime = "image/jpeg"
            let parts = url.pathComponents.filter { $0 != "/" }
            switch host {
            case "page":
                let w = CGFloat(Double(q.first { $0.name == "w" }?.value ?? "") ?? 800)
                if let x = q.first(where: { $0.name == "x" })?.value, !x.isEmpty { data = self.doc.renderMods(id, width: w, mods: x) }   // 改字、搬圖中的頁：先真的拿掉再畫
                else { data = self.doc.render(id, width: w, annots: q.first(where: { $0.name == "a" })?.value == "1") }
            case "ximg":
                if parts.count >= 2, let k = Int(parts[1]) { data = self.doc.ximgPNG(parts[0], k); mime = "image/png" }
            case "ann":
                if parts.count >= 2, let k = Int(parts[1]) { data = self.doc.annotationPNG(parts[0], k); mime = "image/png" }
            case "img":
                if let u = self.doc.images[id] {
                    if u.pathExtension.lowercased() == "pdf", let d = PDFDocument(url: u), PDFs.usable(d), let p = d.page(at: 0) {
                        let img = p.thumbnail(of: NSSize(width: 1200, height: 1200), for: .cropBox)
                        if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) { data = rep.representation(using: .png, properties: [:]); mime = "image/png" }
                    } else {
                        data = try? Data(contentsOf: u)
                        mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "image/png"
                        if ["heic", "heif", "tif", "tiff"].contains(u.pathExtension.lowercased()), let (img, _) = Convert.loadImage(u) { data = Raster.encode(img, type: .png); mime = "image/png" }
                    }
                }
            default: break
            }
            DispatchQueue.main.async {
                guard self.live.contains(key) else { return }
                self.live.remove(key)
                guard let data else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
                task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            }
        }
    }
    func stop(_ task: WKURLSchemeTask) { live.remove(ObjectIdentifier(task)) }

    func webView(_ webView: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = a.request.url, u.scheme == "https" || u.scheme == "http" { NSWorkspace.shared.open(u); decisionHandler(.cancel); return }
        decisionHandler(a.navigationType == .other ? .allow : .cancel)
    }
}

// Pdf/img 用 PDF 當圖片（例：公司章是 PDF）：Convert.loadImage 讀不了 PDF，這裡補一個
extension Convert {
    static func loadAnyImage(_ u: URL) -> CGImage? {
        if u.pathExtension.lowercased() == "pdf", let d = PDFDocument(url: u), PDFs.usable(d), let p = d.page(at: 0) {
            let img = p.thumbnail(of: NSSize(width: 2400, height: 2400), for: .cropBox)
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return Convert.loadImage(u)?.0
    }
}
