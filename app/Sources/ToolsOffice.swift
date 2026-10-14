// ToolsOffice.swift — Word／PowerPoint／Excel 轉 PDF
//
// 版面最準的是讓原本的軟體自己輸出：先找 Pages／Keynote／Numbers（蘋果的，讀得懂 Office 檔），再找 Microsoft Office；
// 都沒有，Word 類的檔用 macOS 內建的文字排版印成 PDF（字與段落對，複雜版面會跑掉），CSV 用網頁表格印。
// 叫別的 app 做事，macOS 第一次會問「允許 Slimly 控制 Pages 嗎」，按一次好就記住。
import AppKit
import Foundation
import PDFKit

enum Office {
    struct App { let id: String; let kind: String }       // kind：iwork／word／powerpoint
    static let word = ["docx", "doc", "rtf", "odt", "txt", "pages", "md"]
    static let slides = ["pptx", "ppt", "key", "odp"]
    static let sheets = ["xlsx", "xls", "numbers", "csv", "ods"]

    static func candidates(_ ext: String) -> [App] {
        if slides.contains(ext) { return [App(id: "com.apple.Keynote", kind: "iwork"), App(id: "com.apple.iWork.Keynote", kind: "iwork"), App(id: "com.microsoft.Powerpoint", kind: "powerpoint")] }
        if sheets.contains(ext) { return ext == "csv" ? [] : [App(id: "com.apple.Numbers", kind: "iwork"), App(id: "com.apple.iWork.Numbers", kind: "iwork")] }
        if ["txt", "md", "rtf"].contains(ext) { return [] }                       // 純文字：內建排版就夠
        return [App(id: "com.apple.Pages", kind: "iwork"), App(id: "com.apple.iWork.Pages", kind: "iwork"), App(id: "com.microsoft.Word", kind: "word")]
    }
    static func installed(_ id: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }
    static func running(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }

    static func toPDF(_ r: ToolRun) throws -> ToolResult {
        var res = ToolResult()
        for (k, u) in r.inputs.enumerated() {
            let ext = u.pathExtension.lowercased()
            guard (word + slides + sheets).contains(ext) else { throw ToolError.msg(L("「\(u.lastPathComponent)」不是 Office 檔", "“\(u.lastPathComponent)” isn’t an Office document")) }
            r.progress(L("轉「\(u.lastPathComponent)」", "Converting “\(u.lastPathComponent)”"), Double(k) / Double(r.inputs.count))
            let tmp = r.tmp("office-\(k).pdf")
            var how = "", errors: [String] = []
            for app in candidates(ext) where installed(app.id) {
                do {
                    try viaApp(app, u, tmp)
                    if PDFDocument(url: tmp)?.pageCount ?? 0 > 0 { how = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)?.deletingPathExtension().lastPathComponent ?? app.id; break }
                } catch let e as ToolError { errors.append(e.text) } catch { errors.append(error.localizedDescription) }
            }
            if how.isEmpty && (word.contains(ext) || ext == "csv") {
                do { try builtIn(u, ext: ext, to: tmp); how = L("macOS 內建排版", "macOS text layout") }
                catch let e as ToolError { errors.append(e.text) }
            }
            guard !how.isEmpty, let o = PDFDocument(url: tmp), o.pageCount > 0 else {
                let need = slides.contains(ext) ? "Keynote" : sheets.contains(ext) ? "Numbers" : "Pages"
                throw ToolError.msg(L("「\(u.lastPathComponent)」轉不了：\(errors.last ?? "這台沒有 \(need)（App Store 免費）")", "Couldn’t convert “\(u.lastPathComponent)”: \(errors.last ?? "install \(need) (free on the App Store)")"))
            }
            res.outputs.append(try r.place(tmp, like: u, suffix: "", ext: "pdf"))
            res.notes.append(L("用 \(how) 轉：\(o.pageCount) 頁", "Converted with \(how): \(o.pageCount) pages"))
        }
        return res
    }

    /// 叫 app 開檔、輸出 PDF、關檔（原本沒開的 app 用完關掉）。用 osascript：卡住可以收掉
    static func viaApp(_ app: App, _ src: URL, _ out: URL) throws {
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let was = running(app.id)
        var script: String
        switch app.kind {
        case "iwork":
            script = """
            set inF to POSIX file "\(q(src.path))"
            set outF to POSIX file "\(q(out.path))"
            with timeout of 300 seconds
                tell application id "\(app.id)"
                    set d to open inF
                    delay 0.5
                    export d to outF as PDF
                    close d saving no
                end tell
            end timeout
            """
        case "word":
            script = """
            with timeout of 300 seconds
                tell application id "\(app.id)"
                    open (POSIX file "\(q(src.path))")
                    set d to active document
                    save as d file name "\(q(out.path))" file format format PDF
                    close d saving no
                end tell
            end timeout
            """
        default:
            script = """
            with timeout of 300 seconds
                tell application id "\(app.id)"
                    open (POSIX file "\(q(src.path))")
                    save active presentation in "\(q(out.path))" as save as PDF
                    close active presentation saving no
                end tell
            end timeout
            """
        }
        if !was { script += "\ntell application id \"\(app.id)\" to quit" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run()
        let deadline = Date().addingTimeInterval(330)
        while p.isRunning {
            if Date() > deadline { p.terminate(); throw ToolError.msg(L("等太久沒有回應", "The app didn’t respond")) }
            if Thread.isMainThread { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) } else { usleep(100_000) }
        }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0 {
            if msg.contains("-1743") || msg.contains("Not authorized") || msg.contains("不允許") {
                throw ToolError.msg(L("macOS 還沒允許 Slimly 控制這個 app：系統設定 → 隱私權與安全性 → 自動化，把 Slimly 底下的勾打開", "Allow Slimly to control this app in System Settings → Privacy & Security → Automation"))
            }
            throw ToolError.msg(msg.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200).description)
        }
    }

    /// 內建排版：docx／doc／rtf／odt／txt／md 用 macOS 的文字系統排成 A4；CSV 做成表格網頁再印
    static func builtIn(_ u: URL, ext: String, to out: URL) throws {
        if ext == "csv" {
            let s = (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue))))) ?? ""
            guard !s.isEmpty else { throw ToolError.msg(L("CSV 是空的", "The CSV is empty")) }
            var html = "<html><head><meta charset=utf-8><style>body{font:11px -apple-system,'PingFang TC';margin:0}table{border-collapse:collapse}td{border:1px solid #ccc;padding:3px 6px;white-space:nowrap}tr:first-child td{font-weight:600;background:#f3f5f5}</style></head><body><table>"
            for line in s.components(separatedBy: .newlines) where !line.isEmpty {
                html += "<tr>" + parseCSV(line).map { "<td>\(OOXML.esc($0))</td>" }.joined() + "</tr>"
            }
            html += "</table></body></html>"
            let page = out.deletingLastPathComponent().appendingPathComponent("csv-\(UUID().uuidString.prefix(6)).html")
            try html.write(to: page, atomically: true, encoding: .utf8)
            let long = out.deletingLastPathComponent().appendingPathComponent("csv-long.pdf")
            try MainRunner.wait(timeout: 60) { done in WebSnapshot.shared.capture(page, to: long, width: 1100) { _, e in done(e) } }
            try Convert.paginate(long, to: out, page: CGSize(width: 841.89, height: 595.28))
            return
        }
        var attr: NSAttributedString
        if ext == "md" {
            let s = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            attr = (try? NSAttributedString(AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))) ?? NSAttributedString(string: s)
        } else {
            var da: NSDictionary?
            guard let a = try? NSAttributedString(url: u, options: [:], documentAttributes: &da) else {
                throw ToolError.msg(L("macOS 讀不懂這份（\(ext)）：裝 Pages（App Store 免費）就能轉", "macOS can’t read this \(ext) file; install Pages (free)"))
            }
            attr = a
        }
        try MainRunner.wait(timeout: 120) { done in
            if NSApp == nil { _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited) }
            let paper = CGSize(width: 595.28, height: 841.89), m: CGFloat = 56
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: paper.width - m * 2, height: 100))
            tv.textStorage?.setAttributedString(attr)
            tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = true
            if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc); tv.frame.size.height = lm.usedRect(for: tc).height + 20 }
            let pi = NSPrintInfo(dictionary: [NSPrintInfo.AttributeKey.jobSavingURL: out])
            pi.jobDisposition = .save
            pi.paperSize = paper
            pi.topMargin = m; pi.bottomMargin = m; pi.leftMargin = m; pi.rightMargin = m
            pi.horizontalPagination = .fit; pi.verticalPagination = .automatic
            let op = NSPrintOperation(view: tv, printInfo: pi)
            op.showsPrintPanel = false; op.showsProgressPanel = false
            done(op.run() ? nil : ToolError.msg(L("排版印不出來", "Couldn’t lay out the document")))
        }
    }

    static func parseCSV(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        var it = Array(line)[...]
        while let c = it.popFirst() {
            if c == "\"" { if quoted, it.first == "\"" { cur.append("\""); _ = it.popFirst() } else { quoted.toggle() } }
            else if c == "," && !quoted { out.append(cur); cur = "" }
            else { cur.append(c) }
        }
        out.append(cur)
        return out
    }
}
