// ToolsLayout.swift — 讀出頁面上的字與位置，轉成 PowerPoint、Excel、Markdown
//
// PDF → PPT：每頁一張投影片。背景＝Ghostscript 畫的「拿掉字的頁面」（圖、底色、線條），字＝照原位置放成可以編輯的文字框，
// 看起來跟原頁一樣、字又能改。PDF → Excel：每頁一張工作表，字照列、照欄位的間距切成格子，數字存成數字。
// PDF → Markdown：照字的大小分出標題、條列、段落。掃描檔先辨識文字。
// Office 檔（.pptx／.xlsx）是一包 XML 用 zip 壓起來：這裡只寫最小、合格的那幾個檔（PowerPoint、Keynote、Excel、Numbers 都打得開）。
import AppKit
import Foundation
import PDFKit

/// macOS 的 PDFKit 讀字級（attributedString）時會在 stderr 印一堆除錯字（attributedStringScaled…）：
/// 包起來的那一段暫時把 stderr 接到 /dev/null，命令列才乾淨（呼叫的程式讀得到真正的訊息）
enum Quiet {
    private static let lock = NSLock()
    static func stderr<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        fflush(Darwin.stderr)
        let saved = dup(2), null = open("/dev/null", O_WRONLY)
        if saved >= 0, null >= 0 { dup2(null, 2) }
        defer {
            fflush(Darwin.stderr)
            if saved >= 0 { dup2(saved, 2); close(saved) }
            if null >= 0 { close(null) }
        }
        return body()
    }
}

enum TextMap {
    struct Glyph { let s: String; let r: CGRect?; let line: Int }      // r：顯示方向、原點左下；空白沒有框
    struct Line { var text: String; var rect: CGRect; var size: CGFloat; var glyphs: [Glyph] }
    struct Para { var text: String; var rect: CGRect; var size: CGFloat; var lines: Int }

    /// 一頁的字，照 macOS 抽字的順序（本來就一行一行、照閱讀順序）；line＝第幾行。空白留著（沒有框），換行不算字
    static func glyphs(_ p: PDFPage) -> [Glyph] {
        let s = PDFs.text(p) as NSString
        guard s.length > 0 else { return [] }
        var out: [Glyph] = []
        out.reserveCapacity(s.length)
        var i = 0, line = 0
        while i < s.length {
            let r = s.rangeOfComposedCharacterSequence(at: i)
            let ch = s.substring(with: r)
            if ch.rangeOfCharacter(from: .newlines) != nil { line += 1 }
            else if ch.trimmingCharacters(in: .whitespaces).isEmpty { out.append(Glyph(s: " ", r: nil, line: line)) }
            else {
                let b = p.characterBounds(at: i)
                out.append(Glyph(s: ch, r: (b.width > 0 && b.height > 0) ? Overlay.map(b, p) : nil, line: line))
            }
            i = r.location + r.length
        }
        return out
    }

    /// 一頁的行：用 macOS 自己分的行（PDFKit 的 selectionsByLine：框準、表格的格會各自一行、字級讀得到）
    static func lines(_ p: PDFPage) -> [Line] {
        guard let all = p.selection(for: p.bounds(for: .cropBox)) else { return [] }
        return Quiet.stderr { lines(all, p) }
    }
    private static func lines(_ all: PDFSelection, _ p: PDFPage) -> [Line] {
        var out: [Line] = []
        for l in all.selectionsByLine() {
            let text = PDFs.fixRadicals(l.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let b = l.bounds(for: p)
            guard !text.isEmpty, b.width > 0, b.height > 0 else { continue }
            let rect = Overlay.map(b, p)
            var size = rect.height * 0.8
            if let a = l.attributedString, a.length > 0, let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
               f.pointSize > 1, abs(f.pointSize - rect.height * 0.8) < rect.height { size = f.pointSize }
            out.append(Line(text: text, rect: rect, size: size, glyphs: []))
        }
        return out
    }

    static func isLatin(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.value < 0x2E80 } }

    /// 行開頭是條列或編號（•、-、1.、(1)、一、、①）
    static func startsItem(_ s: String) -> Bool {
        s.range(of: #"^([•‧·●○▪■◆◇►▶✓✔\-–—*]|[(（]?\d{1,2}[\.\)）、]|[(（]?[一二三四五六七八九十]{1,3}[、．.）)]|[①-⑳])"#, options: .regularExpression) != nil
    }

    /// 行併成段落：上下間距小、左緣對齊（或置中）、字一樣大的接在一起。
    /// 上一行沒寫到欄的右緣（下一行開頭的字明明放得下）＝段落在那裡結束；條列、編號開頭另起一段。
    /// context：整頁的行（用來量「這一欄的右緣」）；預設就是 ls
    static func paragraphs(_ ls: [Line], context: [Line]? = nil) -> [Para] {
        let all = context ?? ls
        func colRight(_ l: Line) -> CGFloat {          // 字差不多大、左右有重疊的行裡最靠右的
            var r = l.rect.maxX
            for o in all where abs(o.size - l.size) <= max(1, l.size * 0.2) && o.rect.minX < l.rect.maxX && l.rect.minX < o.rect.maxX { r = max(r, o.rect.maxX) }
            return r
        }
        func endedEarly(_ p: Line, _ next: Line) -> Bool {
            let room = colRight(p) - p.rect.maxX
            guard let c0 = next.text.first else { return false }
            if !isLatin(String(c0)) { return room > p.size * 2.5 }                          // 中日韓：差兩個字以上
            let word = next.text.prefix { !$0.isWhitespace && isLatin(String($0)) }
            let perChar = next.rect.width / CGFloat(max(1, next.text.count))
            return room > CGFloat(word.count + 1) * perChar + p.size * 0.5              // 英文：下一行第一個字放得下卻換行了
        }
        var out: [Para] = []
        var cur: Para?
        var lastLine: Line?
        for l in ls {                                                    // 照閱讀順序（多欄的版面才不會兩欄交錯）
            if var c = cur, let p = lastLine {
                let gap = p.rect.minY - l.rect.maxY
                let sameSize = abs(p.size - l.size) <= max(1, p.size * 0.18)
                let aligned = abs(p.rect.minX - l.rect.minX) <= max(4, p.size * 1.5) || abs(p.rect.midX - l.rect.midX) <= p.size
                if gap >= -p.size * 0.3, gap <= p.size * 0.9, sameSize, aligned, !startsItem(l.text), !endedEarly(p, l) {
                    let join = isLatin(String(c.text.suffix(1))) && isLatin(String(l.text.prefix(1))) ? " " : ""
                    c.text += join + l.text; c.rect = c.rect.union(l.rect); c.lines += 1
                    cur = c; lastLine = l; continue
                }
                out.append(c)
            }
            cur = Para(text: l.text, rect: l.rect, size: l.size, lines: 1); lastLine = l
        }
        if let c = cur { out.append(c) }
        return out
    }

    // MARK: 表格

    struct Table { var rows: [[String]]; var rect: CGRect }
    enum Block { case para(Para), table(Table) }

    /// 同一列：閱讀順序上相鄰、上下重疊的行（表格的一列、左右對齊的頁首頁尾）；每列照左到右
    static func rows(_ ls: [Line]) -> [[Line]] {
        var out: [[Line]] = []
        for l in ls {
            if let f = out.last?.first, abs(f.rect.midY - l.rect.midY) <= max(2, min(f.rect.height, l.rect.height) * 0.5) { out[out.count - 1].append(l) }
            else { out.append([l]) }
        }
        return out.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// 一頁切成段落與表格（照閱讀順序）。連續兩列以上、每列兩格以上＝表格；夾在中間只有一格的列也算
    static func blocks(_ ls: [Line]) -> [Block] {
        let rs = rows(ls)
        var out: [Block] = [], pending: [Line] = []
        func flush() { if !pending.isEmpty { out += paragraphs(pending, context: ls).map { .para($0) }; pending = [] } }
        var i = 0
        while i < rs.count {
            var j = i, multi = 0
            while j < rs.count {
                if rs[j].count >= 2 { multi += 1; j += 1; continue }
                if j > i, j + 1 < rs.count, rs[j + 1].count >= 2, rs[j][0].text.count <= 40 { j += 1; continue }
                break
            }
            if multi >= 2 {
                flush()
                out.append(.table(table(Array(rs[i..<j]))))
                i = j
            } else {
                pending += rs[i]; i += 1
            }
        }
        flush()
        return out
    }

    /// 表格的欄：先看格子數最多的那幾列（每一欄都有字，照左到右就是第 1、2、3…欄），每欄的範圍＝那幾列同一格的聯集；
    /// 其他列的格子放到重疊最多（沒重疊就最近）的那一欄。表頭靠左、數字靠右也對得上——不靠格子之間有沒有重疊
    static func table(_ rs: [[Line]]) -> Table {
        let n = rs.map(\.count).max() ?? 0
        var cols = Array(repeating: (lo: CGFloat.greatestFiniteMagnitude, hi: -CGFloat.greatestFiniteMagnitude), count: n)
        for row in rs where row.count == n {
            for (k, c) in row.enumerated() { cols[k] = (min(cols[k].lo, c.rect.minX), max(cols[k].hi, c.rect.maxX)) }
        }
        if n > 1 { for k in 1..<n where cols[k].lo < cols[k - 1].hi { let mid = (cols[k].lo + cols[k - 1].hi) / 2; cols[k - 1].hi = mid; cols[k].lo = mid } }
        // 重疊的寬度；沒重疊就是負的距離（越近越大）
        func score(_ k: Int, _ r: CGRect) -> CGFloat { min(cols[k].hi, r.maxX) - max(cols[k].lo, r.minX) }
        var grid: [[String]] = []
        for row in rs {
            var line = Array(repeating: "", count: n)
            if row.count == n { for (k, c) in row.enumerated() { line[k] = c.text } }
            else {
                for c in row {
                    var k = (0..<n).max(by: { score($0, c.rect) < score($1, c.rect) }) ?? 0
                    while k < n - 1, !line[k].isEmpty { k += 1 }
                    line[k] = line[k].isEmpty ? c.text : line[k] + " " + c.text
                }
            }
            grid.append(line)
        }
        return Table(rows: grid, rect: rs.flatMap { $0 }.reduce(CGRect.null) { $0.union($1.rect) })
    }

    /// 掃描頁：辨識出來的行（由上而下、同一列由左而右）
    static func ocrLines(_ p: PDFPage, dpi: CGFloat = 250) -> [Line] {
        let sz = Overlay.displaySize(p)
        guard let img = Raster.page(p, dpi: dpi, maxSide: 5000) else { return [] }
        let ls = OCR.lines(in: img).map { o -> Line in
            let r = CGRect(x: o.box.minX * sz.width, y: o.box.minY * sz.height, width: o.box.width * sz.width, height: o.box.height * sz.height)
            return Line(text: o.text, rect: r, size: r.height * 0.8, glyphs: [])
        }.sorted { $0.rect.maxY > $1.rect.maxY }
        var rows: [[Line]] = []
        for l in ls {
            if let f = rows.last?.first, abs(f.rect.midY - l.rect.midY) <= min(f.rect.height, l.rect.height) * 0.5 { rows[rows.count - 1].append(l) }
            else { rows.append([l]) }
        }
        return rows.flatMap { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }
}

// MARK: - 最小的 Office 檔（zip 起來的 XML）

enum OOXML {
    static func esc(_ s: String) -> String {
        var o = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": o += "&amp;"; case "<": o += "&lt;"; case ">": o += "&gt;"; case "\"": o += "&quot;"
            default: if u.value < 0x20 && u != "\t" && u != "\n" { continue }; o.unicodeScalars.append(u)
            }
        }
        return o
    }
    /// 資料夾內容 zip 成一個檔（不含資料夾本身、不帶 macOS 的附加資訊）
    static func zip(_ dir: URL, to out: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-X", "-r", out.path, "."]
        p.currentDirectoryURL = dir
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, PDFs.fileSize(out) > 0 else { throw ToolError.msg(L("打包 Office 檔失敗", "Couldn’t package the Office file")) }
    }
    static func put(_ s: String, _ dir: URL, _ path: String) throws {
        let u = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + s).write(to: u, atomically: true, encoding: .utf8)
    }
    static let nsP = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static let theme = """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Slimly"><a:themeElements>
    <a:clrScheme name="Slimly"><a:dk1><a:srgbClr val="1E2223"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="2B2D33"/></a:dk2><a:lt2><a:srgbClr val="EEEFF2"/></a:lt2>
    <a:accent1><a:srgbClr val="003CFF"/></a:accent1><a:accent2><a:srgbClr val="FFC814"/></a:accent2><a:accent3><a:srgbClr val="5C6466"/></a:accent3><a:accent4><a:srgbClr val="8A9294"/></a:accent4><a:accent5><a:srgbClr val="DFE6E6"/></a:accent5><a:accent6><a:srgbClr val="2B2D33"/></a:accent6>
    <a:hlink><a:srgbClr val="003CFF"/></a:hlink><a:folHlink><a:srgbClr val="5C6466"/></a:folHlink></a:clrScheme>
    <a:fontScheme name="Slimly"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface="PingFang TC"/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface="PingFang TC"/><a:cs typeface=""/></a:minorFont></a:fontScheme>
    <a:fmtScheme name="Slimly"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
    <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>
    </a:themeElements></a:theme>
    """
}

enum Layout {
    static let emu: CGFloat = 12700                                       // 1 pt＝12700 EMU

    /// 每頁「拿掉字的背景」（Ghostscript -dFILTERTEXT）畫成 JPEG；回傳每頁的檔（沒有就 nil）
    static func backgrounds(_ src: URL, pages: Int, dpi: Int, work: URL) -> [URL?] {
        let dir = work.appendingPathComponent("bg-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = GS.run(["-sDEVICE=jpeg", "-dJPEGQ=85", "-r\(dpi)", "-dFILTERTEXT", "-dUseCropBox", "-dNOPAUSE", "-dBATCH", "-dSAFER",
                    "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4", "-o", dir.appendingPathComponent("p-%04d.jpg").path, src.path], work: work)
        return (1...max(1, pages)).map { i in
            let u = dir.appendingPathComponent(String(format: "p-%04d.jpg", i))
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
    }

    // MARK: PDF → PowerPoint

    static func pdfToPPT(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            let n = d.pageCount
            r.progress(L("畫背景", "Rendering backgrounds"), 0.05)
            let bgs = backgrounds(u, pages: n, dpi: 150, work: r.work)
            let pkg = r.tmp("pptx-\(res.outputs.count)")
            let first = Overlay.displaySize(d.page(at: 0)!)
            let cx = Int(first.width * emu), cy = Int(first.height * emu)
            var types = "", presRels = "", sldIds = ""
            var editable = 0
            for i in 0..<n {
                if r.isCancelled { break }
                r.progress(L("第 \(i + 1)／\(n) 張投影片", "Slide \(i + 1)/\(n)"), 0.1 + 0.85 * Double(i) / Double(n))
                guard let p = d.page(at: i) else { continue }
                let sz = Overlay.displaySize(p)
                let kx = CGFloat(cx) / sz.width, ky = CGFloat(cy) / sz.height
                let hasText = OCR.hasText(p)
                // 背景：有字的頁用「拿掉字的背景」；掃描頁（字在圖裡）直接用整頁的圖
                var bgData: Data?
                if hasText, let b = bgs[i] { bgData = try? Data(contentsOf: b) }
                if bgData == nil, let img = Raster.page(p, dpi: 150) { bgData = Raster.encode(img, quality: 0.85) }
                if let bgData { try FileManager.default.createDirectory(at: pkg.appendingPathComponent("ppt/media"), withIntermediateDirectories: true)
                    try bgData.write(to: pkg.appendingPathComponent("ppt/media/image\(i + 1).jpeg")) }
                var shapes = ""
                if bgData != nil {
                    shapes += "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Page \(i + 1)\"/><p:cNvPicPr><a:picLocks noGrp=\"1\" noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
                }
                if hasText {
                    var sid = 3
                    for para in TextMap.paragraphs(TextMap.lines(p)) {
                        let x = Int(para.rect.minX * kx), y = Int((sz.height - para.rect.maxY) * ky)
                        let w = Int(max(para.rect.width * 1.04, para.size) * kx), h = Int(max(para.rect.height, para.size) * ky)
                        let pt = Int((para.size * ky / emu * 100).rounded())
                        shapes += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(sid)\" name=\"Text \(sid)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"
                        shapes += "<p:txBody><a:bodyPr wrap=\"square\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" rtlCol=\"0\"><a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:r><a:rPr lang=\"zh-TW\" sz=\"\(max(600, pt))\" dirty=\"0\"><a:solidFill><a:srgbClr val=\"1E2223\"/></a:solidFill><a:latin typeface=\"Helvetica Neue\"/><a:ea typeface=\"PingFang TC\"/></a:rPr><a:t>\(OOXML.esc(para.text))</a:t></a:r></a:p></p:txBody></p:sp>"
                        sid += 1; editable += 1
                    }
                }
                try OOXML.put("<p:sld \(OOXML.nsP)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>", pkg, "ppt/slides/slide\(i + 1).xml")
                try OOXML.put("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(OOXML.rel)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" + (bgData != nil ? "<Relationship Id=\"rId2\" Type=\"\(OOXML.rel)/image\" Target=\"../media/image\(i + 1).jpeg\"/>" : "") + "</Relationships>", pkg, "ppt/slides/_rels/slide\(i + 1).xml.rels")
                types += "<Override PartName=\"/ppt/slides/slide\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
                presRels += "<Relationship Id=\"rId\(i + 3)\" Type=\"\(OOXML.rel)/slide\" Target=\"slides/slide\(i + 1).xml\"/>"
                sldIds += "<p:sldId id=\"\(256 + i)\" r:id=\"rId\(i + 3)\"/>"
            }
            try OOXML.put("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>\(types)</Types>", pkg, "[Content_Types].xml")
            try OOXML.put("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(OOXML.rel)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>", pkg, "_rels/.rels")
            try OOXML.put("<p:presentation \(OOXML.nsP)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(sldIds)</p:sldIdLst><p:sldSz cx=\"\(cx)\" cy=\"\(cy)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>", pkg, "ppt/presentation.xml")
            try OOXML.put("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(OOXML.rel)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/><Relationship Id=\"rId2\" Type=\"\(OOXML.rel)/theme\" Target=\"theme/theme1.xml\"/>\(presRels)</Relationships>", pkg, "ppt/_rels/presentation.xml.rels")
            try OOXML.put("<p:sldMaster \(OOXML.nsP)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>", pkg, "ppt/slideMasters/slideMaster1.xml")
            try OOXML.put("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(OOXML.rel)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(OOXML.rel)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>", pkg, "ppt/slideMasters/_rels/slideMaster1.xml.rels")
            try OOXML.put("<p:sldLayout \(OOXML.nsP) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>", pkg, "ppt/slideLayouts/slideLayout1.xml")
            try OOXML.put("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(OOXML.rel)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>", pkg, "ppt/slideLayouts/_rels/slideLayout1.xml.rels")
            try OOXML.put(OOXML.theme, pkg, "ppt/theme/theme1.xml")
            let tmp = r.tmp("out-\(res.outputs.count).pptx")
            try OOXML.zip(pkg, to: tmp)
            res.outputs.append(try r.place(tmp, like: u, suffix: "", ext: "pptx"))
            res.notes.append(L("\(n) 張投影片、\(editable) 個可以改的文字框；背景是原頁拿掉字的圖", "\(n) slides, \(editable) editable text boxes over the original page art"))
        }
        return res
    }

    // MARK: PDF → Excel

    /// 數字格：1,200,000 → 1200000（顯示成 #,##0）、12.5% → 0.125（顯示成 0.0%）、(300) → -300。
    /// 0 開頭的（電話、編號）、帶幣別的留成文字。回傳（值, 樣式編號）
    static func number(_ t: String) -> (Double, Int)? {
        var s = t.trimmingCharacters(in: .whitespaces), neg = false, pct = false
        if s.hasPrefix("("), s.hasSuffix(")") { neg = true; s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("-") || s.hasPrefix("−") { neg = true; s = String(s.dropFirst()) }
        if s.hasSuffix("%") { pct = true; s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard s.range(of: #"^(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
        if s.count > 1, s.hasPrefix("0"), !s.hasPrefix("0.") { return nil }
        let plain = s.replacingOccurrences(of: ",", with: "")
        guard plain.filter(\.isNumber).count <= 15, var v = Double(plain) else { return nil }
        if neg { v = -v }
        let dec = plain.contains(".")
        if pct { return (v / 100, dec ? 4 : 3) }
        if s.contains(",") { return (v, dec ? 2 : 1) }
        return (v, 0)
    }
    static func cellWidth(_ s: String) -> CGFloat { s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) } }

    static func pdfToExcel(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            let n = d.pageCount
            let pkg = r.tmp("xlsx-\(res.outputs.count)")
            var sheets = "", rels = "", types = "", cellsTotal = 0, tables = 0
            for i in 0..<n {
                r.progress(L("第 \(i + 1)／\(n) 頁", "Page \(i + 1)/\(n)"), Double(i) / Double(n))
                guard let p = d.page(at: i) else { continue }
                let ls = OCR.hasText(p) ? TextMap.lines(p) : TextMap.ocrLines(p, dpi: 300)
                // 段落一格（放 A 欄，字會往右延伸）；表格照欄位排，第一列是字、下面有數字就當表頭（粗體）
                var rows: [[(s: String, bold: Bool)]] = [], widths: [Int: CGFloat] = [:]
                let body = ls.map(\.size).sorted().dropFirst(ls.count / 2).first ?? 10
                for b in TextMap.blocks(ls) {
                    switch b {
                    case .para(let p):
                        rows.append([(p.text, p.lines <= 2 && p.size >= body * 1.2)])
                    case .table(let t):
                        tables += 1
                        let header = !t.rows[0].contains { number($0) != nil } && t.rows.dropFirst().contains { $0.contains { number($0) != nil } }
                        if let last = rows.last, !last.isEmpty { rows.append([]) }
                        for (k, row) in t.rows.enumerated() {
                            rows.append(row.map { ($0, header && k == 0) })
                            for (c, s) in row.enumerated() { widths[c] = max(widths[c] ?? 0, cellWidth(s)) }
                        }
                        rows.append([])
                    }
                }
                while rows.last?.isEmpty == true { rows.removeLast() }
                var xml = ""
                if !widths.isEmpty {
                    xml += "<cols>" + widths.keys.sorted().map { c in "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(Int(min(50, max(9, widths[c]! * 1.1 + 2))))\" customWidth=\"1\"/>" }.joined() + "</cols>"
                }
                xml += "<sheetData>"
                for (ri, row) in rows.enumerated() {
                    xml += "<row r=\"\(ri + 1)\">"
                    for (ci, cell) in row.enumerated() {
                        let t = cell.s.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { continue }
                        let ref = colName(ci) + "\(ri + 1)"
                        if let (v, st) = number(t) {
                            let vs = v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
                            xml += "<c r=\"\(ref)\" s=\"\(st)\"><v>\(vs)</v></c>"
                        } else {
                            xml += "<c r=\"\(ref)\"\(cell.bold ? " s=\"5\"" : "") t=\"inlineStr\"><is><t xml:space=\"preserve\">\(OOXML.esc(t))</t></is></c>"
                        }
                        cellsTotal += 1
                    }
                    xml += "</row>"
                }
                xml += "</sheetData>"
                try OOXML.put("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(OOXML.rel)\">\(xml)</worksheet>", pkg, "xl/worksheets/sheet\(i + 1).xml")
                sheets += "<sheet name=\"\(L("第\(i + 1)頁", "Page \(i + 1)"))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
                rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(OOXML.rel)/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
                types += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            }
            try OOXML.put("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>\(types)</Types>", pkg, "[Content_Types].xml")
            try OOXML.put("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(OOXML.rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>", pkg, "_rels/.rels")
            try OOXML.put("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(OOXML.rel)\"><sheets>\(sheets)</sheets></workbook>", pkg, "xl/workbook.xml")
            try OOXML.put("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)<Relationship Id=\"rId\(n + 1)\" Type=\"\(OOXML.rel)/styles\" Target=\"styles.xml\"/></Relationships>", pkg, "xl/_rels/workbook.xml.rels")
            try OOXML.put("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"12\"/><name val=\"PingFang TC\"/></font><font><b/><sz val=\"12\"/><name val=\"PingFang TC\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"6\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"3\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"4\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"9\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"10\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs></styleSheet>", pkg, "xl/styles.xml")
            guard cellsTotal > 0 else { throw ToolError.msg(L("「\(u.lastPathComponent)」讀不出字", "No text found in “\(u.lastPathComponent)”")) }
            let tmp = r.tmp("out-\(res.outputs.count).xlsx")
            try OOXML.zip(pkg, to: tmp)
            res.outputs.append(try r.place(tmp, like: u, suffix: "", ext: "xlsx"))
            res.notes.append(L("每頁一張工作表、\(tables) 個表格、\(cellsTotal) 格；數字存成數字（千分位、百分比照原樣顯示）。表格線、合併儲存格不會帶過去", "One sheet per page, \(tables) tables, \(cellsTotal) cells; numbers kept as numbers"))
        }
        return res
    }
    static func colName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let m = (n - 1) % 26; s = String(UnicodeScalar(65 + m)!) + s; n = (n - 1) / 26 }
        return s
    }

    // MARK: PDF → Markdown

    static func pdfToMarkdown(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            var md = ""
            var sizes: [CGFloat] = []
            var pages: [[TextMap.Block]] = []
            for i in 0..<d.pageCount {
                r.progress(L("第 \(i + 1)／\(d.pageCount) 頁", "Page \(i + 1)/\(d.pageCount)"), Double(i) / Double(d.pageCount))
                guard let p = d.page(at: i) else { pages.append([]); continue }
                let bs = TextMap.blocks(OCR.hasText(p) ? TextMap.lines(p) : TextMap.ocrLines(p))
                for b in bs { if case .para(let q) = b { sizes.append(q.size) } }
                pages.append(bs)
            }
            let body = sizes.sorted().isEmpty ? 10 : sizes.sorted()[sizes.count / 2]
            func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
            for (i, bs) in pages.enumerated() {
                if i > 0, !bs.isEmpty { md += "\n" }
                var inList = false
                for b in bs {
                    switch b {
                    case .table(let t):
                        if inList { md += "\n"; inList = false }
                        let w = t.rows.first?.count ?? 0
                        guard w > 0 else { continue }
                        md += "| " + t.rows[0].map(cell).joined(separator: " | ") + " |\n"
                        md += "|" + String(repeating: " --- |", count: w) + "\n"
                        for row in t.rows.dropFirst() { md += "| " + row.map(cell).joined(separator: " | ") + " |\n" }
                        md += "\n"
                    case .para(let p):
                        let t = p.text.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { continue }
                        let item = TextMap.startsItem(t) || (p.lines <= 2 && inList && p.size < body * 1.2)
                        if !item, inList { md += "\n"; inList = false }
                        if p.lines <= 2 && p.size >= body * 1.6 { md += "# \(t)\n\n" }
                        else if p.lines <= 2 && p.size >= body * 1.25 { md += "## \(t)\n\n" }
                        else if let f = t.first, "•‧·●○▪■◆◇►▶✓✔-–—*".contains(f) { md += "- " + t.dropFirst().trimmingCharacters(in: .whitespaces) + "\n"; inList = true }
                        else if t.range(of: #"^\d{1,2}[\.\)]\s*"#, options: .regularExpression) != nil { md += t + "\n"; inList = true }
                        else { md += t + "\n\n" }
                    }
                }
                if inList { md += "\n" }
            }
            guard md.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { throw ToolError.msg(L("「\(u.lastPathComponent)」讀不出字", "No text found in “\(u.lastPathComponent)”")) }
            let tmp = r.tmp("out-\(res.outputs.count).md")
            try md.write(to: tmp, atomically: true, encoding: .utf8)
            res.outputs.append(try r.place(tmp, like: u, suffix: "", ext: "md"))
        }
        res.notes.append(L("照字的大小分出標題、條列、段落；表格變成 Markdown 表格", "Headings, lists and paragraphs from text size; tables become Markdown tables"))
        return res
    }
}
