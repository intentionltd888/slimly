// Guard.swift — 壓完看一眼：抽幾頁把原檔跟壓好的都畫成小圖，差太多就不交出去
//
// 為什麼要有：盤點 47 份實檔，Chrome 列印的一份（圖帶 ICC v4.3 色彩描述檔）壓完小了 77%、
// 頁數也對，但第 1 頁有 5% 的彩色元素不見了——只驗頁數會照樣交出去。Canva 的一份整片灰變橘紅。
// 這裡只看「看起來還是不是同一份」：壓縮該有的差異（JPEG 雜訊、降解析度）在小圖上幾乎看不到，
// 東西不見、整片變色會很明顯。門檻用那 47 份的正常輸出與壞輸出校準（見 tests/guardcheck.swift）：
// 用 172 對（各級、原參數與修正參數）校準：正常壓縮最糟 0.91%（連 100 dpi 那級都算），
// 壞掉的 2.2%–100%（缺圖、變色、Mac 畫不出來、頁面被轉向）；門檻 1.5% 在中間。深級細線很多的平面圖會到 2.8%＝變糊，
// 交給呼叫端退回第一級。
import AppKit
import PDFKit

enum VisualGuard {
    /// 一頁「明顯變了」的格子比例上限（8×8 像素一格取平均，任一色版差超過 diffLevel 算變了）
    static let maxDiffFraction = 0.015
    static let diffLevel = 24
    /// 小圖的長邊（像素）
    static let side = 320

    struct Page { let index: Int; let fraction: Double; let mean: Double }

    /// 抽樣比對。回傳最糟的那一頁（nil＝打不開，交給呼叫端當失敗處理）
    static func worstPage(original: URL, output: URL) -> Page? {
        guard let a = PDFDocument(url: original), let b = PDFDocument(url: output),
              a.pageCount == b.pageCount, a.pageCount > 0 else { return nil }
        var worst: Page? = nil
        for i in samplePages(a.pageCount) {
            guard let pa = a.page(at: i), let pb = b.page(at: i) else { return nil }
            guard let ra = render(pa), let rb = render(pb, like: ra) else { return nil }
            let p = compare(ra, rb, index: i)
            if worst == nil || p.fraction > worst!.fraction { worst = p }
        }
        return worst
    }

    /// 拆出來的一份：它的第 0 頁對原檔的第 firstPage 頁（0 起算），一路比到它的最後一頁
    static func worstPage(original: URL, output: URL, firstPage: Int) -> Page? {
        guard let a = PDFDocument(url: original), let b = PDFDocument(url: output),
              b.pageCount > 0, firstPage >= 0, firstPage + b.pageCount <= a.pageCount else { return nil }
        var worst: Page? = nil
        for i in samplePages(b.pageCount) {
            guard let pa = a.page(at: firstPage + i), let pb = b.page(at: i) else { return nil }
            guard let ra = render(pa), let rb = render(pb, like: ra) else { return nil }
            let p = compare(ra, rb, index: i)
            if worst == nil || p.fraction > worst!.fraction { worst = p }
        }
        return worst
    }

    static func passes(_ p: Page) -> Bool { p.fraction <= maxDiffFraction }

    /// 每一頁都看（壞掉的頁不一定在前面：實測一份 47 頁的只壞第 10 頁）；超過 300 頁平均抽 300 頁
    static func samplePages(_ n: Int) -> [Int] {
        if n <= 300 { return Array(0..<n) }
        return (0..<300).map { Int(Double(n - 1) * Double($0) / 299.0) }
    }

    struct Bitmap { let w: Int; let h: Int; let px: [UInt8] }

    private static func render(_ page: PDFPage, like ref: Bitmap? = nil) -> Bitmap? {
        let box = page.bounds(for: .mediaBox)
        var w = ref?.w ?? 0, h = ref?.h ?? 0
        if ref == nil {
            // 顯示方向（含 /Rotate）的長寬
            let rot = abs(page.rotation) % 180 == 90
            let pw = rot ? box.height : box.width, ph = rot ? box.width : box.height
            guard pw > 0, ph > 0 else { return nil }
            let k = Double(side) / Double(max(pw, ph))
            w = max(8, Int((pw * k).rounded())); h = max(8, Int((ph * k).rounded()))
        }
        let img = page.thumbnail(of: NSSize(width: w, height: h), for: .mediaBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))   // 縮圖留白置中的差異兩邊一樣
            return true
        }
        return ok ? Bitmap(w: w, h: h, px: px) : nil
    }

    /// 比法：兩張小圖各自切成 8×8 像素的格子取平均色，再比每一格（任一色版差超過 diffLevel 算「這格變了」）。
    /// 取平均是為了只看「整塊的東西」：東西不見、變色、畫錯位置會讓整片格子變；重新取樣造成的邊緣變柔、JPEG 雜訊平均掉就沒了
    /// （逐像素比會把照片的銳利邊緣也算成變了：實測一頁滿版照片的正常輸出逐像素 2.5%、分格 0%）。
    private static func compare(_ a: Bitmap, _ b: Bitmap, index: Int) -> Page {
        let cell = 8
        let cw = max(1, a.w / cell), ch = max(1, a.h / cell)
        var changed = 0, sum = 0
        a.px.withUnsafeBufferPointer { pa in
            b.px.withUnsafeBufferPointer { pb in
                for cy in 0..<ch {
                    for cx in 0..<cw {
                        var s0 = [0, 0, 0], s1 = [0, 0, 0]
                        for y in (cy * cell)..<min(a.h, (cy + 1) * cell) {
                            for x in (cx * cell)..<min(a.w, (cx + 1) * cell) {
                                let o = (y * a.w + x) * 4
                                s0[0] += Int(pa[o]); s0[1] += Int(pa[o + 1]); s0[2] += Int(pa[o + 2])
                                s1[0] += Int(pb[o]); s1[1] += Int(pb[o + 1]); s1[2] += Int(pb[o + 2])
                            }
                        }
                        let n = cell * cell
                        let d = max(abs(s0[0] - s1[0]), abs(s0[1] - s1[1]), abs(s0[2] - s1[2])) / n
                        sum += d
                        if d > diffLevel { changed += 1 }
                    }
                }
            }
        }
        let cells = cw * ch
        return Page(index: index, fraction: Double(changed) / Double(max(1, cells)), mean: Double(sum) / Double(max(1, cells)))
    }
}
