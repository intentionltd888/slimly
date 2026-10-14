// ToolsConvert.swift — 修復、PDF/A、圖片↔PDF、網頁轉 PDF、PDF 轉 Word
import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// 叫包內的 Ghostscript（暫存放本次工作夾；輸出讀完才等結束，不會卡住管線）
enum GS {
    static func run(_ args: [String], work: URL, timeout: TimeInterval = 900, stop: ToolCancel? = nil) -> (status: Int32, log: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Engine.gsPath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = work.path
        p.environment = env
        p.currentDirectoryURL = work
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        var out = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); out.append(d); if out.count > 65_536 { out = out.suffix(32_768) }; lock.unlock()
        }
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline || stop?.isCancelled == true { p.terminate(); break }
            if Thread.isMainThread { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) } else { usleep(50_000) }
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let s = String(decoding: out, as: UTF8.self); lock.unlock()
        return (p.terminationStatus, s)
    }
}

/// 在主執行緒做一件非同步的事並等它做完（app：工具在背景佇列跑；命令列：本來就在主執行緒，轉主迴圈等）
enum MainRunner {
    static func wait(timeout: TimeInterval, _ start: @escaping (@escaping (Error?) -> Void) -> Void) throws {
        var result: Error?? = nil
        let lock = NSLock()
        let finish: (Error?) -> Void = { e in lock.lock(); if result == nil { result = .some(e) }; lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        if Thread.isMainThread {
            start(finish)
            while true {
                lock.lock(); let r = result; lock.unlock()
                if let r { if let e = r { throw e }; return }
                if Date() > deadline { throw ToolError.msg(L("逾時（超過 \(Int(timeout)) 秒）", "Timed out after \(Int(timeout)) s")) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        } else {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { start { e in finish(e); sem.signal() } }
            guard sem.wait(timeout: .now() + timeout) == .success else { throw ToolError.msg(L("逾時（超過 \(Int(timeout)) 秒）", "Timed out after \(Int(timeout)) s")) }
            lock.lock(); let r = result; lock.unlock()
            if let r, let e = r { throw e }
        }
    }
}

enum Convert {
    // MARK: 轉檔（一個入口）

    /// to＝docx／pptx／xlsx／img／md／pdfa（PDF 轉出去）；放進來的不是 PDF 就轉成 PDF：
    /// 圖片（scan＝true 當成拍文件的照片：找邊、拉正、提亮、辨識）、Word／PPT／Excel、網頁（或 url）
    static func any(_ r: ToolRun) throws -> ToolResult {
        let pdfs = r.inputs.filter { $0.pathExtension.lowercased() == "pdf" }
        let others = r.inputs.filter { $0.pathExtension.lowercased() != "pdf" }
        if !pdfs.isEmpty && !others.isEmpty {
            throw ToolError.msg(L("PDF 跟其他檔分開轉：PDF 是轉出去（Word、圖片…），其他檔是轉成 PDF", "Convert PDFs and other files separately"))
        }
        func sub(_ inputs: [URL]) -> ToolRun { ToolRun(id: r.id, inputs: inputs, options: r.opt, dest: r.destOverride, progress: { t, f in r.progress(t, f) }, cancel: r.token) }
        if !pdfs.isEmpty {
            switch r.opt.str("to", "docx") {
            case "docx", "word": return try pdfToWord(r)
            case "pptx", "ppt": return try Layout.pdfToPPT(r)
            case "xlsx", "excel": return try Layout.pdfToExcel(r)
            case "img", "jpg", "png": return try pdfToImages(r)
            case "md", "markdown": return try Layout.pdfToMarkdown(r)
            case "pdfa": return try pdfa(r)
            default: throw ToolError.msg(L("不認得要轉成什麼：\(r.opt.str("to"))", "Unknown target: \(r.opt.str("to"))"))
            }
        }
        var res = ToolResult()
        func merge(_ x: ToolResult) { res.outputs += x.outputs; res.notes += x.notes }
        let ext = { (u: URL) in u.pathExtension.lowercased() }
        let imgs = others.filter { Tools.IMG.contains(ext($0)) }
        let office = others.filter { (Office.word + Office.slides + Office.sheets).contains(ext($0)) }
        let html = others.filter { ["html", "htm", "webarchive"].contains(ext($0)) }
        let unknown = others.filter { u in !imgs.contains(u) && !office.contains(u) && !html.contains(u) }
        if !unknown.isEmpty { throw ToolError.msg(L("「\(unknown[0].lastPathComponent)」轉不了（不認得這種檔）", "Can’t convert “\(unknown[0].lastPathComponent)”")) }
        if !imgs.isEmpty { let s = sub(imgs); defer { s.cleanup() }; merge(r.opt.bool("scan") ? try Scan.run(s) : try imagesToPDF(s)) }
        if !office.isEmpty { let s = sub(office); defer { s.cleanup() }; merge(try Office.toPDF(s)) }
        if !html.isEmpty || (others.isEmpty && r.opt.has("url")) { let s = sub(html); defer { s.cleanup() }; merge(try htmlToPDF(s)) }
        guard !res.outputs.isEmpty else { throw ToolError.msg(L("先放要轉的檔，或貼網址", "Add files or paste a web address")) }
        return res
    }

    // MARK: 修復

    /// 修復：先試 macOS 的 PDF 引擎重寫（最快、不動內容）；打不開再交給 Ghostscript 掃整個檔重建
    static func repair(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        for u in r.inputs {
            let tmp = r.tmp("repair.pdf")
            var how = ""
            if let d = PDFDocument(url: u), !d.isLocked, d.pageCount > 0, d.write(to: tmp), let o = PDFDocument(url: tmp), o.pageCount == d.pageCount {
                how = L("重寫了檔案結構，\(d.pageCount) 頁都在", "File structure rewritten; all \(d.pageCount) pages kept")
            } else {
                try? FileManager.default.removeItem(at: tmp)
                r.progress(L("用 Ghostscript 重建「\(u.lastPathComponent)」", "Rebuilding “\(u.lastPathComponent)”"), 0.3)
                let (st, log) = GS.run(["-sDEVICE=pdfwrite", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-dAutoRotatePages=/None", "-dPreserveMarkedContent=false",
                                        "-dPassThroughJPEGImages=true", "-dPassThroughJPXImages=true",
                                        "-dDownsampleColorImages=false", "-dDownsampleGrayImages=false", "-dDownsampleMonoImages=false",
                                        "-dAutoFilterColorImages=false", "-dColorImageFilter=/FlateEncode",
                                        "-dAutoFilterGrayImages=false", "-dGrayImageFilter=/FlateEncode",
                                        "-o", tmp.path, u.path], work: r.work, stop: r.token)
                guard let o = PDFDocument(url: tmp), o.pageCount > 0 else {
                    throw ToolError.msg(L("「\(u.lastPathComponent)」救不回來（\(st == 0 ? "沒有可用的頁" : String(log.suffix(160)))）", "“\(u.lastPathComponent)” couldn’t be recovered"))
                }
                how = L("重建出 \(o.pageCount) 頁（壞掉的部分救不回來的會少）；圖沒有重壓", "Rebuilt \(o.pageCount) pages; images were not recompressed")
            }
            res.outputs.append(try r.place(tmp, like: u, suffix: L("（修復）", " (repaired)"), ext: "pdf"))
            res.notes.append(how)
        }
        return res
    }

    // MARK: PDF/A

    /// PDF/A（長期保存）：level＝2（預設，2b）／1／3。字型全部嵌入、色彩轉 sRGB、加輸出意圖
    static func pdfa(_ r: ToolRun) throws -> ToolResult {
        let level = ["1", "2", "3"].contains(r.opt.str("level", "2")) ? r.opt.str("level", "2") : "2"
        let def = r.tmp("pdfa_def.ps")
        let ps = """
        %!
        /ICCProfile (%rom%iccprofiles/srgb.icc) def
        [/_objdef {icc_PDFA} /type /stream /OBJ pdfmark
        [{icc_PDFA} << /N 3 >> /PUT pdfmark
        [{icc_PDFA} ICCProfile (r) file /PUT pdfmark
        [/_objdef {OutputIntent_PDFA} /type /dict /OBJ pdfmark
        [{OutputIntent_PDFA} << /Type /OutputIntent /S /GTS_PDFA1 /DestOutputProfile {icc_PDFA} /OutputConditionIdentifier (sRGB IEC61966-2.1) /Info (sRGB) >> /PUT pdfmark
        [{Catalog} << /OutputIntents [ {OutputIntent_PDFA} ] >> /PUT pdfmark
        """
        try ps.write(to: def, atomically: true, encoding: .ascii)
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            r.progress(L("轉「\(u.lastPathComponent)」", "Converting “\(u.lastPathComponent)”"), 0.2)
            let tmp = r.tmp("pdfa.pdf")
            let (st, log) = GS.run(["-dPDFA=\(level)", "-dBATCH", "-dNOPAUSE", "-dSAFER", "-dNOOUTERSAVE", "-sDEVICE=pdfwrite",
                                    "-dPDFACompatibilityPolicy=1", "-sColorConversionStrategy=RGB", "-dAutoRotatePages=/None",
                                    "-dPassThroughJPEGImages=true", "-dDownsampleColorImages=false", "-dDownsampleGrayImages=false",
                                    "-o", tmp.path, "--permit-file-read=\(r.work.path)/", def.path, u.path], work: r.work, stop: r.token)
            guard st == 0 else { throw ToolError.msg(L("轉不了 PDF/A：\(String(log.suffix(200)))", "Couldn’t convert to PDF/A: \(String(log.suffix(200)))")) }
            try PDFs.verify(tmp, pages: d.pageCount)
            guard let data = try? Data(contentsOf: tmp), data.range(of: Data("pdfaid:part".utf8)) != nil || data.range(of: Data("GTS_PDFA1".utf8)) != nil else {
                throw ToolError.msg(L("轉出來的檔沒有 PDF/A 標記，沒交出去", "The result isn’t marked as PDF/A, so it wasn’t saved"))
            }
            res.outputs.append(try r.place(tmp, like: u, suffix: "（PDF-A\(level)b）", ext: "pdf"))
        }
        res.notes.append(L("PDF/A-\(level)b：字型全部嵌入、顏色轉成 sRGB；透明效果與動態內容會被攤平", "PDF/A-\(level)b: fonts embedded, colors converted to sRGB"))
        return res
    }

    // MARK: 圖片 → PDF

    /// 圖片轉 PDF：paper＝a4（預設）／letter／fit（照圖片大小）；orient＝auto／portrait／landscape；margin＝0（預設）／small／big；each＝每張一份
    static func imagesToPDF(_ r: ToolRun) throws -> ToolResult {
        let paper = r.opt.str("paper", "a4"), orient = r.opt.str("orient", "auto")
        let margin: CGFloat = ["small": 20, "big": 50][r.opt.str("margin", "none")] ?? 0
        let groups: [[URL]] = r.opt.bool("each") ? r.inputs.map { [$0] } : [r.inputs]
        var res = ToolResult()
        for (gi, g) in groups.enumerated() {
            let tmp = r.tmp("img-\(gi).pdf")
            var mb = CGRect.zero
            guard let ctx = CGContext(tmp as CFURL, mediaBox: &mb, [kCGPDFContextCreator as String: "Slimly"] as CFDictionary) else { throw ToolError.msg(L("寫不出 PDF", "Couldn’t create the PDF")) }
            var pages = 0
            for (k, u) in g.enumerated() {
                r.progress(L("第 \(k + 1)／\(g.count) 張", "Image \(k + 1)/\(g.count)"), Double(k) / Double(g.count))
                guard let (img, px) = loadImage(u) else { res.notes.append(L("「\(u.lastPathComponent)」讀不出來，跳過", "Skipped “\(u.lastPathComponent)”")); continue }
                var page: CGSize
                switch paper {
                case "fit": page = CGSize(width: px.width + margin * 2, height: px.height + margin * 2)
                case "letter": page = CGSize(width: 612, height: 792)
                default: page = CGSize(width: 595.28, height: 841.89)
                }
                let landscape = orient == "landscape" || (orient == "auto" && paper != "fit" && px.width > px.height)
                if paper != "fit" && landscape { page = CGSize(width: page.height, height: page.width) }
                var r0 = CGRect(origin: .zero, size: page)
                ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &r0, count: MemoryLayout<CGRect>.size)] as CFDictionary)
                let avail = r0.insetBy(dx: margin, dy: margin)
                let k0 = min(avail.width / px.width, avail.height / px.height)
                let w = px.width * k0, h = px.height * k0
                ctx.draw(img, in: CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h))
                ctx.endPDFPage()
                pages += 1
            }
            ctx.closePDF()
            guard pages > 0 else { continue }
            try PDFs.verify(tmp, pages: pages)
            let name = g.count == 1 ? PDFs.stem(g[0]) : PDFs.stem(g[0]) + L(" 等 \(g.count) 張", " +\(g.count - 1)")
            res.outputs.append(try r.place(tmp, like: g[0], suffix: "", ext: "pdf", stem: name))
        }
        guard !res.outputs.isEmpty else { throw ToolError.msg(L("沒有讀得出來的圖片", "No readable images")) }
        return res
    }

    /// 讀圖：轉正（照相機的方向），照片類（JPEG／HEIC）用 JPEG 放進 PDF（JPEG 原檔直接放、不重壓），截圖類（PNG）保持無損
    static func loadImage(_ u: URL) -> (CGImage, CGSize)? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0, h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orient = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let type = CGImageSourceGetType(src) as String? ?? ""
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let pt = 72 / max(72, min(600, dpi))
        if type == UTType.jpeg.identifier, orient == 1, let data = try? Data(contentsOf: u), let img = Raster.jpegImage(data) {
            return (img, CGSize(width: w * pt, height: h * pt))
        }
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: max(w, h)] as CFDictionary) else { return nil }
        let size = CGSize(width: Double(img.width) * pt, height: Double(img.height) * pt)
        let photo = type == UTType.jpeg.identifier || type == UTType.heic.identifier || type == "public.heif"
        if photo, let d = Raster.encode(img, quality: 0.9), let j = Raster.jpegImage(d) { return (j, size) }
        return (img, size)
    }

    // MARK: PDF → 圖片

    /// PDF 轉圖片：mode＝pages（每頁一張，預設）／images（取出裡面的圖）；dpi＝150（預設）／300；format＝jpg／png
    static func pdfToImages(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        let png = r.opt.str("format", "jpg") == "png"
        for u in r.inputs {
            let d = try PDFs.open(u)
            let folder = r.tmp("imgs-\(res.outputs.count)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var count = 0
            let stem = PDFs.stem(u)
            if r.opt.str("mode", "pages") == "images" {
                count = extractImages(d, into: folder, stem: stem)
                guard count > 0 else { throw ToolError.msg(L("「\(u.lastPathComponent)」裡沒有可以取出的圖片", "No embedded images in “\(u.lastPathComponent)”")) }
            } else {
                let which = try PDFs.pages(r.opt.str("pages", "all"), count: d.pageCount)
                let dpi = CGFloat(min(600, max(36, r.opt.dbl("dpi", 150))))
                for (k, i) in which.enumerated() {
                    if r.isCancelled { break }
                    r.progress(L("第 \(i + 1) 頁", "Page \(i + 1)"), Double(k) / Double(which.count))
                    guard let p = d.page(at: i), let img = Raster.page(p, dpi: dpi, maxSide: 12000),
                          let data = Raster.encode(img, type: png ? .png : .jpeg, quality: 0.9) else { continue }
                    try data.write(to: folder.appendingPathComponent(String(format: "%@-%03d.%@", stem, i + 1, png ? "png" : "jpg")))
                    count += 1
                }
            }
            // 只有一張：直接放一個檔；很多張：放一個資料夾
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            if files.count == 1, let f = files.first {
                res.outputs.append(try r.place(f, like: u, suffix: "", ext: f.pathExtension, stem: f.deletingPathExtension().lastPathComponent))
            } else {
                let dir = r.destOverride ?? Compressor.destination(for: u, override: nil).dir
                res.outputs.append(try Files.moveNoClobber(folder, into: dir, name: stem + L("（圖片）", " (images)")))
            }
            res.notes.append(L("\(count) 張", "\(count) images"))
        }
        return res
    }

    /// 取出 PDF 裡的圖：JPEG 原檔照抄；其他（8 位元 RGB／灰階）解開存 PNG。同一張圖只取一次
    static func extractImages(_ d: PDFDocument, into folder: URL, stem: String) -> Int {
        var seen = Set<Int>(), n = 0
        func walk(_ res: CGPDFDictionaryRef?, depth: Int) {
            guard let res, depth < 6 else { return }
            var xo: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return }
            CGPDFDictionaryApplyBlock(xo, { _, obj, _ in
                var st: CGPDFStreamRef?
                guard CGPDFObjectGetValue(obj, .stream, &st), let st, let dict = CGPDFStreamGetDictionary(st) else { return true }
                let key = unsafeBitCast(st, to: Int.self)
                if seen.contains(key) { return true }
                seen.insert(key)
                var sub: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dict, "Subtype", &sub), let sub else { return true }
                if String(cString: sub) == "Form" {
                    var r2: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &r2) { walk(r2, depth: depth + 1) }
                    return true
                }
                guard String(cString: sub) == "Image" else { return true }
                var w: CGPDFInteger = 0, h: CGPDFInteger = 0, bpc: CGPDFInteger = 8
                CGPDFDictionaryGetInteger(dict, "Width", &w); CGPDFDictionaryGetInteger(dict, "Height", &h); CGPDFDictionaryGetInteger(dict, "BitsPerComponent", &bpc)
                guard w >= 32, h >= 32 else { return true }                        // 小圖示、線條不要
                var fmt: CGPDFDataFormat = .raw
                guard let data = CGPDFStreamCopyData(st, &fmt) as Data? else { return true }
                n += 1
                let base = folder.appendingPathComponent(String(format: "%@-img%03d", stem, n))
                if fmt == .jpegEncoded { try? data.write(to: base.appendingPathExtension("jpg")); return true }
                if fmt == .JPEG2000 { try? data.write(to: base.appendingPathExtension("jp2")); return true }
                // 解開的原始像素：看色彩空間有幾個分量
                var comps = 3
                var csName: UnsafePointer<CChar>?
                var csArr: CGPDFArrayRef?
                if CGPDFDictionaryGetName(dict, "ColorSpace", &csName), let csName {
                    let c = String(cString: csName); comps = c == "DeviceGray" ? 1 : c == "DeviceCMYK" ? 4 : 3
                } else if CGPDFDictionaryGetArray(dict, "ColorSpace", &csArr), let csArr {
                    var nm: UnsafePointer<CChar>?
                    if CGPDFArrayGetName(csArr, 0, &nm), let nm, String(cString: nm) == "ICCBased" {
                        var icc: CGPDFStreamRef?
                        if CGPDFArrayGetStream(csArr, 1, &icc), let icc, let idict = CGPDFStreamGetDictionary(icc) {
                            var nn: CGPDFInteger = 3; CGPDFDictionaryGetInteger(idict, "N", &nn); comps = Int(nn)
                        }
                    } else { n -= 1; return true }                                  // Indexed 之類：不處理
                }
                guard bpc == 8, comps != 4, data.count >= Int(w) * Int(h) * comps,
                      let prov = CGDataProvider(data: data as CFData),
                      let img = CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 8 * comps, bytesPerRow: Int(w) * comps,
                                        space: comps == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                      let png = Raster.encode(img, type: .png) else { n -= 1; return true }
                try? png.write(to: base.appendingPathExtension("png"))
                return true
            }, nil)
        }
        for i in 0..<d.pageCount {
            guard let p = d.page(at: i)?.pageRef, let pd = p.dictionary else { continue }
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pd, "Resources", &res) { walk(res, depth: 0) }
        }
        return n
    }

    // MARK: 網頁 → PDF

    /// 網頁轉 PDF：url＝網址（或丟 .html／.webarchive 檔）；paper＝a4（預設，切在空白處分頁）／letter／long（一整頁長圖）
    static func htmlToPDF(_ r: ToolRun) throws -> ToolResult {
        var sources: [URL] = r.inputs
        if r.opt.has("url") {
            var s = r.opt.str("url")
            if !s.contains("://") { s = "https://" + s }
            guard let u = URL(string: s), u.host != nil else { throw ToolError.msg(L("網址看不懂：\(s)", "Invalid address: \(s)")) }
            sources.insert(u, at: 0)
        }
        guard !sources.isEmpty else { throw ToolError.msg(L("給一個網址，或丟 .html 檔", "Enter an address or add .html files")) }
        var res = ToolResult()
        for (k, src) in sources.enumerated() {
            r.progress(L("打開 \(src.isFileURL ? src.lastPathComponent : src.host ?? "")", "Loading \(src.isFileURL ? src.lastPathComponent : src.host ?? "")"), Double(k) / Double(sources.count))
            let long = r.tmp("long-\(k).pdf")
            var title = ""
            try MainRunner.wait(timeout: 90) { done in
                WebSnapshot.shared.capture(src, to: long, width: CGFloat(r.opt.dbl("width", 1000))) { t, e in title = t; done(e) }
            }
            let out = r.tmp("html-\(k).pdf")
            let paper = r.opt.str("paper", "a4")
            if paper == "long" { try FileManager.default.moveItem(at: long, to: out) }
            else { try paginate(long, to: out, page: paper == "letter" ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)) }
            try PDFs.verify(out)
            let stem = !title.isEmpty ? String(title.prefix(80)).replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
                                      : (src.isFileURL ? PDFs.stem(src) : (src.host ?? "網頁"))
            res.outputs.append(try r.place(out, like: src.isFileURL ? src : nil, suffix: "", ext: "pdf", stem: stem))
        }
        res.notes.append(L("網頁照螢幕版面轉；會動的東西、要登入才看得到的內容不會出現", "Converted as shown on screen; logged-in or animated content won’t appear"))
        return res
    }

    /// 一整頁長的 PDF 切成紙張大小：內容縮到紙寬（留邊），分頁點往上找一條空白列，不把字切一半
    static func paginate(_ long: URL, to out: URL, page: CGSize) throws {
        guard let d = PDFDocument(url: long), let p = d.page(at: 0) else { throw ToolError.msg(L("網頁畫不出來", "The page didn’t render")) }
        let b = p.bounds(for: .mediaBox)
        let margin: CGFloat = 32
        let k = (page.width - margin * 2) / b.width
        let sliceH = (page.height - margin * 2) / k                 // 每頁裝得下的原始高度
        // 低解析度畫一次，找每一列有沒有東西
        let s: CGFloat = 0.5
        let W = max(1, Int(b.width * s)), H = max(1, Int(b.height * s))
        var blank = [Bool](repeating: true, count: H)
        if let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.scaleBy(x: s, y: s); p.draw(with: .mediaBox, to: ctx)
            let px = data.bindMemory(to: UInt8.self, capacity: W * H * 4)
            for y in 0..<H {
                var clean = true
                for x in stride(from: 0, to: W, by: 2) { let o = (y * W + x) * 4; if px[o] < 240 || px[o + 1] < 240 || px[o + 2] < 240 { clean = false; break } }
                blank[y] = clean                                           // y＝從上往下第幾列
            }
        }
        var cuts: [CGFloat] = [0]                                          // 從頂端往下量的位置（原始座標）
        while cuts.last! + sliceH < b.height {
            let ideal = cuts.last! + sliceH
            var cut = ideal
            var yy = Int(ideal * s)
            let floor = Int((cuts.last! + sliceH * 0.8) * s)
            while yy > floor { if yy < H, blank[yy] { cut = CGFloat(yy) / s; break }; yy -= 1 }
            cuts.append(cut)
        }
        cuts.append(b.height)
        // 整段都是空白的（網頁底部多出來的）不印
        func isBlank(_ top: CGFloat, _ bottom: CGFloat) -> Bool {
            let a = max(0, Int(top * s)), z = min(H, Int(bottom * s))
            return a >= z || (a..<z).allSatisfy { blank[$0] }
        }
        var mb = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(out as CFURL, mediaBox: &mb, nil) else { throw ToolError.msg(L("寫不出 PDF", "Couldn’t create the PDF")) }
        var printed = 0
        for i in 0..<(cuts.count - 1) {
            let top = cuts[i], bottom = cuts[i + 1]
            if isBlank(top, bottom) && !(i == cuts.count - 2 && printed == 0) { continue }
            printed += 1
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // 這一段（從頂端 top 到 bottom）放到紙的上緣
            ctx.clip(to: CGRect(x: margin, y: page.height - margin - (bottom - top) * k, width: page.width - margin * 2, height: (bottom - top) * k))
            ctx.translateBy(x: margin, y: page.height - margin)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: 0, y: -(b.height - top))
            p.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: PDF → Word

    /// PDF 轉 Word：Ghostscript 的 docxwrite（段落、字、表格的文字）；掃描檔先辨識文字
    static func pdfToWord(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        for u in r.inputs {
            let d = try PDFs.open(u)
            var src = u
            let textPages = (0..<d.pageCount).filter { d.page(at: $0).map(OCR.hasText) ?? false }.count
            if textPages * 2 < d.pageCount {
                // 大半是掃描：先做一份可搜尋的，再轉
                r.progress(L("先辨識掃描的字", "Recognizing scanned text first"), 0.1)
                let sub = ToolRun(id: "ocr", inputs: [u], options: ToolOptions(raw: ["lang": r.opt.str("lang", "zh")]), dest: r.work, progress: nil, cancel: r.token)
                defer { sub.cleanup() }
                if let o = try? OCR.run(sub), let f = o.outputs.first { src = f }
            }
            r.progress(L("轉「\(u.lastPathComponent)」", "Converting “\(u.lastPathComponent)”"), 0.5)
            let tmp = r.tmp("word.docx")
            let (st, log) = GS.run(["-sDEVICE=docxwrite", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-o", tmp.path, src.path], work: r.work, stop: r.token)
            guard PDFs.fileSize(tmp) > 2000 else { throw ToolError.msg(L("轉不出 Word（\(st)）：\(String(log.suffix(160)))", "Couldn’t convert to Word: \(String(log.suffix(160)))")) }
            try fixDocx(tmp, work: r.work)
            res.outputs.append(try r.place(tmp, like: u, suffix: "", ext: "docx"))
        }
        res.notes.append(L("文字、段落、表格的字都可以編輯；多欄或圖文穿插的版面會重新排過，圖片不會帶過去", "Text, paragraphs and table text are editable; complex layouts are reflowed and images aren’t included"))
        return res
    }
}

extension Convert {
    /// docx 裡的字修部首碼位（解開 → 改 word/document.xml → 包回去）
    static func fixDocx(_ docx: URL, work: URL) throws {
        let dir = work.appendingPathComponent("docx-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", docx.path, "-d", dir.path]
        try unzip.run(); unzip.waitUntilExit()
        let xml = dir.appendingPathComponent("word/document.xml")
        guard unzip.terminationStatus == 0, let s = try? String(contentsOf: xml, encoding: .utf8) else { return }
        let fixed = PDFs.fixRadicals(s)
        guard fixed != s else { return }
        try fixed.write(to: xml, atomically: true, encoding: .utf8)
        let out = work.appendingPathComponent("fixed-\(UUID().uuidString.prefix(6)).docx")
        try OOXML.zip(dir, to: out)
        _ = try FileManager.default.replaceItemAt(docx, withItemAt: out)
    }
}

/// 網頁畫成一整頁長的 PDF（WKWebView；app 與命令列都在主執行緒用）
final class WebSnapshot: NSObject, WKNavigationDelegate {
    static let shared = WebSnapshot()
    private var web: WKWebView?
    private var window: NSWindow?
    private var pending: ((String, Error?) -> Void)?
    private var out: URL?

    func capture(_ src: URL, to out: URL, width: CGFloat, _ done: @escaping (String, Error?) -> Void) {
        if NSApp == nil { _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited) }   // 命令列：WebKit 要有 NSApplication
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800), configuration: cfg)
        w.navigationDelegate = self
        let win = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = w
        web = w; window = win; pending = done; self.out = out
        if src.isFileURL {
            if src.pathExtension.lowercased() == "webarchive", let data = try? Data(contentsOf: src) {
                w.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: src.deletingLastPathComponent())
            } else { w.loadFileURL(src, allowingReadAccessTo: src.deletingLastPathComponent()) }
        } else { w.load(URLRequest(url: src, timeoutInterval: 45)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等字型、圖片再畫：先捲到底觸發延遲載入的圖，1.5 秒後量高度出 PDF
        webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); setTimeout(() => window.scrollTo(0, 0), 300); document.title") { t, _ in
            let title = (t as? String) ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // 內容的高度（document 的 scrollHeight 至少等於視窗高，短的頁會多出一大片空白）
                webView.evaluateJavaScript("Math.ceil(Math.max(document.body.scrollHeight, document.body.getBoundingClientRect().bottom + window.scrollY) + 16)") { h, _ in
                    let height = min(60000, max(400, (h as? NSNumber)?.doubleValue ?? 1200))
                    webView.frame.size.height = CGFloat(height)
                    let cfg = WKPDFConfiguration()
                    cfg.rect = CGRect(x: 0, y: 0, width: webView.frame.width, height: CGFloat(height))
                    webView.createPDF(configuration: cfg) { res in
                        switch res {
                        case .success(let data):
                            do { try data.write(to: self.out!); self.finish(title, nil) } catch { self.finish(title, error) }
                        case .failure(let e): self.finish(title, e)
                        }
                    }
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish("", error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish("", ToolError.msg(L("打不開這個網址：\(error.localizedDescription)", "Couldn’t load the page: \(error.localizedDescription)")))
    }
    private func finish(_ title: String, _ e: Error?) {
        let p = pending; pending = nil
        web?.navigationDelegate = nil; web = nil; window = nil
        p?(title, e)
    }
}
