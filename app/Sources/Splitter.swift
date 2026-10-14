// Splitter.swift — 壓到最小還是超過目標：依頁拆成幾份，每份都在目標以下
//
// 情境：大作品集、掃描檔壓完還是 40 MB，Gmail 寄不出去。「拆開寄」把它拆成幾份（例如 3 份），每封信各帶一份，不必改用雲端連結。
// 拆的是已經壓好的那一份（畫質不再動）：用 macOS 自己的 PDF 引擎（PDFKit）照頁搬進新檔，不重新壓圖。
// 做法：先量每頁單獨存的大小（估重），照順序裝箱；存出來真的超過就對半再拆；最後相鄰兩份合得起來就合（份數越少越好寄）。
// 每一份都驗頁數，並逐頁畫小圖跟來源比（VisualGuard，同壓完的那道關）。單一頁就超過目標的，那一份會標出來。
import Foundation
import PDFKit

enum Splitter {
    struct Part {
        var url: URL
        let bytes: Int64
        let first: Int        // 第幾頁起（1 起算）
        let last: Int
        var over: Bool        // 單頁就超過目標，拆不下去
    }
    enum Failure: Error { case unreadable, write, verify(page: Int) }

    /// 拆好放在 work（還沒搬到最後的位置）。onProgress：給介面／命令列顯示「正在存第幾份」
    static func split(_ src: URL, limit: Int64, work: URL, onProgress: ((Int, Int) -> Void)? = nil) -> Result<[Part], Failure> {
        guard let doc = PDFDocument(url: src), !doc.isLocked, doc.pageCount > 0 else { return .failure(.unreadable) }
        let n = doc.pageCount
        // ① 估重：每頁單獨存一份量大小（頁數多時幾頁一組，最多量 200 次）
        let chunk = max(1, Int((Double(n) / 200).rounded(.up)))
        var weight = [Int64](repeating: 0, count: n)
        var i = 0
        while i < n {
            let r = i..<min(n, i + chunk)
            guard let d = makeDoc(doc, r)?.dataRepresentation() else { return .failure(.write) }
            for k in r { weight[k] = Int64(d.count) / Int64(r.count) }
            i += chunk
        }
        // ② 裝箱：照順序放，放不下就換下一份（留 8% 餘裕：單頁量的大小把共用的字型重複算了，合起來通常更小）
        let budget = Int64(Double(limit) * 0.92)
        var ranges: [Range<Int>] = []
        var start = 0, sum: Int64 = 0
        for k in 0..<n {
            if k > start, sum + weight[k] > budget { ranges.append(start..<k); start = k; sum = 0 }
            sum += weight[k]
        }
        ranges.append(start..<n)
        // ③ 存出來；真的超過就對半再拆
        var parts: [(Range<Int>, URL, Int64)] = []
        var queue = ranges
        var seq = 0
        while !queue.isEmpty {
            let r = queue.removeFirst()
            seq += 1
            let url = work.appendingPathComponent("part-\(seq).pdf")
            guard let d = makeDoc(doc, r), d.write(to: url) else { return .failure(.write) }
            let bytes = fileSize(url)
            if bytes > limit, r.count > 1 {
                let mid = r.lowerBound + r.count / 2
                queue.insert(contentsOf: [r.lowerBound..<mid, mid..<r.upperBound], at: 0)
                try? FileManager.default.removeItem(at: url)
                continue
            }
            parts.append((r, url, bytes))
            onProgress?(parts.count, parts.count + queue.count)
        }
        parts.sort { $0.0.lowerBound < $1.0.lowerBound }
        // ④ 相鄰兩份合得起來就合
        var merged = true
        while merged, parts.count > 1 {
            merged = false
            for k in 0..<(parts.count - 1) where parts[k].2 + parts[k + 1].2 <= limit {
                let r = parts[k].0.lowerBound..<parts[k + 1].0.upperBound
                seq += 1
                let url = work.appendingPathComponent("part-\(seq).pdf")
                guard let d = makeDoc(doc, r), d.write(to: url) else { return .failure(.write) }
                let bytes = fileSize(url)
                if bytes <= limit {
                    try? FileManager.default.removeItem(at: parts[k].1)
                    try? FileManager.default.removeItem(at: parts[k + 1].1)
                    parts.replaceSubrange(k...(k + 1), with: [(r, url, bytes)])
                    merged = true
                    break
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
        // ⑤ 驗收：頁數、逐頁畫面（跟來源的那幾頁比）
        var out: [Part] = []
        for (r, url, bytes) in parts {
            guard let d = PDFDocument(url: url), d.pageCount == r.count else { return .failure(.verify(page: r.lowerBound + 1)) }
            guard let w = VisualGuard.worstPage(original: src, output: url, firstPage: r.lowerBound) else {
                return .failure(.verify(page: r.lowerBound + 1))
            }
            if !VisualGuard.passes(w) { return .failure(.verify(page: r.lowerBound + w.index + 1)) }
            out.append(Part(url: url, bytes: bytes, first: r.lowerBound + 1, last: r.upperBound, over: bytes > limit))
        }
        return .success(out)
    }

    /// 搬到 dir：「品牌提案（已壓縮 1／3）.pdf」；同名已存在就加號碼，永不覆蓋
    static func place(_ parts: [Part], dir: URL, compressedName: String) throws -> [Part] {
        let stem = (compressedName as NSString).deletingPathExtension
        let n = parts.count
        func name(_ i: Int) -> String {
            if stem.hasSuffix("（已壓縮）") { return String(stem.dropLast(5)) + "（已壓縮 \(i)／\(n)）.pdf" }
            if stem.hasSuffix(" (compressed)") { return String(stem.dropLast(13)) + " (compressed \(i) of \(n)).pdf" }
            return stem + L("（\(i)／\(n)）", " (\(i) of \(n))") + ".pdf"
        }
        var placed: [Part] = []
        do {
            for (k, p) in parts.enumerated() {
                var q = p
                q.url = try Files.moveNoClobber(p.url, into: dir, name: name(k + 1))
                placed.append(q)
            }
        } catch {
            // 放到一半失敗：已經搬過去的留著（都是新檔，不會蓋到東西），把錯誤交給呼叫端講
            throw error
        }
        return placed
    }

    private static func makeDoc(_ doc: PDFDocument, _ r: Range<Int>) -> PDFDocument? {
        let d = PDFDocument()
        for (j, k) in r.enumerated() {
            guard let p = doc.page(at: k)?.copy() as? PDFPage else { return nil }
            d.insert(p, at: j)
        }
        return d
    }

    private static func fileSize(_ u: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
