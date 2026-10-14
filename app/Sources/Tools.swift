// Tools.swift — 「所有工具」（2.0）：iLovePDF 那 32 個工具，全部在這台 Mac 上做，不上傳
//
// 做法：同一個引擎給三個入口——app 的「所有工具」頁、命令列 `Slimly --cli <工具> …`、其他程式（叫命令列）。
// 只用這台 Mac 本來就有的東西：PDFKit／Quartz（頁面、疊字、加密）、Vision（OCR）、Translation 與 FoundationModels
// （裝置端翻譯與摘要）、WebKit（網頁轉 PDF）、包內自帶的 Ghostscript（PDF/A、修復、轉 Word、去字背景）、
// 已安裝的 Pages／Keynote／Numbers 或 Microsoft Office（Office 轉 PDF）。
//
// 共同規矩（跟壓縮同一套）：原檔只讀；輸出放原檔旁邊（或設定的資料夾），檔名多一段說明，同名就加號碼，永不覆蓋；
// 暫存在每一次自己的工作夾，做完收掉；看得出對錯的都驗（頁數、畫面、塗黑的字真的搜不到）。
import AppKit
import Foundation
import PDFKit

// MARK: - 規格（介面、命令列、技能都讀這一份）

struct ToolSpec {
    let id: String          // 命令列用的名字
    let cat: String         // organize／optimize／topdf／frompdf／edit／security／ai
    let zh: String, en: String
    let accepts: [String]   // 副檔名；空＝PDF
    let min: Int, max: Int  // 幾份檔
    var name: String { L(zh, en) }
}

enum ToolError: Error {
    case msg(String)
    var text: String { if case .msg(let s) = self { return s }; return "" }
}

struct ToolResult {
    var outputs: [URL] = []
    var text: String? = nil        // 要直接顯示的字（摘要）
    var notes: [String] = []       // 一兩句說明（例：「3 頁塗黑：那幾頁變成圖片，原本的字已刪掉」）
}

/// 選項：畫面送來的 JSON、命令列的 --key value，一律寬鬆讀
struct ToolOptions {
    let raw: [String: Any]
    func str(_ k: String, _ d: String = "") -> String {
        if let s = raw[k] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = raw[k] as? NSNumber { return n.stringValue }
        return d
    }
    func int(_ k: String, _ d: Int) -> Int { Int(str(k)) ?? (raw[k] as? Int) ?? d }
    func dbl(_ k: String, _ d: Double) -> Double { Double(str(k)) ?? d }
    func bool(_ k: String, _ d: Bool = false) -> Bool {
        if let b = raw[k] as? Bool { return b }
        switch str(k).lowercased() { case "1", "true", "yes", "on", "是": return true; case "0", "false", "no", "off", "否": return false; default: return d }
    }
    func has(_ k: String) -> Bool { !str(k).isEmpty }
}

enum Tools {
    static let PDF: [String] = []
    static let IMG = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    static let specs: [ToolSpec] = [
        // 整理 PDF
        ToolSpec(id: "merge",    cat: "organize", zh: "合併 PDF",   en: "Merge PDF",       accepts: PDF, min: 2, max: 500),
        ToolSpec(id: "split",    cat: "organize", zh: "拆分 PDF",   en: "Split PDF",       accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "remove",   cat: "organize", zh: "移除頁面",   en: "Remove pages",    accepts: PDF, min: 1, max: 1),
        ToolSpec(id: "extract",  cat: "organize", zh: "提取頁面",   en: "Extract pages",   accepts: PDF, min: 1, max: 1),
        ToolSpec(id: "organize", cat: "organize", zh: "整理 PDF",   en: "Organize PDF",    accepts: PDF, min: 1, max: 1),
        ToolSpec(id: "scan",     cat: "organize", zh: "掃描為 PDF", en: "Scan to PDF",     accepts: IMG + ["pdf"], min: 1, max: 200),
        // 優化 PDF
        ToolSpec(id: "compress", cat: "optimize", zh: "壓縮 PDF",   en: "Compress PDF",    accepts: PDF, min: 1, max: 1000),
        ToolSpec(id: "repair",   cat: "optimize", zh: "修復 PDF",   en: "Repair PDF",      accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "ocr",      cat: "optimize", zh: "OCR 文字辨識", en: "OCR PDF",       accepts: PDF, min: 1, max: 50),
        // 轉成 PDF
        ToolSpec(id: "img2pdf",   cat: "topdf", zh: "圖片轉 PDF",   en: "JPG to PDF",      accepts: IMG, min: 1, max: 500),
        ToolSpec(id: "word2pdf",  cat: "topdf", zh: "Word 轉 PDF",  en: "Word to PDF",     accepts: ["docx", "doc", "rtf", "odt", "txt", "pages", "md"], min: 1, max: 50),
        ToolSpec(id: "ppt2pdf",   cat: "topdf", zh: "PPT 轉 PDF",   en: "PowerPoint to PDF", accepts: ["pptx", "ppt", "key", "odp"], min: 1, max: 50),
        ToolSpec(id: "excel2pdf", cat: "topdf", zh: "Excel 轉 PDF", en: "Excel to PDF",    accepts: ["xlsx", "xls", "numbers", "csv", "ods"], min: 1, max: 50),
        ToolSpec(id: "html2pdf",  cat: "topdf", zh: "網頁轉 PDF",   en: "HTML to PDF",     accepts: ["html", "htm", "webarchive"], min: 0, max: 50),
        // 從 PDF 轉出
        ToolSpec(id: "pdf2img",   cat: "frompdf", zh: "PDF 轉圖片",      en: "PDF to JPG",        accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "pdf2word",  cat: "frompdf", zh: "PDF 轉 Word",     en: "PDF to Word",       accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "pdf2ppt",   cat: "frompdf", zh: "PDF 轉 PPT",      en: "PDF to PowerPoint", accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "pdf2excel", cat: "frompdf", zh: "PDF 轉 Excel",    en: "PDF to Excel",      accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "pdfa",      cat: "frompdf", zh: "PDF 轉 PDF/A",    en: "PDF to PDF/A",      accepts: PDF, min: 1, max: 50),
        // 編輯
        ToolSpec(id: "rotate",    cat: "edit", zh: "旋轉 PDF",   en: "Rotate PDF",        accepts: PDF, min: 1, max: 200),
        ToolSpec(id: "number",    cat: "edit", zh: "加頁碼",     en: "Add page numbers",  accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "watermark", cat: "edit", zh: "加浮水印",   en: "Add watermark",     accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "crop",      cat: "edit", zh: "裁切 PDF",   en: "Crop PDF",          accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "edit",      cat: "edit", zh: "編輯 PDF",   en: "Edit PDF",          accepts: PDF, min: 1, max: 1),
        ToolSpec(id: "forms",     cat: "edit", zh: "填表單",     en: "PDF forms",         accepts: PDF, min: 1, max: 1),
        // 安全性
        ToolSpec(id: "unlock",  cat: "security", zh: "PDF 解鎖",   en: "Unlock PDF",   accepts: PDF, min: 1, max: 1),
        ToolSpec(id: "protect", cat: "security", zh: "PDF 加密",   en: "Protect PDF",  accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "sign",    cat: "security", zh: "簽名",       en: "Sign PDF",     accepts: PDF, min: 1, max: 1),
        ToolSpec(id: "redact",  cat: "security", zh: "塗黑個資",   en: "Redact PDF",   accepts: PDF, min: 1, max: 50),
        ToolSpec(id: "compare", cat: "security", zh: "比較兩版",   en: "Compare PDF",  accepts: PDF, min: 2, max: 2),
        // 轉檔（2.1）：一個入口，看放進來的是什麼決定怎麼轉（PDF → Word／PPT／Excel／圖片／Markdown／PDF-A；其他 → PDF）
        ToolSpec(id: "convert", cat: "convert", zh: "轉檔", en: "Convert", accepts: ["pdf"] + IMG + ["docx", "doc", "rtf", "odt", "txt", "pages", "md", "pptx", "ppt", "key", "odp", "xlsx", "xls", "numbers", "csv", "ods", "html", "htm", "webarchive"], min: 0, max: 500),
        // 裝置端智慧（不上網）
        ToolSpec(id: "summarize", cat: "ai", zh: "摘要",           en: "Summarize",       accepts: PDF, min: 1, max: 1),
        ToolSpec(id: "translate", cat: "ai", zh: "翻譯",           en: "Translate PDF",   accepts: PDF, min: 1, max: 1),
        ToolSpec(id: "markdown",  cat: "ai", zh: "PDF 轉 Markdown", en: "PDF to Markdown", accepts: PDF, min: 1, max: 20),
    ]
    static func spec(_ id: String) -> ToolSpec? { specs.first { $0.id == id } }

    /// 跑一個工具。在呼叫的這條執行緒上做完（app 放背景佇列；命令列在主執行緒）
    static func run(_ id: String, inputs: [URL], options: [String: Any], dest: URL?,
                    progress: ((String, Double) -> Void)? = nil, cancel: ToolCancel? = nil) -> Result<ToolResult, ToolError> {
        guard let spec = spec(id) else { return .failure(.msg(L("沒有這個工具：\(id)", "No such tool: \(id)"))) }
        let urlOK = (id == "html2pdf" || id == "convert") && ToolOptions(raw: options).has("url")
        if (inputs.count < spec.min || (id == "convert" && inputs.isEmpty)) && !urlOK {
            return .failure(.msg(spec.min >= 2 ? L("至少要 \(spec.min) 份檔", "Needs at least \(spec.min) files") : L("先放一份檔進來", "Add a file first")))
        }
        let run = ToolRun(id: id, inputs: inputs, options: ToolOptions(raw: options), dest: dest, progress: progress, cancel: cancel)
        defer { run.cleanup() }
        do {
            var r: ToolResult
            switch id {
            case "merge": r = try PageTools.merge(run)
            case "split": r = try PageTools.split(run)
            case "remove": r = try PageTools.remove(run)
            case "extract": r = try PageTools.extract(run)
            case "organize": r = try PageTools.organize(run)
            case "rotate": r = try PageTools.rotate(run)
            case "crop": r = try PageTools.crop(run)
            case "number": r = try Stamp.pageNumbers(run)
            case "watermark": r = try Stamp.watermark(run)
            case "edit": r = try Stamp.text(run)
            case "sign": r = try Stamp.sign(run)
            case "forms": r = try Security.forms(run)
            case "unlock": r = try Security.unlock(run)
            case "protect": r = try Security.protect(run)
            case "redact": r = try Redact.run(run)
            case "compare": r = try Compare.run(run)
            case "repair": r = try Convert.repair(run)
            case "pdfa": r = try Convert.pdfa(run)
            case "img2pdf": r = try Convert.imagesToPDF(run)
            case "pdf2img": r = try Convert.pdfToImages(run)
            case "html2pdf": r = try Convert.htmlToPDF(run)
            case "word2pdf", "ppt2pdf", "excel2pdf": r = try Office.toPDF(run)
            case "pdf2word": r = try Convert.pdfToWord(run)
            case "pdf2ppt": r = try Layout.pdfToPPT(run)
            case "pdf2excel": r = try Layout.pdfToExcel(run)
            case "markdown": r = try Layout.pdfToMarkdown(run)
            case "ocr": r = try OCR.run(run)
            case "summarize", "translate":
                guard #available(macOS 26.0, *) else { return .failure(.msg(L("摘要、翻譯要 macOS 26 以上（裝置端的模型）", "Summary and translation need macOS 26 or later"))) }
                r = id == "summarize" ? try Brain.summarize(run) : try Brain.translate(run)
            case "scan": r = try Scan.run(run)
            case "convert": r = try Convert.any(run)
            case "compress":
                return .failure(.msg(L("壓縮在主畫面：把檔拖進 Slimly 視窗就好（命令列：Slimly --cli 檔案）", "Compression is the main screen: drop files on the Slimly window (CLI: Slimly --cli files)")))
            default: return .failure(.msg(L("沒有這個工具：\(id)", "No such tool: \(id)")))
            }
            if run.isCancelled { return .failure(.msg(L("已停止；原檔都沒動", "Stopped; nothing was changed"))) }
            if r.outputs.isEmpty && r.text == nil { return .failure(.msg(L("沒有產出任何檔", "Nothing was produced"))) }
            return .success(r)
        } catch let e as ToolError {
            return .failure(e)
        } catch {
            return .failure(.msg(error.localizedDescription))
        }
    }
}

// MARK: - 一次執行：工作夾、放檔、進度

/// 「停止」：畫面按停止＝這個旗子立起來，工具在頁與頁之間看到就收手（Ghostscript 那段直接結束行程）
final class ToolCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func cancel() { lock.lock(); v = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

final class ToolRun {
    let id: String
    let inputs: [URL]
    let opt: ToolOptions
    let destOverride: URL?
    let work: URL
    let token: ToolCancel
    private let onProgress: ((String, Double) -> Void)?

    init(id: String, inputs: [URL], options: ToolOptions, dest: URL?, progress: ((String, Double) -> Void)?, cancel: ToolCancel? = nil) {
        self.id = id; self.inputs = inputs; self.opt = options; self.destOverride = dest; self.onProgress = progress
        token = cancel ?? ToolCancel()
        work = FileManager.default.temporaryDirectory.appendingPathComponent("Slimly-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: work) }
    func cancel() { token.cancel() }
    var isCancelled: Bool { token.isCancelled }
    func progress(_ text: String, _ frac: Double) { onProgress?(text, max(0, min(1, frac))) }

    /// 工作夾裡的一個暫存路徑
    func tmp(_ name: String) -> URL { work.appendingPathComponent(name) }

    /// 放到最後的位置：跟 input 同一夾（或設定／--dest 的資料夾），「檔名＋說明.副檔名」，同名加號碼，永不覆蓋
    func place(_ tmp: URL, like input: URL?, suffix: String, ext: String, stem: String? = nil) throws -> URL {
        let dir: URL
        if let d = destOverride { dir = d }
        else if let i = input { dir = Compressor.destination(for: i, override: nil).dir }
        else { dir = URL(fileURLWithPath: Prefs.defaultFolder, isDirectory: true) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw ToolError.msg(L("存不進「\(dir.path)」（唯讀或沒有權限）；原檔沒動", "Can’t write to “\(dir.path)”; nothing was changed"))
        }
        let base = stem ?? input.map { $0.deletingPathExtension().lastPathComponent } ?? "Slimly"
        do { return try Files.moveNoClobber(tmp, into: dir, name: base + suffix + "." + ext) }
        catch { throw ToolError.msg(L("存不進「\(dir.path)」：\(error.localizedDescription)", "Couldn’t save to “\(dir.path)”: \(error.localizedDescription)")) }
    }
}

// MARK: - 共用：開檔、頁碼範圍、存檔、驗收

enum PDFs {
    /// 打開 PDF。有密碼的擋下（叫人先用「解鎖」）
    static func open(_ url: URL) throws -> PDFDocument {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ToolError.msg(L("讀不到「\(url.lastPathComponent)」", "Can’t read “\(url.lastPathComponent)”")) }
        guard let d = PDFDocument(url: url), d.pageCount > 0 else {
            throw ToolError.msg(L("「\(url.lastPathComponent)」打不開：不是完整的 PDF（可以先用「修復 PDF」）", "“\(url.lastPathComponent)” isn’t a readable PDF (try Repair PDF)"))
        }
        if d.isLocked { throw ToolError.msg(L("「\(url.lastPathComponent)」有密碼：先用「PDF 解鎖」", "“\(url.lastPathComponent)” is password-protected: unlock it first")) }
        if restricted(d) { throw ToolError.msg(restrictedMsg(url)) }
        return d
    }

    /// 作者設了限制（列印、拷貝、修改…），而且不是用擁有者密碼打開的。重寫這份檔會把限制拿掉，所以公開版一律不動它（跟壓縮同一條規則）
    static func restricted(_ d: PDFDocument) -> Bool {
        guard d.isEncrypted, d.permissionsStatus != .owner else { return false }
        return !(d.allowsPrinting && d.allowsCopying && d.allowsDocumentChanges && d.allowsDocumentAssembly
                 && d.allowsContentAccessibility && d.allowsCommenting && d.allowsFormFieldEntry)
    }
    /// 拿來當素材（當圖片放進別份、比較兩版）可不可以：公開版有作者限制的不行
    static func usable(_ d: PDFDocument) -> Bool {
        return !restricted(d)
    }
    static func restrictedMsg(_ u: URL) -> String {
        L("「\(u.lastPathComponent)」有作者設的限制（列印、拷貝、修改）：要先用「PDF 解鎖」輸入擁有者密碼",
          "“\(u.lastPathComponent)” has restrictions set by its author (print, copy, edit): remove them with the owner password in Unlock PDF first")
    }

    /// 「1-3, 5, 8-」「全部」「單數」「雙數」「最後」→ 0 起算的頁（照寫的順序，可重複）
    static func pages(_ spec: String, count n: Int) throws -> [Int] {
        let s = spec.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "～", with: "-").replacingOccurrences(of: "~", with: "-")
            .replacingOccurrences(of: " ", with: "").lowercased()
        if s.isEmpty || ["all", "全部", "*"].contains(s) { return Array(0..<n) }
        if ["odd", "單數", "奇數"].contains(s) { return stride(from: 0, to: n, by: 2).map { $0 } }
        if ["even", "雙數", "偶數"].contains(s) { return stride(from: 1, to: n, by: 2).map { $0 } }
        var out: [Int] = []
        for part in s.split(separator: ",") {
            let p = String(part)
            func num(_ t: String) throws -> Int {
                if t == "last" || t == "最後" || t == "end" { return n }
                guard let v = Int(t), v >= 1, v <= n else { throw ToolError.msg(L("頁碼「\(t)」不在 1–\(n) 之間", "Page “\(t)” isn’t between 1 and \(n)")) }
                return v
            }
            if let dash = p.firstIndex(of: "-") {
                let a = String(p[..<dash]), b = String(p[p.index(after: dash)...])
                let lo = a.isEmpty ? 1 : try num(a), hi = b.isEmpty ? n : try num(b)
                if lo <= hi { out += Array((lo - 1)...(hi - 1)) } else { out += Array((hi - 1)...(lo - 1)).reversed() }
            } else { out.append(try num(p) - 1) }
        }
        guard !out.isEmpty else { throw ToolError.msg(L("沒看懂要哪幾頁（例：1-3, 5, 8-）", "Couldn’t read the pages (e.g. 1-3, 5, 8-)")) }
        return out
    }

    /// PDFKit 存檔；失敗就講
    static func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any]? = nil) throws {
        let ok = options == nil ? doc.write(to: url) : doc.write(to: url, withOptions: options)
        guard ok, FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.msg(L("存檔失敗（磁碟空間不夠，或這份的結構寫不回去）", "Couldn’t save (disk full, or this file can’t be rewritten)"))
        }
    }

    /// 驗收：打得開、頁數對
    static func verify(_ url: URL, pages: Int? = nil) throws {
        guard let d = PDFDocument(url: url), d.pageCount > 0 else { throw ToolError.msg(L("做出來的檔打不開，沒交出去", "The result didn’t open, so it wasn’t saved")) }
        if let p = pages, d.pageCount != p {
            throw ToolError.msg(L("做出來是 \(d.pageCount) 頁、應該 \(p) 頁，沒交出去", "Result has \(d.pageCount) pages instead of \(p), so it wasn’t saved"))
        }
    }

    /// 新文件，把 src 的第 idx 頁（0 起算）照順序抄過去
    static func pick(_ src: PDFDocument, _ idx: [Int]) -> PDFDocument {
        let d = PDFDocument()
        for i in idx { if let p = src.page(at: i)?.copy() as? PDFPage { d.insert(p, at: d.pageCount) } }
        return d
    }

    /// 整份抄成一份新的文件（頁、文件資訊、書籤）：用來拿掉加密——新文件本來就沒有加密
    static func rebuild(_ src: PDFDocument) -> PDFDocument {
        let out = PDFDocument()
        var map: [ObjectIdentifier: PDFPage] = [:]
        for i in 0..<src.pageCount {
            guard let p = src.page(at: i), let c = p.copy() as? PDFPage else { continue }
            out.insert(c, at: out.pageCount)
            map[ObjectIdentifier(p)] = c
        }
        out.documentAttributes = src.documentAttributes
        func clone(_ o: PDFOutline) -> PDFOutline {
            let n = PDFOutline()
            n.label = o.label
            n.isOpen = o.isOpen
            if let d = o.destination, let pg = d.page, let np = map[ObjectIdentifier(pg)] { n.destination = PDFDestination(page: np, at: d.point) }
            for k in 0..<o.numberOfChildren { if let ch = o.child(at: k) { n.insertChild(clone(ch), at: n.numberOfChildren) } }
            return n
        }
        if let root = src.outlineRoot, root.numberOfChildren > 0 { out.outlineRoot = clone(root) }
        return out
    }

    static func stem(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent }

    /// macOS 用蘋方產生的 PDF，有些字抽出來是「康熙部首」的碼位（小＝U+2F29、口＝U+2F1D），長得一樣、搜尋卻找不到。
    /// 一對一換回一般漢字（長度不變，位置照用）；不用 NFKC（會把中文全形標點也換成半形）
    static func fixRadicals(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var changed = false
        for u in s.unicodeScalars {
            if (0x2E80...0x2FDF).contains(u.value) {
                let m = String(u).precomposedStringWithCompatibilityMapping.unicodeScalars
                if m.count == 1, let f = m.first, f.value <= 0xFFFF { out.append(f); changed = true; continue }
            }
            out.append(u)
        }
        return changed ? String(out) : s
    }
    /// 一頁的文字（已修部首）
    static func text(_ p: PDFPage?) -> String { fixRadicals(p?.string ?? "") }
    static func fileSize(_ u: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0 }

    /// 頁碼寫給人看：「第 1–3 頁」「第 5 頁」
    static func label(_ idx: [Int]) -> String {
        guard let a = idx.first, let b = idx.last else { return "" }
        let contiguous = idx == Array(a...b)
        if idx.count == 1 { return L("第 \(a + 1) 頁", "p\(a + 1)") }
        return contiguous ? L("第 \(a + 1)–\(b + 1) 頁", "pp\(a + 1)-\(b + 1)") : L("\(idx.count) 頁", "\(idx.count) pages")
    }
}

// MARK: - 整理：合併、拆分、移除、提取、整理、旋轉、裁切

enum PageTools {
    /// 合併：照放進來的順序；每一份在書籤裡一筆
    static func merge(_ r: ToolRun) throws -> ToolResult {
        let out = PDFDocument()
        let outline = PDFOutline()
        var total = 0
        for (k, u) in r.inputs.enumerated() {
            r.progress(L("合併 \(k + 1)／\(r.inputs.count)", "Merging \(k + 1)/\(r.inputs.count)"), Double(k) / Double(r.inputs.count))
            let d = try PDFs.open(u)
            let start = out.pageCount
            for i in 0..<d.pageCount { if let p = d.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
            total += d.pageCount
            if let first = out.page(at: start) {
                let item = PDFOutline()
                item.label = PDFs.stem(u)
                item.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: .cropBox).maxY))
                outline.insertChild(item, at: outline.numberOfChildren)
            }
        }
        out.outlineRoot = outline
        let tmp = r.tmp("merge.pdf")
        try PDFs.write(out, to: tmp)
        try PDFs.verify(tmp, pages: total)
        let dst = try r.place(tmp, like: r.inputs[0], suffix: L("（合併 \(r.inputs.count) 份）", " (merged \(r.inputs.count))"), ext: "pdf")
        return ToolResult(outputs: [dst], notes: [L("\(r.inputs.count) 份、共 \(total) 頁；書籤裡每一份一筆", "\(r.inputs.count) files, \(total) pages; one bookmark per file")])
    }

    /// 拆分：mode＝each（每頁一份，預設）／every（每 N 頁）／ranges（照範圍，每段一份）／size（每份 ≤ N MB）
    static func split(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            let n = d.pageCount
            let mode = r.opt.str("mode", r.opt.has("ranges") ? "ranges" : r.opt.has("every") ? "every" : r.opt.has("mb") ? "size" : "each")
            var groups: [[Int]] = []
            switch mode {
            case "every":
                let k = max(1, r.opt.int("every", 1))
                groups = stride(from: 0, to: n, by: k).map { Array($0..<min(n, $0 + k)) }
            case "ranges":
                let spec = r.opt.str("ranges")
                guard !spec.isEmpty else { throw ToolError.msg(L("照範圍拆：要寫範圍（例：1-3, 4-8）", "Split by ranges needs ranges (e.g. 1-3, 4-8)")) }
                for part in spec.replacingOccurrences(of: "，", with: ",").split(separator: ",") { groups.append(try PDFs.pages(String(part), count: n)) }
            case "size":
                let mb = max(1, r.opt.int("mb", Prefs.targetMB > 0 ? Prefs.targetMB : 25))
                switch Splitter.split(u, limit: Int64(mb) * 1024 * 1024, work: r.work, onProgress: { i, k in r.progress(L("存第 \(i)／\(k) 份", "Saving part \(i)/\(k)"), Double(i) / Double(max(1, k))) }) {
                case .success(let parts):
                    let placed = try Splitter.place(parts, dir: r.destOverride ?? Compressor.destination(for: u, override: nil).dir, compressedName: u.lastPathComponent)
                    res.outputs += placed.map(\.url)
                    if placed.contains(where: \.over) { res.notes.append(L("有一頁單頁就超過 \(mb) MB，那一份還是太大", "One page alone is over \(mb) MB")) }
                case .failure(let e): throw ToolError.msg(L("照大小拆不了（\(e)）", "Couldn’t split by size (\(e))"))
                }
                continue
            default:
                groups = (0..<n).map { [$0] }
            }
            guard groups.count > 1 || mode == "ranges" else { throw ToolError.msg(L("「\(u.lastPathComponent)」只有 1 頁，不用拆", "“\(u.lastPathComponent)” has only one page")) }
            for (k, g) in groups.enumerated() {
                if r.isCancelled { break }
                r.progress(L("存第 \(k + 1)／\(groups.count) 份", "Saving part \(k + 1)/\(groups.count)"), Double(k) / Double(groups.count))
                let tmp = r.tmp("split-\(k).pdf")
                try PDFs.write(PDFs.pick(d, g), to: tmp)
                try PDFs.verify(tmp, pages: g.count)
                res.outputs.append(try r.place(tmp, like: u, suffix: L("（\(PDFs.label(g))）", " (\(PDFs.label(g)))"), ext: "pdf"))
            }
        }
        res.notes.insert(L("拆成 \(res.outputs.count) 份", "\(res.outputs.count) files"), at: 0)
        return res
    }

    /// 移除頁面：pages＝要拿掉的頁
    static func remove(_ r: ToolRun) throws -> ToolResult {
        guard r.opt.has("pages") else { throw ToolError.msg(L("要寫拿掉哪幾頁（例：2, 5-7）", "Say which pages to remove (e.g. 2, 5-7)")) }
        let u = r.inputs[0], d = try PDFs.open(u)
        let drop = Set(try PDFs.pages(r.opt.str("pages"), count: d.pageCount))
        let keep = (0..<d.pageCount).filter { !drop.contains($0) }
        guard !keep.isEmpty else { throw ToolError.msg(L("全部拿掉就沒東西了；至少留一頁", "That would remove every page")) }
        let tmp = r.tmp("remove.pdf")
        try PDFs.write(PDFs.pick(d, keep), to: tmp)
        try PDFs.verify(tmp, pages: keep.count)
        let dst = try r.place(tmp, like: u, suffix: L("（拿掉 \(drop.count) 頁）", " (\(drop.count) removed)"), ext: "pdf")
        return ToolResult(outputs: [dst], notes: [L("剩 \(keep.count) 頁", "\(keep.count) pages left")])
    }

    /// 提取頁面：pages；each＝每頁一份（預設合成一份）
    static func extract(_ r: ToolRun) throws -> ToolResult {
        let u = r.inputs[0], d = try PDFs.open(u)
        guard r.opt.has("pages") else { throw ToolError.msg(L("要寫取哪幾頁（例：1-3, 8）", "Say which pages to extract (e.g. 1-3, 8)")) }
        let idx = try PDFs.pages(r.opt.str("pages"), count: d.pageCount)
        var res = ToolResult()
        let groups = r.opt.bool("each") ? idx.map { [$0] } : [idx]
        for (k, g) in groups.enumerated() {
            let tmp = r.tmp("extract-\(k).pdf")
            try PDFs.write(PDFs.pick(d, g), to: tmp)
            try PDFs.verify(tmp, pages: g.count)
            res.outputs.append(try r.place(tmp, like: u, suffix: L("（\(PDFs.label(g))）", " (\(PDFs.label(g)))"), ext: "pdf"))
        }
        return res
    }

    /// 整理：order＝新順序（沒寫到的頁拿掉，可重複）；rotate＝「2:90, 5:180」；介面送 plan＝[{p:3,r:90},…]
    static func organize(_ r: ToolRun) throws -> ToolResult {
        let u = r.inputs[0], d = try PDFs.open(u)
        var plan: [(Int, Int)] = []
        if let arr = r.opt.raw["plan"] as? [[String: Any]] {
            for x in arr {
                guard let p = (x["p"] as? NSNumber)?.intValue, p >= 1, p <= d.pageCount else { continue }
                plan.append((p - 1, ((x["r"] as? NSNumber)?.intValue ?? 0)))
            }
        } else {
            let order = try PDFs.pages(r.opt.str("order", "all"), count: d.pageCount)
            var rot: [Int: Int] = [:]
            for part in r.opt.str("rotate").replacingOccurrences(of: "，", with: ",").split(separator: ",") {
                let kv = part.split(separator: ":"); if kv.count == 2, let p = Int(kv[0].trimmingCharacters(in: .whitespaces)), let a = Int(kv[1].trimmingCharacters(in: .whitespaces)) { rot[p - 1] = a }
            }
            plan = order.map { ($0, rot[$0] ?? 0) }
        }
        guard !plan.isEmpty else { throw ToolError.msg(L("整理完一頁都不剩；至少留一頁", "No pages left")) }
        let out = PDFDocument()
        for (i, a) in plan {
            guard let p = d.page(at: i)?.copy() as? PDFPage else { continue }
            p.rotation = ((p.rotation + a) % 360 + 360) % 360
            out.insert(p, at: out.pageCount)
        }
        let tmp = r.tmp("organize.pdf")
        try PDFs.write(out, to: tmp)
        try PDFs.verify(tmp, pages: plan.count)
        let dst = try r.place(tmp, like: u, suffix: L("（整理）", " (organized)"), ext: "pdf")
        return ToolResult(outputs: [dst], notes: [L("\(d.pageCount) 頁 → \(plan.count) 頁", "\(d.pageCount) → \(plan.count) pages")])
    }

    /// 旋轉：angle＝90（右轉）／180／270（左轉）；pages 預設全部。一次可以很多份
    static func rotate(_ r: ToolRun) throws -> ToolResult {
        let a = ((r.opt.int("angle", 90) % 360) + 360) % 360
        guard a % 90 == 0, a != 0 else { throw ToolError.msg(L("只能轉 90、180、270 度", "Rotate by 90, 180 or 270")) }
        var res = ToolResult()
        for (k, u) in r.inputs.enumerated() {
            r.progress(L("旋轉 \(k + 1)／\(r.inputs.count)", "Rotating \(k + 1)/\(r.inputs.count)"), Double(k) / Double(r.inputs.count))
            let d = try PDFs.open(u)
            for i in Set(try PDFs.pages(r.opt.str("pages", "all"), count: d.pageCount)) {
                if let p = d.page(at: i) { p.rotation = (p.rotation + a) % 360 }
            }
            let tmp = r.tmp("rotate-\(k).pdf")
            try PDFs.write(d, to: tmp)
            try PDFs.verify(tmp, pages: d.pageCount)
            res.outputs.append(try r.place(tmp, like: u, suffix: L("（旋轉）", " (rotated)"), ext: "pdf"))
        }
        return res
    }

    /// 裁切：mode＝auto（去白邊，預設）／margin（每邊 mm）；pages 預設全部
    static func crop(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        let mm = 72.0 / 25.4
        for u in r.inputs {
            let d = try PDFs.open(u)
            let which = Set(try PDFs.pages(r.opt.str("pages", "all"), count: d.pageCount))
            var changed = 0
            for i in 0..<d.pageCount where which.contains(i) {
                guard let p = d.page(at: i) else { continue }
                let media = p.bounds(for: .mediaBox)
                var box = p.bounds(for: .cropBox)
                if r.opt.str("mode", "auto") == "margin" {
                    let m = CGFloat(r.opt.dbl("mm", 10) * mm)
                    box = box.insetBy(dx: m, dy: m)
                } else {
                    guard let content = contentBounds(p) else { continue }
                    let pad = CGFloat(r.opt.dbl("pad", 4) * mm)
                    box = content.insetBy(dx: -pad, dy: -pad).intersection(media)
                }
                guard box.width > 36, box.height > 36 else { continue }
                p.setBounds(box, for: .cropBox)
                changed += 1
            }
            guard changed > 0 else { throw ToolError.msg(L("「\(u.lastPathComponent)」找不到可以裁的白邊", "No margins to crop in “\(u.lastPathComponent)”")) }
            let tmp = r.tmp("crop.pdf")
            try PDFs.write(d, to: tmp)
            try PDFs.verify(tmp, pages: d.pageCount)
            res.outputs.append(try r.place(tmp, like: u, suffix: L("（裁切）", " (cropped)"), ext: "pdf"))
            res.notes.append(L("裁了 \(changed) 頁（只改顯示範圍，原本的內容都還在檔案裡）", "\(changed) pages cropped (content outside is hidden, not deleted)"))
        }
        return res
    }

    /// 頁面上有東西的範圍（不含旋轉；PDF 座標）。畫成小圖找不是白色的像素
    static func contentBounds(_ page: PDFPage) -> CGRect? {
        guard let cg = page.pageRef else { return nil }
        let media = page.bounds(for: .mediaBox)
        let s: CGFloat = 1.5                                   // 108 dpi 夠找邊
        let w = Int(media.width * s), h = Int(media.height * s)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s); ctx.translateBy(x: -media.minX, y: -media.minY)
        ctx.drawPDFPage(cg)
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if px[o] < 245 || px[o + 1] < 245 || px[o + 2] < 245 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        // 點陣的第 0 列在上面；PDF 的 y 往上。換回頁面座標
        let x0 = CGFloat(minX) / s + media.minX, x1 = CGFloat(maxX + 1) / s + media.minX
        let y0 = CGFloat(h - maxY - 1) / s + media.minY, y1 = CGFloat(h - minY) / s + media.minY
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
