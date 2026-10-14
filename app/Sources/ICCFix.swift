// ICCFix.swift — 圖帶 ICC v4.1 以上色彩描述檔的 PDF：送進 gs 之前，在副本裡把描述檔的版本欄改成 4.0
//
// 為什麼：Ghostscript 10.08 碰到 v4.1 以上的描述檔（Chrome／Skia 印的 P3 圖、Canva、部分 Keynote）會把圖拆成上千條、
// 整片變色、掉元素，而且很慢（盤點：Canva 83 頁第一級 12.5 分鐘、變 263 MB）。描述檔的內容 gs 讀得懂，擋的是版本號：
// 版本欄（位元組 8–11）改成 4.0，同一份 51 秒、12.3 MB、顏色對。試過 2.1、4.1、4.2 都一樣壞，只有 4.0 行。
// 描述檔 ID（位元組 84–99，對內容算的 MD5）一起清成 0（＝規格裡的「沒算」）：版本欄改了，舊的 ID 就對不上了。
// 壓完的檔照樣帶這份描述檔，色彩管理不變。不能用 gs 的 -dOverrideICC：那會把描述檔丟掉，P3 的圖在 Mac 上會變灰。
//
// 做法：不重寫整份 PDF，在副本尾端加一段「增量更新」（PDF 標準的改版方式；在預覽程式裡加註解存檔也是這樣）：
// 改好的描述檔物件（不壓縮，幾 KB）＋一段新的交叉參照表，指回原本那段。原檔只讀；副本放在這一份的工作夾，做完跟著收掉。
// 看不懂的就放棄（加密、描述檔有特殊編碼參數、找不到交叉參照表、改完 macOS 讀出來還是舊版本），回 nil，呼叫端照原檔壓。
import Foundation
import Compression
import CoreGraphics

enum ICCFix {
    private struct Patch { let num: Int; let gen: Int; let dict: String; let body: Data }

    /// 回傳改好的副本（在 dir 裡）；沒有要改的、或結構看不懂＝nil
    static func patchedCopy(of src: URL, in dir: URL) -> URL? {
        guard let data = try? Data(contentsOf: src, options: .alwaysMapped) else { return nil }
        let (patches, trailer) = data.withUnsafeBytes { raw -> ([Patch], Trailer?) in
            let b = raw.bindMemory(to: UInt8.self)
            return (findPatches(b), readTrailer(b))
        }
        guard !patches.isEmpty, let t = trailer else { return nil }
        let out = dir.appendingPathComponent("iccfix-\(UUID().uuidString.prefix(8)).pdf")
        do {
            try FileManager.default.copyItem(at: src, to: out)        // APFS 上是複本（clone），不多佔空間
            let fh = try FileHandle(forWritingTo: out)
            defer { try? fh.close() }
            var pos = try fh.seekToEnd()
            func w(_ d: Data) { fh.write(d); pos += UInt64(d.count) }
            func w(_ s: String) { w(Data(s.utf8)) }
            if let last = data.last, last != 0x0A, last != 0x0D { w("\n") }
            var offs: [(num: Int, gen: Int, off: UInt64)] = []
            for p in patches.sorted(by: { $0.num < $1.num }) {
                offs.append((p.num, p.gen, pos))
                w("\(p.num) \(p.gen) obj\n\(p.dict)\nstream\n"); w(p.body); w("\nendstream\nendobj\n")
            }
            let extra = (t.info.map { " /Info \($0)" } ?? "") + (t.id.map { " /ID \($0)" } ?? "")
            if t.classic {
                let xoff = pos
                var s = "xref\n"
                for o in offs { s += "\(o.num) 1\n" + String(format: "%010llu %05d n\r\n", o.off, o.gen) }   // 每筆剛好 20 位元組
                s += "trailer\n<< /Size \(t.size) /Root \(t.root)\(extra) /Prev \(t.prev) >>\nstartxref\n\(xoff)\n%%EOF\n"
                w(s)
            } else {
                // 原檔用的是交叉參照「串流」（PDF 1.5 起）：更新段也用串流，新物件號＝原本的 /Size
                let xnum = t.size, xoff = pos
                var rows = Data()
                func row(_ off: UInt64, _ gen: Int) {
                    rows.append(1)
                    for k in (0..<5).reversed() { rows.append(UInt8((off >> (8 * UInt64(k))) & 0xFF)) }
                    rows.append(UInt8((gen >> 8) & 0xFF)); rows.append(UInt8(gen & 0xFF))
                }
                for o in offs { row(o.off, o.gen) }
                row(xoff, 0)
                let index = offs.map { "\($0.num) 1" }.joined(separator: " ") + " \(xnum) 1"
                w("\(xnum) 0 obj\n<< /Type /XRef /Size \(xnum + 1) /W [1 5 2] /Index [\(index)] /Root \(t.root)\(extra) /Prev \(t.prev) /Length \(rows.count) >>\nstream\n")
                w(rows)
                w("\nendstream\nendobj\nstartxref\n\(xoff)\n%%EOF\n")
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        // 驗收：macOS 自己的 PDF 引擎讀得出來、頁數一樣、而且看到的描述檔都已經是 4.0（＝增量更新真的生效）
        guard let a = CGPDFDocument(src as CFURL), let b = CGPDFDocument(out as CFURL),
              a.numberOfPages == b.numberOfPages, b.numberOfPages > 0, !Inspect.hasNewICC(b) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    // MARK: 找出要改的描述檔

    private static func findPatches(_ b: UnsafeBufferPointer<UInt8>) -> [Patch] {
        var byNum: [Int: Patch] = [:]                     // 同一個物件號出現好幾次（改過版的檔）：以檔案裡最後一份為準
        var i = 0
        let n = b.count
        while let hit = find(b, "stream", from: i) {
            i = hit + 6
            if hit >= 3, b[hit - 3] == 0x65, b[hit - 2] == 0x6E, b[hit - 1] == 0x64 { continue }   // endstream
            if hit > 0, !(isWS(b[hit - 1]) || b[hit - 1] == 0x3E) { continue }                    // 前面要是空白或 >>
            // 資料從關鍵字後的換行開始（CRLF 或 LF；單獨 CR 不合規但有人這樣寫）
            var start = hit + 6
            guard start < n else { break }
            if b[start] == 0x0D, start + 1 < n, b[start + 1] == 0x0A { start += 2 }
            else if b[start] == 0x0A || b[start] == 0x0D { start += 1 }
            else { continue }
            // 描述檔的字典很短：先在關鍵字前 400 位元組看有沒有 /N、有沒有 /Subtype，省下大部分解析
            let win = String(decoding: b[max(0, hit - 400)..<hit], as: UTF8.self)
            guard win.contains("/N"), let objAt = objHeader(b, before: hit) else { continue }
            guard let (dictRange, after) = parseDict(b, from: objAt.bodyStart), skipWS(b, after) == hit else { continue }
            let dict = String(bytes: b[dictRange], encoding: .isoLatin1) ?? ""
            guard dict.range(of: #"/N\s+\d"#, options: .regularExpression) != nil,
                  !dict.contains("/Subtype"), !dict.contains("/Type"), !dict.contains("/DecodeParms") else { continue }
            let flate: Bool
            if let f = dict.range(of: #"/Filter\s*(\[\s*)?/(\w+)"#, options: .regularExpression) {
                guard dict[f].hasSuffix("/FlateDecode"), dict.range(of: #"/Filter\s*\[\s*/FlateDecode\s*/"#, options: .regularExpression) == nil else { continue }
                flate = true
            } else { flate = false }
            guard let end = streamEnd(b, dict: dict, start: start), end - start <= 16 << 20 else { continue }
            let payload = Data(b[start..<end])
            guard var icc = flate ? inflate(payload) : payload, icc.count >= 128 else { continue }
            // "acsp" 簽名在 36–39；版本在 8（主）、9 的高 4 位（次）
            guard icc[36] == 0x61, icc[37] == 0x63, icc[38] == 0x73, icc[39] == 0x70 else { continue }
            let major = Int(icc[8]), minor = Int(icc[9] >> 4)
            guard major > 4 || (major == 4 && minor > 0) else { continue }
            icc[8] = 4; icc[9] = 0; icc[10] = 0; icc[11] = 0
            for k in 84..<100 { icc[k] = 0 }
            byNum[objAt.num] = Patch(num: objAt.num, gen: objAt.gen, dict: rewriteDict(dict, length: icc.count), body: icc)
        }
        return Array(byNum.values)
    }

    /// 字典去掉 /Length、/Filter，換成未壓縮的長度
    private static func rewriteDict(_ d: String, length: Int) -> String {
        var s = d
        for p in [#"/Length\s+\d+(\s+\d+\s+R)?"#, #"/Filter\s*(\[[^\]]*\]|/\w+)"#] {
            while let r = s.range(of: p, options: .regularExpression) { s.replaceSubrange(r, with: "") }
        }
        guard let close = s.range(of: ">>", options: .backwards) else { return "<< /Length \(length) >>" }
        s.replaceSubrange(close, with: " /Length \(length) >>")
        return s
    }

    /// 串流資料結尾：/Length 是直接的數字而且後面真的接 endstream＝照它；否則往後找 endstream、扣掉前面的換行
    private static func streamEnd(_ b: UnsafeBufferPointer<UInt8>, dict: String, start: Int) -> Int? {
        if let m = dict.range(of: #"/Length\s+(\d+)(\s+\d+\s+R)?"#, options: .regularExpression) {
            let t = dict[m]
            if !t.hasSuffix("R"), let len = Int(t.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).last ?? "") {
                let e = start + len
                if e <= b.count {
                    var k = e
                    while k < b.count, isWS(b[k]) { k += 1 }
                    if k + 9 <= b.count, matches(b, k, "endstream") { return e }
                }
            }
        }
        guard var e = find(b, "endstream", from: start) else { return nil }
        if e > start, b[e - 1] == 0x0A { e -= 1; if e > start, b[e - 1] == 0x0D { e -= 1 } }
        else if e > start, b[e - 1] == 0x0D { e -= 1 }
        return e
    }

    // MARK: 交叉參照表（增量更新要接在它後面）

    private struct Trailer { let classic: Bool; let prev: Int; let size: Int; let root: String; let info: String?; let id: String? }

    private static func readTrailer(_ b: UnsafeBufferPointer<UInt8>) -> Trailer? {
        let n = b.count
        guard let sx = rfind(b, "startxref", from: n, limit: 4096) else { return nil }
        let k = skipWS(b, sx + 9)
        guard let (prev, _) = readInt(b, k), prev > 0, prev < n else { return nil }
        let at = skipWS(b, prev)
        let dictText: String
        let classic: Bool
        if matches(b, at, "xref") {
            guard let tr = find(b, "trailer", from: at), let (r, _) = parseDict(b, from: skipWS(b, tr + 7)) else { return nil }
            dictText = String(bytes: b[r], encoding: .isoLatin1) ?? ""
            classic = true
        } else {
            // 「N G obj << /Type /XRef … >> stream」
            guard let (_, a1) = readInt(b, at), let (_, a2) = readInt(b, skipWS(b, a1)) else { return nil }
            let o = skipWS(b, a2)
            guard matches(b, o, "obj"), let (r, _) = parseDict(b, from: skipWS(b, o + 3)) else { return nil }
            dictText = String(bytes: b[r], encoding: .isoLatin1) ?? ""
            guard dictText.contains("/XRef") else { return nil }
            classic = false
        }
        func grab(_ p: String) -> String? {
            guard let m = dictText.range(of: p, options: .regularExpression) else { return nil }
            return String(dictText[m])
        }
        guard !dictText.contains("/Encrypt"),
              let sizeS = grab(#"/Size\s+\d+"#), let size = Int(sizeS.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)),
              let rootS = grab(#"/Root\s+\d+\s+\d+\s+R"#) else { return nil }
        let root = rootS.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        let info = grab(#"/Info\s+\d+\s+\d+\s+R"#).map { $0.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines) }
        let id = grab(#"/ID\s*\[\s*(<[0-9A-Fa-f\s]*>\s*){2}\]"#).map { String($0.drop(while: { $0 != "[" })) }
        return Trailer(classic: classic, prev: prev, size: size, root: root, info: info, id: id)
    }

    // MARK: 小工具（位元組層級；PDF 的語法只用到這些）

    private static func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func matches(_ b: UnsafeBufferPointer<UInt8>, _ i: Int, _ s: String) -> Bool {
        let u = Array(s.utf8)
        guard i >= 0, i + u.count <= b.count else { return false }
        for (k, c) in u.enumerated() where b[i + k] != c { return false }
        return true
    }

    private static func find(_ b: UnsafeBufferPointer<UInt8>, _ s: String, from: Int) -> Int? {
        let u = Array(s.utf8)
        guard from >= 0, from < b.count, let base = b.baseAddress else { return nil }
        return u.withUnsafeBufferPointer { nb -> Int? in
            guard let r = memmem(base + from, b.count - from, nb.baseAddress!, u.count) else { return nil }
            return base.distance(to: r.assumingMemoryBound(to: UInt8.self))
        }
    }

    private static func rfind(_ b: UnsafeBufferPointer<UInt8>, _ s: String, from: Int, limit: Int) -> Int? {
        let u = Array(s.utf8)
        var i = min(from, b.count) - u.count
        let stop = max(0, from - limit)
        while i >= stop {
            if b[i] == u[0], matches(b, i, s) { return i }
            i -= 1
        }
        return nil
    }

    private static func skipWS(_ b: UnsafeBufferPointer<UInt8>, _ i0: Int) -> Int {
        var i = i0
        while i < b.count {
            if isWS(b[i]) { i += 1; continue }
            if b[i] == 0x25 {                                     // % 註解到行尾
                while i < b.count, b[i] != 0x0A, b[i] != 0x0D { i += 1 }
                continue
            }
            break
        }
        return i
    }

    private static func readInt(_ b: UnsafeBufferPointer<UInt8>, _ i0: Int) -> (Int, Int)? {
        var i = i0, v = 0, any = false
        while i < b.count, isDigit(b[i]) { v = v * 10 + Int(b[i] - 0x30); i += 1; any = true; if v > 1 << 40 { return nil } }
        return any ? (v, i) : nil
    }

    /// 「stream」關鍵字前面最近的「N G obj」；回傳物件號、世代號、obj 後面的位置
    private static func objHeader(_ b: UnsafeBufferPointer<UInt8>, before hit: Int) -> (num: Int, gen: Int, bodyStart: Int)? {
        var i = hit - 3
        let stop = max(0, hit - (256 << 10))
        while i >= stop {
            if b[i] == 0x6F, b[i + 1] == 0x62, b[i + 2] == 0x6A {        // "obj"
                let isEnd = i >= 3 && b[i - 3] == 0x65 && b[i - 2] == 0x6E && b[i - 1] == 0x64
                let next = i + 3 < b.count ? b[i + 3] : 0x20
                if !isEnd, i > 0, isWS(b[i - 1]), isWS(next) || next == 0x3C || next == 0x25 {
                    // 往回讀「世代號 空白 物件號」
                    var j = i - 1
                    while j > 0, isWS(b[j]) { j -= 1 }
                    var gEnd = j + 1
                    while j >= 0, isDigit(b[j]) { j -= 1 }
                    guard j + 1 < gEnd, let (gen, _) = readInt(b, j + 1) else { return nil }
                    while j > 0, isWS(b[j]) { j -= 1 }
                    gEnd = j + 1
                    while j >= 0, isDigit(b[j]) { j -= 1 }
                    guard j + 1 < gEnd, let (num, _) = readInt(b, j + 1) else { return nil }
                    return (num, gen, i + 3)
                }
            }
            i -= 1
        }
        return nil
    }

    /// 從 i 起解析一個字典 << … >>（處理巢狀、字串、十六進位字串、註解）；回傳範圍與結尾後的位置
    private static func parseDict(_ b: UnsafeBufferPointer<UInt8>, from i0: Int) -> (Range<Int>, Int)? {
        let s = skipWS(b, i0)
        guard matches(b, s, "<<") else { return nil }
        var i = s, depth = 0
        while i < b.count {
            let c = b[i]
            if c == 0x3C, i + 1 < b.count, b[i + 1] == 0x3C { depth += 1; i += 2; continue }
            if c == 0x3E, i + 1 < b.count, b[i + 1] == 0x3E {
                depth -= 1; i += 2
                if depth == 0 { return (s..<i, i) }
                continue
            }
            if c == 0x28 {                                          // ( 字串 )，可巢狀、可跳脫
                var lv = 1; i += 1
                while i < b.count, lv > 0 {
                    if b[i] == 0x5C { i += 2; continue }
                    if b[i] == 0x28 { lv += 1 } else if b[i] == 0x29 { lv -= 1 }
                    i += 1
                }
                continue
            }
            if c == 0x3C {                                          // < 十六進位字串 >
                while i < b.count, b[i] != 0x3E { i += 1 }
                i += 1; continue
            }
            if c == 0x25 { while i < b.count, b[i] != 0x0A, b[i] != 0x0D { i += 1 }; continue }
            i += 1
            if i - s > 64 << 10 { return nil }                      // 字典不會這麼長：當成看不懂
        }
        return nil
    }

    /// FlateDecode（zlib 包裝的 DEFLATE）解開
    private static func inflate(_ d: Data) -> Data? {
        var src = [UInt8](d)
        if src.count >= 2, src[0] & 0x0F == 8, (Int(src[0]) << 8 | Int(src[1])) % 31 == 0 { src.removeFirst(2) }
        guard !src.isEmpty else { return nil }
        var cap = max(1 << 16, src.count * 16)
        while cap <= 1 << 26 {
            var dst = [UInt8](repeating: 0, count: cap)
            let got = compression_decode_buffer(&dst, cap, src, src.count, nil, COMPRESSION_ZLIB)
            if got == 0 { return nil }
            if got < cap { return Data(dst[0..<got]) }
            cap *= 4
        }
        return nil
    }
}
