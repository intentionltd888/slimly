// OfficeEngine.swift — Office 檔裡的圖壓縮（擴充提案 #6）：docx、pptx、xlsx 也用同一顆鍵、同一套目標與壓前預估
//
// 做法：解開 zip（系統內建 /usr/bin/unzip），只重壓 media 夾裡的圖（word/media、ppt/media、xl/media），其他部分一個位元組都不動，
//       照原本的順序重新打包（/usr/bin/zip）。
//   ・照片（PNG 沒有透明、壓成 JPEG 小到 6 成以下）→ JPEG，副檔名改了就同步改 *.rels 的 Target 與 [Content_Types].xml
//   ・有透明的 PNG 還是 PNG（只縮尺寸）；JPEG 重壓要小 1 成以上才換；50 KB 以下的小圖（logo、圖示）不動
//   ・圖不轉正（Office 自己管方向）、相機資訊照留；GPS 照設定
//   ・六級跟照片同一套（畫質 0.90／0.80／0.62，再縮長邊 3000／2400／1600）；第一個整份壓到目標以下的就停；壓不到交最小的
// 不壓（照實說）：有密碼（加密的 Office 檔其實是 OLE 容器，裡面有 EncryptedPackage）、有數位簽章（_xmlsignatures）、
//   內嵌 OLE 物件（embeddings 裡不是圖表資料表的檔、ActiveX）、巨集（vbaProject.bin、docm／pptm／xlsm）、
//   舊格式 doc／ppt／xls（含改了副檔名的）。圖表（charts）帶的 Excel 資料表不算 OLE，照樣壓（它一個位元組都不會動）。
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum OfficeDoc {
    static let exts: Set<String> = ["docx", "pptx", "xlsx"]
    static let macroExts: Set<String> = ["docm", "pptm", "xlsm"]
    static let legacyExts: Set<String> = ["doc", "ppt", "xls"]
    static func isOffice(_ u: URL) -> Bool { let e = u.pathExtension.lowercased(); return exts.contains(e) || macroExts.contains(e) || legacyExts.contains(e) }
    static let mediaDirs = ["word/media/", "ppt/media/", "xl/media/"]
    static func isMedia(_ name: String) -> Bool {
        let l = name.lowercased()
        return mediaDirs.contains { l.hasPrefix($0) } && (l.hasSuffix(".png") || l.hasSuffix(".jpg") || l.hasSuffix(".jpeg"))
    }

    /// 跑一個系統指令，回 (結束碼, 標準輸出)
    @discardableResult
    static func sh(_ exe: String, _ args: [String], cwd: URL? = nil, stdin: String? = nil) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let o = Pipe(), i = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        p.standardInput = stdin == nil ? FileHandle.nullDevice : i
        do { try p.run() } catch { return (-1, "") }
        if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)); try? i.fileHandleForWriting.close() }
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// zip 裡的檔名（照原本的順序）；nil＝不是 zip
    static func entries(_ u: URL) -> [String]? {
        let (c, out) = sh("/usr/bin/zipinfo", ["-1", u.path])
        guard c == 0 else { return nil }
        return out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// 收件：能不能壓、是哪一種、幾頁（投影片、工作表）、幾張圖
    static func check(_ url: URL) -> Result<PDFInfo, SkipError> {
        let name = url.lastPathComponent, fm = FileManager.default, ext = url.pathExtension.lowercased()
        if legacyExts.contains(ext) { return .failure(SkipError(code: .legacy, name: name)) }
        if macroExts.contains(ext) { return .failure(SkipError(code: .officeMacro, name: name)) }
        guard fm.isReadableFile(atPath: url.path) else { return .failure(SkipError(code: .unreadable, name: name)) }
        let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { return .failure(SkipError(code: .empty, name: name)) }
        guard let h = FileHandle(forReadingAtPath: url.path) else { return .failure(SkipError(code: .unreadable, name: name)) }
        let head = h.readData(ofLength: 8); try? h.close()
        if head == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            // OLE 容器：裡面有 EncryptedPackage 串流＝加了密碼的新格式；沒有＝舊格式（doc／ppt／xls）改了副檔名
            let enc = Data("EncryptedPackage".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            let all = (try? Data(contentsOf: url, options: .alwaysMapped)) ?? Data()
            return .failure(SkipError(code: all.range(of: enc) != nil ? .officeLocked : .legacy, name: name))
        }
        guard head.starts(with: [0x50, 0x4B, 0x03, 0x04]), let es = entries(url), es.contains("[Content_Types].xml") else {
            return .failure(SkipError(code: .officeDamaged, name: name))
        }
        // 數位簽章：_xmlsignatures 夾，或封裝層的 rels 指到 digital-signature/origin
        if es.contains(where: { $0.hasPrefix("_xmlsignatures/") }) || sh("/usr/bin/unzip", ["-p", url.path, "_rels/.rels"]).1.contains("digital-signature/origin") {
            return .failure(SkipError(code: .officeSigned, name: name))
        }
        if es.contains(where: { $0.lowercased().hasSuffix("vbaproject.bin") }) { return .failure(SkipError(code: .officeMacro, name: name)) }
        // OLE 物件：embeddings 夾裡、不是圖表自己帶的資料表（圖表的 Excel 資料表從 charts/_rels 指過去，照樣能壓）；ActiveX 控制項也算
        let emb = es.filter { $0.contains("/embeddings/") && !$0.hasSuffix("/") }
        var ole = es.contains { $0.contains("/activeX/") && !$0.hasSuffix("/") }
        if !ole && !emb.isEmpty {
            let fromCharts = Set(targets(sh("/usr/bin/unzip", ["-p", url.path, "*/charts/_rels/*.rels"]).1).map { (String($0.1) as NSString).lastPathComponent })
            ole = emb.contains { !fromCharts.contains(($0 as NSString).lastPathComponent) }
        }
        if ole { return .failure(SkipError(code: .officeOle, name: name)) }
        let count = { (re: String) in es.filter { $0.range(of: re, options: .regularExpression) != nil }.count }
        var info = PDFInfo(url: url, bytes: bytes, pages: max(1, ext == "pptx" ? count(#"^ppt/slides/slide\d+\.xml$"#) : ext == "xlsx" ? count(#"^xl/worksheets/sheet\d+\.xml$"#) : 1),
                           signed: false, hasForm: false, producer: "", creator: "")
        info.kind = .office
        info.format = ext.uppercased()
        info.width = es.filter(isMedia).count                                          // 照片沿用 width 欄位放「幾張圖」
        return .success(info)
    }

    /// rels 文字裡每個 Target="…" 的值（位置、內容）
    static func targets(_ s: String) -> [(Range<String.Index>, Substring)] {
        let re = try! NSRegularExpression(pattern: #"\bTarget="([^"]*)""#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in Range(m.range(at: 1), in: s).map { ($0, s[$0]) } }
    }

    /// rels 裡的一個 Target：照 rels 所在的位置解成 zip 裡的完整路徑，指到改了名的圖就回新的 Target（前面的路徑、編碼照舊，只換副檔名）；
    /// 外部網址、指到別的檔的回 nil
    static func retarget(_ t: String, from src: String, renames: [String: String]) -> String? {
        if t.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil { return nil }
        let raw = t.removingPercentEncoding ?? t
        var parts: [Substring] = []
        for p in ((raw.hasPrefix("/") || src.isEmpty ? "" : src + "/") + raw).split(separator: "/") {
            if p == ".." { _ = parts.popLast() } else if p != "." { parts.append(p) }
        }
        let key = parts.joined(separator: "/")
        guard let new = renames[key] else { return nil }
        return (t as NSString).deletingPathExtension + new.dropFirst((key as NSString).deletingPathExtension.count)    // image1.png → image1.jpg（撞名時 image1_2.jpg）
    }

    // MARK: 圖

    struct Media { let name: String; let bytes: Int64 }
    /// 一張圖照這一級重壓：回 (新的資料, 是不是 PNG)；nil＝不換（不夠小、太小張、解不開）
    static func recompress(_ data: Data, name: String, level i: Int, stripGPS: Bool) -> (Data, Bool)? {
        guard data.count >= 50 * 1024, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let isPNG = name.lowercased().hasSuffix(".png")
        let alpha = isPNG && ImageLadder.hasTransparency(src)
        let lv = ImageLadder.levels[i]
        if alpha && lv.edge == nil { return nil }                                       // 透明的 PNG 只縮尺寸
        guard let scaled = lv.edge.map({ ImageLadder.scaled(img, edge: $0) }) ?? img else { return nil }
        let toPNG = alpha
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, (toPNG ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return nil }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyPNGDictionary] { props[k] = nil }
        if stripGPS { props[kCGImagePropertyGPSDictionary] = nil }
        if !toPNG { props[kCGImageDestinationLossyCompressionQuality] = lv.q }
        CGImageDestinationAddImage(dst, scaled, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        let d = out as Data
        // 夠小才換：PNG 變 JPEG 要小到 6 成以下（圖表、截圖這種 JPEG 反而大或糊的留 PNG）；JPEG 重壓要小 1 成以上
        let need = isPNG && !toPNG ? 0.6 : 0.9
        return Double(d.count) <= Double(data.count) * need ? (d, toPNG) : nil
    }
}

/// 壓一份 Office 檔。介面跟 PDF、照片一樣（主視窗、命令列、監看資料夾共用）
final class OfficeCompressor: Compressing {
    let info: PDFInfo
    let target: Int64?
    let destOverride: URL?
    var onProgress: ((Int, Int, Int) -> Void)?

    private let q = DispatchQueue(label: "slimly.office", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    init(info: PDFInfo, target: Int64?, dest: URL? = nil) { self.info = info; self.target = target; self.destOverride = dest }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func run(_ done: @escaping (Outcome) -> Void) { q.async { let r = self.ladder(); DispatchQueue.main.async { done(r) } } }
    func runSync() -> Outcome { ladder() }

    /// 解開、算每一級整份多大（只重壓圖；其他部分不動），回 (第幾級, 每張圖換成什麼)。estimateOnly＝六級都算（壓前預估）
    static func plan(_ info: PDFInfo, dir: URL, target: Int64?, every: Bool, cancelled: () -> Bool, onLevel: ((Int, Int64) -> Void)? = nil)
        -> (levels: [Int64?], pick: Int, changes: [String: (Data, Bool)])? {
        guard let names = OfficeDoc.entries(info.url) else { return nil }
        let media = names.filter(OfficeDoc.isMedia).map { OfficeDoc.Media(name: $0, bytes: (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.size] as? NSNumber)?.int64Value ?? 0) }
        var totals: [Int64?] = Array(repeating: nil, count: ImageLadder.levels.count)
        var keep: (i: Int, c: [String: (Data, Bool)])? = nil, small: (i: Int, t: Int64, c: [String: (Data, Bool)])? = nil
        let order = target == nil && !every ? [0] : Array(ImageLadder.levels.indices)
        for i in order {
            if cancelled() { return nil }
            var changes: [String: (Data, Bool)] = [:], total = info.bytes
            for m in media {
                if cancelled() { return nil }
                guard let d = try? Data(contentsOf: dir.appendingPathComponent(m.name)),
                      let r = OfficeDoc.recompress(d, name: m.name, level: i, stripGPS: Prefs.stripGPS) else { continue }
                changes[m.name] = r; total += Int64(r.0.count) - m.bytes
            }
            totals[i] = total; onLevel?(i, total)
            if small == nil || total < small!.t { small = (i, total, changes) }
            if !every, let t = target, total <= t { keep = (i, changes); break }
            if !every, target == nil { keep = (i, changes); break }
        }
        let pick = keep ?? small.map { ($0.i, $0.c) } ?? (0, [:])
        return (totals, pick.0, pick.1)
    }

    private func ladder() -> Outcome {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Slimly-\(UUID().uuidString)", isDirectory: true)
        let dir = work.appendingPathComponent("x", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return .failed(code: "space", detail: error.localizedDescription) }
        guard let names = OfficeDoc.entries(info.url), OfficeDoc.sh("/usr/bin/unzip", ["-q", "-o", info.url.path, "-d", dir.path]).0 <= 1 else {   // 1＝有警告但都解開了
            return .failed(code: "engine", detail: "unzip")
        }
        onProgress?(0, 0, 1)
        guard let plan = Self.plan(info, dir: dir, target: target, every: false, cancelled: { self.isCancelled }, onLevel: { i, _ in self.onProgress?(i, 0, 1) }) else {
            return .failed(code: isCancelled ? "cancelled" : "engine", detail: "")
        }
        if plan.changes.isEmpty { return .noGain(best: info.bytes) }                                // 沒有一張圖值得換
        // 換圖：副檔名變了（PNG→JPEG）要同步改 rels 的 Target 與 [Content_Types].xml
        var renames: [String: String] = [:]
        for (name, (data, png)) in plan.changes {
            let u = dir.appendingPathComponent(name)
            var newName = name
            if !png && name.lowercased().hasSuffix(".png") {
                let base = (name as NSString).deletingPathExtension
                newName = base + ".jpg"; var k = 2
                while names.contains(newName) || renames.values.contains(newName) { newName = base + "_\(k).jpg"; k += 1 }
                try? fm.removeItem(at: u)
                renames[name] = newName
            }
            do { try data.write(to: dir.appendingPathComponent(newName)) } catch { return .failed(code: "space", detail: error.localizedDescription) }
        }
        if !renames.isEmpty {
            // 每個 *.rels 的 Target 照它所在的位置解成完整路徑（../media/image1.png、media/image1.png、/ppt/media/image1.png），指到改了名的圖才換
            for rel in names where rel.hasSuffix(".rels") {
                let u = dir.appendingPathComponent(rel)
                guard let s = try? String(contentsOf: u, encoding: .utf8) else { continue }
                let src = ((rel as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent      // ppt/slides/_rels/slide1.xml.rels → ppt/slides
                var out = "", last = s.startIndex
                for (r, t) in OfficeDoc.targets(s) {
                    guard let new = OfficeDoc.retarget(String(t), from: src, renames: renames) else { continue }
                    out += s[last..<r.lowerBound]; out += new; last = r.upperBound
                }
                out += s[last...]
                if out != s { try? out.write(to: u, atomically: true, encoding: .utf8) }
            }
            let ct = dir.appendingPathComponent("[Content_Types].xml")
            if var s = try? String(contentsOf: ct, encoding: .utf8) {
                for (old, new) in renames {
                    let enc = { (p: String) in p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p }
                    for o in Set([old, enc(old)]) {
                        s = s.replacingOccurrences(of: #"<Override[^>]*PartName="/\#(NSRegularExpression.escapedPattern(for: o))"[^>]*/>"#,
                                                   with: NSRegularExpression.escapedTemplate(for: "<Override PartName=\"/\(enc(new))\" ContentType=\"image/jpeg\"/>"),
                                                   options: [.regularExpression, .caseInsensitive])
                    }
                }
                if s.range(of: #"<Default\s+Extension="jpg""#, options: [.regularExpression, .caseInsensitive]) == nil {
                    s = s.replacingOccurrences(of: "</Types>", with: "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/></Types>")
                }
                try? s.write(to: ct, atomically: true, encoding: .utf8)
            }
        }
        // 照原本的順序重新打包（圖本來就壓過了：只存不壓）
        let order = names.map { renames[$0] ?? $0 }.filter { !$0.hasSuffix("/") }
        let out = work.appendingPathComponent("out.zip")
        guard OfficeDoc.sh("/usr/bin/zip", ["-X", "-D", "-q", "-nw", "-n", ".jpg:.jpeg:.png:.gif", out.path, "-@"], cwd: dir, stdin: order.joined(separator: "\n") + "\n").0 == 0,
              OfficeDoc.sh("/usr/bin/unzip", ["-tq", out.path]).0 == 0, let after = OfficeDoc.entries(out), after.count == order.count else {
            return .failed(code: "engine", detail: "zip")
        }
        let bytes = (try? fm.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0
        if isCancelled { return .failed(code: "cancelled", detail: "") }
        if Double(bytes) >= Double(info.bytes) * Engine.minGain { return .noGain(best: bytes) }
        let reached = target.map { bytes <= $0 } ?? true
        let smallest = plan.levels.compactMap { $0 }.min() ?? bytes
        return Compressor.place(out, src: info.url, destOverride: destOverride, ext: info.url.pathExtension.lowercased(), bytes: bytes,
                                level: plan.pick, reached: reached, smallest: min(smallest, bytes), note: nil)
    }
}
