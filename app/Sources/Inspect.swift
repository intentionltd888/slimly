// Inspect.swift — 收件：把拖進來的東西變成「可以壓的 PDF 清單」＋「為什麼略過」
//
// 壓之前先看一眼，擋掉會出事的：不是 PDF、空檔、壞檔、有密碼、有電子簽章（壓了簽章會失效）。
// 全部只讀，不碰原檔。
import Foundation
import PDFKit
import ImageIO

/// 為什麼這份不壓（給介面講人話用；code 是介面的鍵）
enum SkipCode: String {
    case notPDF, empty, damaged, unreadable, locked, protected, signed, duplicate
    case legacy, officeLocked, officeSigned, officeOle, officeMacro, officeDamaged      // Office 檔
}

enum MediaKind: String { case pdf, image, office }

/// 一份要壓的檔（名字沿用 PDFInfo；也可以是照片：kind＝image）
struct PDFInfo {
    let url: URL
    let bytes: Int64
    let pages: Int
    let signed: Bool          // 有電子簽章（壓縮＝重寫內容，簽章一定失效）
    let hasForm: Bool         // 有可填寫的表單欄位
    let producer: String
    let creator: String
    var iccNew = false        // 圖片帶 ICC v4.1 以上的色彩描述檔（Chrome、Canva、部分 Keynote）：gs 壓了會變大、變色、甚至掉東西
    var slimmed = false       // 我們自己壓過的（輸出時文件資訊會帶 SlimlyVersion）
    // ── 照片──
    var kind: MediaKind = .pdf
    var width = 0, height = 0 // 照片轉正之後的寬高（EXIF 方向 5–8＝寬高對調）
    var alpha = false         // 有透明通道（PNG）；真的有透明的地方才保留 PNG，壓縮時再看
    var format = ""           // HEIC／JPEG／PNG
    /// Illustrator／Photoshop 存的 PDF：裡面有「保留編輯能力」的資料，壓完就只能看、印，不能再用原軟體編輯
    /// 只看建立程式（Producer 帶 Photoshop 的多半是 Word 轉 PDF 時圖片經過 Photoshop 外掛，不是可編輯檔）
    var editable: Bool { creator.range(of: #"Illustrator|Photoshop"#, options: .regularExpression) != nil }
}

enum Inspect {
    /// 備份夾不收：拖整個資料夾進來時，不要把上次收起來的原檔又壓一次
    static let backupFolderNames: Set<String> = ["未壓縮備份", "Uncompressed Originals"]
    /// 照片：HEIC、JPEG、PNG 也用同一顆鍵壓
    static let imageExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]
    static func isImage(_ u: URL) -> Bool { imageExts.contains(u.pathExtension.lowercased()) }
    static let maxFilesPerDrop = 1000

    /// 資料夾展開成裡面的 PDF（含子資料夾，跳過隱藏檔、套件與備份夾）；其他照原樣。
    /// 回傳：要檢查的檔案、以及「裡面一份 PDF 都沒有」的資料夾名稱。
    static func expand(_ urls: [URL]) -> (files: [URL], emptyFolders: [String]) {
        var out: [URL] = [], empty: [String] = []
        let fm = FileManager.default
        for u0 in urls {
            let u = u0.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { out.append(u); continue }
            let isPackage = (try? u.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            guard isDir.boolValue, !isPackage else { out.append(u); continue }
            var found: [URL] = []
            let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let f = e?.nextObject() as? URL {
                if backupFolderNames.contains(f.lastPathComponent) { e?.skipDescendants(); continue }
                if f.pathExtension.lowercased() == "pdf" || isImage(f) || OfficeDoc.exts.contains(f.pathExtension.lowercased()) { found.append(f) }
                if found.count >= maxFilesPerDrop { break }
            }
            if found.isEmpty { empty.append(u.lastPathComponent) }
            out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return (out, empty)
    }

    /// 一份檔案能不能壓。能＝.success(資訊)；不能＝.failure((原因, 檔名))
    static func check(_ url: URL) -> Result<PDFInfo, SkipError> {
        let name = url.lastPathComponent
        let fm = FileManager.default
        if isImage(url) { return checkImage(url) }
        if OfficeDoc.isOffice(url) { return OfficeDoc.check(url) }
        guard url.pathExtension.lowercased() == "pdf" else { return .failure(SkipError(code: .notPDF, name: name)) }
        guard fm.isReadableFile(atPath: url.path) else { return .failure(SkipError(code: .unreadable, name: name)) }
        let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { return .failure(SkipError(code: .empty, name: name)) }

        // 副檔名是 .pdf 不代表真的是 PDF：開頭 1 KB 內要看得到 %PDF-
        guard let h = FileHandle(forReadingAtPath: url.path) else { return .failure(SkipError(code: .unreadable, name: name)) }
        let head = h.readData(ofLength: 1024)
        try? h.close()
        guard head.range(of: Data("%PDF-".utf8)) != nil else { return .failure(SkipError(code: .damaged, name: name)) }

        guard let doc = PDFDocument(url: url) else { return .failure(SkipError(code: .damaged, name: name)) }
        // 有密碼：Slimly 不破解、也不繞過（連「只限制列印／複製」的權限密碼也一樣——壓完的檔會失去那層保護）
        if doc.isLocked { return .failure(SkipError(code: .locked, name: name)) }
        if doc.isEncrypted { return .failure(SkipError(code: .protected, name: name)) }
        let pages = doc.pageCount
        guard pages > 0 else { return .failure(SkipError(code: .damaged, name: name)) }

        var producer = "", creator = "", signed = false, hasForm = false
        if let cg = CGPDFDocument(url as CFURL) {
            if let info = cg.info {
                producer = pdfString(info, "Producer") ?? ""
                creator = pdfString(info, "Creator") ?? ""
            }
            if let cat = cg.catalog {
                var acro: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(cat, "AcroForm", &acro), let acro {
                    var flags: CGPDFInteger = 0
                    if CGPDFDictionaryGetInteger(acro, "SigFlags", &flags), flags & 1 != 0 { signed = true }
                    var fields: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(acro, "Fields", &fields), let fields, CGPDFArrayGetCount(fields) > 0 {
                        hasForm = true
                        var budget = 3000
                        if scanSigned(fields, depth: 0, budget: &budget) { signed = true }
                    }
                }
            }
        }
        var info = PDFInfo(url: url, bytes: bytes, pages: pages, signed: signed, hasForm: hasForm,
                           producer: producer, creator: creator)
        if let cg = CGPDFDocument(url as CFURL) {
            info.iccNew = hasNewICC(cg)
            if let d = cg.info, pdfString(d, "SlimlyVersion") != nil { info.slimmed = true }
        }
        return .success(info)
    }

    /// 照片：讀得到、不是空的、ImageIO 解得開（副檔名對但內容不是圖＝打不開）
    static func checkImage(_ url: URL) -> Result<PDFInfo, SkipError> {
        let name = url.lastPathComponent, fm = FileManager.default
        guard fm.isReadableFile(atPath: url.path) else { return .failure(SkipError(code: .unreadable, name: name)) }
        let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { return .failure(SkipError(code: .empty, name: name)) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return .failure(SkipError(code: .damaged, name: name)) }
        let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let t = (CGImageSourceGetType(src) as String?) ?? ""
        var info = PDFInfo(url: url, bytes: bytes, pages: 1, signed: false, hasForm: false, producer: "", creator: "")
        info.kind = .image
        info.width = o >= 5 ? h : w; info.height = o >= 5 ? w : h
        info.alpha = (p[kCGImagePropertyHasAlpha] as? Bool) ?? false
        info.format = t.contains("heic") || t.contains("heif") ? "HEIC" : t.contains("png") ? "PNG" : "JPEG"
        return .success(info)
    }

    /// 有沒有圖片用了 ICC v4.1 以上的色彩描述檔（只讀；每個描述檔只解一次，最多看 3000 張圖）
    static func hasNewICC(_ doc: CGPDFDocument) -> Bool {
        var seen = Set<Int>()
        var budget = 3000
        func iccIsNew(_ cs: CGPDFObjectRef) -> Bool {
            var arr: CGPDFArrayRef?
            guard CGPDFObjectGetValue(cs, .array, &arr), let arr, CGPDFArrayGetCount(arr) >= 2 else { return false }
            var name: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(arr, 0, &name), let name else { return false }
            let n = String(cString: name)
            if n == "Indexed" {                                          // [/Indexed 底色空間 …]：看底色空間
                var base: CGPDFObjectRef?
                return CGPDFArrayGetObject(arr, 1, &base) && base != nil && iccIsNew(base!)
            }
            guard n == "ICCBased" else { return false }
            var st: CGPDFStreamRef?
            guard CGPDFArrayGetStream(arr, 1, &st), let st else { return false }
            let key = unsafeBitCast(st, to: Int.self)       // 同一個描述檔物件只解一次
            if seen.contains(key) { return false }
            seen.insert(key)
            var fmt: CGPDFDataFormat = .raw
            guard let data = CGPDFStreamCopyData(st, &fmt) as Data?, data.count > 40,
                  data[36] == 0x61, data[37] == 0x63, data[38] == 0x73, data[39] == 0x70 else { return false }   // "acsp"
            let major = Int(data[8]), minor = Int(data[9] >> 4)
            return major > 4 || (major == 4 && minor > 0)
        }
        func scan(_ res: CGPDFDictionaryRef?, depth: Int) -> Bool {
            guard let res, depth < 4 else { return false }
            var xo: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return false }
            var found = false
            CGPDFDictionaryApplyBlock(xo, { _, obj, _ in
                budget -= 1
                if budget < 0 { return false }
                var st: CGPDFStreamRef?
                guard CGPDFObjectGetValue(obj, .stream, &st), let st, let d = CGPDFStreamGetDictionary(st) else { return true }
                var sub: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(d, "Subtype", &sub), let sub else { return true }
                switch String(cString: sub) {
                case "Image":
                    var cs: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(d, "ColorSpace", &cs), let cs, iccIsNew(cs) { found = true; return false }
                case "Form":
                    var r: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(d, "Resources", &r), scan(r, depth: depth + 1) { found = true; return false }
                default: break
                }
                return true
            }, nil)
            return found
        }
        let n = doc.numberOfPages
        guard n > 0 else { return false }
        for i in 1...n {
            guard let page = doc.page(at: i), let pd = page.dictionary else { continue }
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pd, "Resources", &res), scan(res, depth: 0) { return true }
            if budget < 0 { break }
        }
        return false
    }

    /// 表單欄位裡有沒有「已經簽了名」的簽章欄（/FT /Sig 而且有 /V）
    private static func scanSigned(_ arr: CGPDFArrayRef, depth: Int, budget: inout Int) -> Bool {
        guard depth < 6 else { return false }
        for i in 0..<CGPDFArrayGetCount(arr) {
            budget -= 1
            if budget < 0 { return false }
            var f: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(arr, i, &f), let f else { continue }
            var ft: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(f, "FT", &ft), let ft, String(cString: ft) == "Sig" {
                var v: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(f, "V", &v), v != nil { return true }
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(f, "Kids", &kids), let kids, scanSigned(kids, depth: depth + 1, budget: &budget) { return true }
        }
        return false
    }

    private static func pdfString(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var s: CGPDFStringRef?
        guard CGPDFDictionaryGetString(d, key, &s), let s, let cf = CGPDFStringCopyTextString(s) else { return nil }
        return cf as String
    }

    /// 同一份檔的頁數（壓完驗收用；打不開回 nil）
    static func pageCount(_ url: URL) -> Int? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        return doc.pageCount
    }
}

struct SkipError: Error {
    let code: SkipCode
    let name: String
}
