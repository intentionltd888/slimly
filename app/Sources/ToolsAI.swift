// ToolsAI.swift — 摘要、翻譯：用這台 Mac 裝置端的模型（Apple Intelligence、系統翻譯），檔案不離開電腦
//
// 摘要：FoundationModels（macOS 26 內建的語言模型）。一段一段讀，先列重點，再合成一段總結＋條列。
// 翻譯：Translation（系統翻譯，語言包下載過就離線可用）。保留版面：背景＝原頁拿掉字（Ghostscript），
// 譯文放回原本段落的位置，放不下就縮字。掃描頁用辨識出來的行，原字蓋白再寫譯文。
import AppKit
import CoreText
import Foundation
@_weakLinked import FoundationModels
import NaturalLanguage
import PDFKit
@_weakLinked import Translation

/// 在同步的工具裡等一個 async 呼叫（主執行緒就轉主迴圈等，背景就睡著等）
enum Async {
    final class Box<T>: @unchecked Sendable {
        private var v: Result<T, Error>?
        private let lock = NSLock()
        func set(_ r: Result<T, Error>) { lock.lock(); v = r; lock.unlock() }
        func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return v }
    }
    static func wait<T>(timeout: TimeInterval = 900, _ op: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>()
        Task.detached {
            let r: Result<T, Error>
            do { r = .success(try await op()) } catch { r = .failure(error) }
            box.set(r)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let r = box.get() { return try r.get() }
            if Date() > deadline { throw ToolError.msg(L("逾時（超過 \(Int(timeout)) 秒）", "Timed out")) }
            if Thread.isMainThread { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) } else { usleep(20_000) }
        }
    }
}

@available(macOS 26.0, *)
enum Brain {
    // MARK: 摘要

    /// 摘要：lang＝zh（預設，繁體中文）／en；存一份 .md，畫面上直接顯示
    static func summarize(_ r: ToolRun) throws -> ToolResult {
        guard case .available = SystemLanguageModel.default.availability else {
            throw ToolError.msg(L("這台 Mac 的 Apple Intelligence 沒有開（系統設定 → Apple Intelligence 與 Siri）",
                                  "Apple Intelligence is off on this Mac (System Settings → Apple Intelligence & Siri)"))
        }
        let u = r.inputs[0], d = try PDFs.open(u)
        var text = ""
        for i in 0..<d.pageCount {
            r.progress(L("讀第 \(i + 1)／\(d.pageCount) 頁", "Reading page \(i + 1)/\(d.pageCount)"), 0.3 * Double(i) / Double(d.pageCount))
            if let p = d.page(at: i) { text += OCR.pageText(p) + "\n" }
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 30 else { throw ToolError.msg(L("讀不出足夠的字可以摘要", "Not enough text to summarize")) }
        let en = r.opt.str("lang", "zh") == "en"
        let inst = en ? "You summarize documents. Use English. Be concise and only state what the document says. Copy numbers exactly; never add up, calculate or infer numbers."
                      : "你是文件摘要助手。一律用繁體中文（台灣用語）。簡潔，只講文件裡有的內容，不要補充文件沒有的資訊。數字照原文抄，不要自己加總、計算或推論。"
        // 一段 1500 字左右（裝置端模型一次讀得下的量），照行切
        var chunks: [String] = [], cur = ""
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if cur.count + line.count > 1500, !cur.isEmpty { chunks.append(cur); cur = "" }
            cur += String(line.prefix(1500)) + "\n"
        }
        if !cur.isEmpty { chunks.append(cur) }
        func ask(_ prompt: String) -> String? {
            try? Async.wait(timeout: 180) { try await LanguageModelSession(instructions: inst).respond(to: prompt).content }
        }
        var points: [String] = []
        for (k, c) in chunks.enumerated() {
            if r.isCancelled { break }
            r.progress(L("讀第 \(k + 1)／\(chunks.count) 段", "Reading part \(k + 1)/\(chunks.count)"), 0.3 + 0.6 * Double(k) / Double(chunks.count))
            if let a = ask(en ? "List the 3–5 key points of this part of a document, one line each. Skip filler and repeated sentences:\n\n\(c)" : "列出這段文件的 3–5 個重點，每點一行；重複或湊字數的句子不要列：\n\n\(c)") { points.append(a) }
        }
        guard !points.isEmpty else { throw ToolError.msg(L("模型沒有給出摘要（內容可能被系統的安全規則擋下）", "The model didn’t return a summary")) }
        // 重點太多：先分批濃縮，再合成
        var pool = points
        while pool.joined(separator: "\n").count > 2800 && pool.count > 1 {
            var next: [String] = [], batch = ""
            for p in pool {
                if batch.count + p.count > 2400, !batch.isEmpty { next.append(ask((en ? "Condense into 5 key points:\n\n" : "濃縮成 5 個重點：\n\n") + batch) ?? batch.prefix(1200).description); batch = "" }
                batch += p + "\n"
            }
            if !batch.isEmpty { next.append(ask((en ? "Condense into 5 key points:\n\n" : "濃縮成 5 個重點：\n\n") + batch) ?? batch) }
            if next.count >= pool.count { break }
            pool = next
        }
        r.progress(L("整理成摘要", "Writing the summary"), 0.95)
        let final = ask(en ? "These are the key points of a document. Write a 2–3 sentence overview, then at most 8 bullet points starting with \"- \". Merge duplicates; drop points about filler text.\n\n\(pool.joined(separator: "\n"))"
                           : "以下是一份文件各段的重點。整理成：先一段 2–3 句的總結，再列最多 8 個條列重點（每點用「- 」開頭）。重複的合併；講湊字數、填充內容的不要列。\n\n\(pool.joined(separator: "\n"))") ?? pool.joined(separator: "\n")
        let md = "# \(PDFs.stem(u))" + L("：摘要", " — summary") + "\n\n" + final.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n---\n"
            + L("由這台 Mac 的 Apple Intelligence 在裝置上產生（沒有上傳）；重要內容請對照原文。", "Generated on this Mac by Apple Intelligence (nothing uploaded); check important details against the original.") + "\n"
        let tmp = r.tmp("summary.md")
        try md.write(to: tmp, atomically: true, encoding: .utf8)
        return ToolResult(outputs: [try r.place(tmp, like: u, suffix: L("（摘要）", " (summary)"), ext: "md")], text: final,
                          notes: [L("讀了 \(d.pageCount) 頁、\(chunks.count) 段", "Read \(d.pageCount) pages in \(chunks.count) parts")])
    }

    // MARK: 翻譯

    static let names: [String: (String, String)] = [
        "zh-Hant": ("繁中", "Traditional Chinese"), "zh-Hans": ("簡中", "Simplified Chinese"), "en": ("英文", "English"), "ja": ("日文", "Japanese"),
        "ko": ("韓文", "Korean"), "fr": ("法文", "French"), "de": ("德文", "German"), "es": ("西班牙文", "Spanish"), "it": ("義大利文", "Italian"),
        "pt": ("葡萄牙文", "Portuguese"), "th": ("泰文", "Thai"), "vi": ("越南文", "Vietnamese"), "id": ("印尼文", "Indonesian"),
    ]

    /// 翻譯：to＝目標語言（預設：原文是中文就翻英文，其他翻繁中）；保留版面輸出 PDF
    static func translate(_ r: ToolRun) throws -> ToolResult {
        let u = r.inputs[0], d = try PDFs.open(u)
        let n = d.pageCount
        // 1. 每頁的段落（掃描頁用辨識的行）
        var paras: [[TextMap.Para]] = [], scanned = Set<Int>()
        for i in 0..<n {
            r.progress(L("讀第 \(i + 1)／\(n) 頁", "Reading page \(i + 1)/\(n)"), 0.25 * Double(i) / Double(n))
            guard let p = d.page(at: i) else { paras.append([]); continue }
            if OCR.hasText(p) { paras.append(TextMap.paragraphs(TextMap.lines(p))) }
            else {
                scanned.insert(i)
                let sz = Overlay.displaySize(p)
                paras.append((Raster.page(p, dpi: 250, maxSide: 5000).map { OCR.lines(in: $0) } ?? []).map {
                    TextMap.Para(text: $0.text, rect: CGRect(x: $0.box.minX * sz.width, y: $0.box.minY * sz.height, width: $0.box.width * sz.width, height: $0.box.height * sz.height),
                                 size: $0.box.height * sz.height * 0.8, lines: 1)
                })
            }
        }
        let all = paras.flatMap { $0 }
        guard !all.isEmpty else { throw ToolError.msg(L("讀不出字可以翻譯", "No text to translate")) }
        // 2. 原文是什麼語言
        let rec = NLLanguageRecognizer()
        rec.processString(String(all.map(\.text).joined(separator: " ").prefix(4000)))
        let src: String
        switch rec.dominantLanguage {
        case .traditionalChinese?: src = "zh-Hant"
        case .simplifiedChinese?: src = "zh-Hans"
        case .some(let l): src = l.rawValue
        case nil: src = "en"
        }
        let tgt = r.opt.has("to") ? r.opt.str("to") : (src.hasPrefix("zh") ? "en" : "zh-Hant")
        guard tgt != src else { throw ToolError.msg(L("原文已經是這個語言", "The document is already in that language")) }
        let sl = Locale.Language(identifier: src), tl = Locale.Language(identifier: tgt)
        let status = try Async.wait(timeout: 60) { await LanguageAvailability().status(from: sl, to: tl) }
        let tn = names[tgt].map { L($0.0, $0.1) } ?? tgt, sn = names[src].map { L($0.0, $0.1) } ?? src
        switch status {
        case .installed: break
        case .supported: throw ToolError.msg(L("翻譯語言包還沒下載：系統設定 → 一般 → 語言與地區 → 翻譯語言，下載「\(sn)」與「\(tn)」", "Download the \(sn) and \(tn) languages in System Settings → General → Language & Region → Translation Languages"))
        default: throw ToolError.msg(L("系統翻譯不支援 \(sn) → \(tn)", "System translation doesn’t support \(sn) → \(tn)"))
        }
        // 3. 一句一句翻（整段丟進去，中英混排的段落會被吃掉半段）：重複的句子只翻一次；已經是目標語言、或只有數字符號的句子照抄
        r.progress(L("翻成\(tn)", "Translating to \(tn)"), 0.3)
        let split = all.map { sentences($0.text) }
        var unique: [String] = [], index: [String: Int] = [:]
        let keepRec = NLLanguageRecognizer()
        keepRec.languageConstraints = [NLLanguage(src), NLLanguage(tgt)]
        func keep(_ s: String) -> Bool {
            guard s.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return true }
            keepRec.reset(); keepRec.processString(s)
            return keepRec.dominantLanguage == NLLanguage(tgt) && !(tgt.hasPrefix("zh") == false && s.unicodeScalars.contains { $0.value >= 0x2E80 })
        }
        for s in split.joined() where !keep(s) && index[s] == nil { index[s] = unique.count; unique.append(s) }
        let reqs = unique.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
        let done: [String: String] = reqs.isEmpty ? [:] : try Async.wait(timeout: 900) {
            let s = TranslationSession(installedSource: sl, target: tl)
            let res = try await s.translations(from: reqs)
            return Dictionary(res.compactMap { r in r.clientIdentifier.map { ($0, r.targetText) } }, uniquingKeysWith: { a, _ in a })
        }
        let cjkTarget = ["zh", "ja", "ko"].contains { tgt.hasPrefix($0) }
        var out: [String: String] = [:]
        for (k, ss) in split.enumerated() {
            out["\(k)"] = ss.map { s in index[s].flatMap { done["\($0)"] } ?? s }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .joined(separator: cjkTarget ? "" : " ")
        }
        // 4. 畫：背景（原頁拿掉字；掃描頁＝原圖、原字位置蓋白）＋譯文放回段落位置
        r.progress(L("排版", "Laying out"), 0.7)
        let bgs = Layout.backgrounds(u, pages: n, dpi: 150, work: r.work)
        let tmp = r.tmp("translate.pdf")
        var mb = CGRect.zero
        guard let ctx = CGContext(tmp as CFURL, mediaBox: &mb, nil) else { throw ToolError.msg(L("寫不出 PDF", "Couldn’t create the PDF")) }
        var k = 0
        for i in 0..<n {
            guard let p = d.page(at: i) else { continue }
            let sz = Overlay.displaySize(p)
            var rr = CGRect(origin: .zero, size: sz)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &rr, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            if !scanned.contains(i), let b = bgs[i], let data = try? Data(contentsOf: b), let img = Raster.jpegImage(data) {
                ctx.draw(img, in: rr)
            } else if let img = Raster.page(p, dpi: 150), let j = Raster.encode(img), let ji = Raster.jpegImage(j) {
                ctx.draw(ji, in: rr)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                for para in paras[i] { ctx.fill(para.rect.insetBy(dx: -1.5, dy: -1.5)) }
            }
            let ps = paras[i]
            let margin = max(18, ps.map(\.rect.minX).min() ?? 36)                 // 左邊界＝右邊界（大部分文件左右對稱）
            for (j, para) in ps.enumerated() {
                defer { k += 1 }
                guard let t = out["\(k)"], !t.isEmpty else { continue }
                fit(t, in: room(for: j, in: ps, page: sz, margin: margin), size: para.size, ctx: ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try PDFs.verify(tmp, pages: n)
        return ToolResult(outputs: [try r.place(tmp, like: u, suffix: L("（\(tn)）", " (\(tn))"), ext: "pdf")],
                          notes: [L("\(sn) → \(tn)，\(all.count) 段；用這台 Mac 的系統翻譯（沒有上傳）。版面照原檔，譯文放不下的地方字會縮小", "\(sn) → \(tn), \(all.count) passages, translated on this Mac; layout kept, text shrinks where it doesn’t fit")])
    }

    /// 一段拆成句子（中文照「。！？」、英文照句點）
    static func sentences(_ s: String) -> [String] {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = s
        var out: [String] = []
        tok.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in out.append(String(s[r])); return true }
        return out.isEmpty ? [s] : out
    }

    /// 譯文通常比原文長：框往右放寬到右邊的字（或頁邊界）為止，往下放寬到下一段為止（最多多一倍高），還放不下才縮字。
    /// 同一列左右還有別的字（表格的格子）＝只往右、不往下（不壓到表格線）
    static func room(for j: Int, in ps: [TextMap.Para], page sz: CGSize, margin: CGFloat) -> CGRect {
        let r = ps[j].rect, gap = max(3, ps[j].size * 0.4)
        var right = max(r.maxX, sz.width - margin), inRow = false
        for (o, q) in ps.enumerated() where o != j && q.rect.minY < r.maxY && r.minY < q.rect.maxY {
            if q.rect.minX >= r.maxX - 1 { right = min(right, max(r.maxX, q.rect.minX - gap)); inRow = true }
            else if q.rect.maxX <= r.minX + 1 { inRow = true }
        }
        if inRow { return CGRect(x: r.minX, y: r.minY, width: right - r.minX, height: r.height) }
        var bottom = max(min(r.minY, 18), r.minY - max(r.height, ps[j].size * 1.5))
        for (o, q) in ps.enumerated() where o != j && q.rect.maxY <= r.minY + 1 && q.rect.minX < right && r.minX < q.rect.maxX {
            bottom = max(bottom, min(r.minY, q.rect.maxY + gap))
        }
        return CGRect(x: r.minX, y: bottom, width: right - r.minX, height: r.maxY - bottom)
    }

    /// 字放進框裡：從原字級開始，放不下就縮，最小 4pt；從框的上緣往下排
    static func fit(_ s: String, in box: CGRect, size: CGFloat, ctx: CGContext) {
        var fs = max(4, size)
        let ink = CGColor(red: 0.12, green: 0.13, blue: 0.14, alpha: 1)
        while true {
            let para = NSMutableParagraphStyle(); para.lineHeightMultiple = 1.05
            let attr = NSAttributedString(string: s, attributes: [.font: Overlay.font(fs), .foregroundColor: ink, .paragraphStyle: para])
            let setter = CTFramesetterCreateWithAttributedString(attr)
            let need = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
            if need.height <= box.height + fs * 0.3 || fs <= 4 {
                let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: box.minX, y: box.maxY - max(box.height, need.height), width: box.width, height: max(box.height, need.height)), transform: nil), nil)
                CTFrameDraw(frame, ctx)
                return
            }
            fs *= 0.9
        }
    }
}
