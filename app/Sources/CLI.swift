// CLI.swift — 命令列入口：其他程式、終端機都能叫這個
//
//   /Applications/Slimly.app/Contents/MacOS/Slimly --cli [選項] <PDF 或資料夾>…
//
// 跟 app 同一套引擎、同一道關（品質階梯、結束碼、頁數、逐頁畫面核對、永不覆蓋、原檔只讀）。
// 呼叫的程式只負責「要壓哪份、壓到多小」，壓交給這裡。不開視窗、不上 Dock、不碰使用者在 app 裡的設定（這次執行專用一份，結束就收掉）。
import Foundation
import PDFKit

enum CLI {
    static let usage = """
    用法：Slimly --cli [選項] <PDF 或資料夾>…
      --target <MB>        壓到多小，預設 25（寄 Email）；0＝不限大小，只做看不出差別的那一級
      --dest <資料夾>      壓好的放這裡（預設：原檔旁邊，檔名多「（已壓縮）」）
      --original backup    原檔收進旁邊的「未壓縮備份」，壓好的接手原檔名
      --split              壓到最小還是超過目標：依頁拆成幾份，每份都在目標以下
      --yes                有可填寫表單或電子簽章的也照壓（預設跳過並說明原因：壓了欄位不能填、簽章失效）
      --json               只印最後一行 JSON（給程式讀）
      --lang zh|en         輸出的語言
    每份一行結果，最後一行是 JSON。結束碼：0＝都處理好了（壓好，或原檔已經最精簡）；2＝有沒壓成或被跳過的；64＝用法錯。
    原檔永遠不動（--original backup 時是搬進備份夾，不刪不蓋）。
    """

    private static let valued: Set<String> = ["--target", "--dest", "--original", "--lang", "--engine", "--stall", "--fake-free", "--downloads"]

    static func main(_ argv: [String]) -> Int32 {
        // 2.0：第一個字是工具名＝跑那個工具（Slimly --cli merge a.pdf b.pdf）；否則照舊是壓縮
        let start = (argv.firstIndex(of: "--cli") ?? 0) + 1
        if start < argv.count {
            let first = argv[start]
            if first == "tools" { printTools(); return 0 }
            if first == "estimate", !FileManager.default.fileExists(atPath: first) { return estimate(Array(argv[(start + 1)...])) }
            if Tools.spec(first) != nil, !FileManager.default.fileExists(atPath: first) { return tool(first, Array(argv[(start + 1)...])) }
        }
        var files: [URL] = []
        var split = false, yes = false, jsonOnly = false
        var i = (argv.firstIndex(of: "--cli") ?? 0) + 1
        while i < argv.count {
            let a = argv[i]
            if valued.contains(a) { i += 2; continue }
            switch a {
            case "--split": split = true
            case "--yes": yes = true
            case "--json": jsonOnly = true
            case "--help", "-h": print(usage); return 0
            default:
                if a.hasPrefix("--") { err(L("不認得的選項：\(a)", "Unknown option: \(a)")); err(usage); return 64 }
                files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath).standardizedFileURL)
            }
            i += 1
        }
        guard !files.isEmpty else { err(usage); return 64 }
        if let k = argv.firstIndex(of: "--target"), k + 1 >= argv.count || Int(argv[k + 1]) == nil {
            err(L("--target 要接數字（MB），0＝不限", "--target needs a number of MB (0 = no limit)")); return 64
        }
        Store.resetTestDefaults()                     // 這次執行專用的一份設定（Store.isTest 含 --cli），結束收掉

        let target = Prefs.targetBytes
        let (all, emptyFolders) = Inspect.expand(files)
        var results: [[String: Any]] = []
        var bad = 0
        func out(_ s: String) { if !jsonOnly { print(s); fflush(stdout) } }

        for d in emptyFolders {
            results.append(["file": d, "status": "skipped", "code": "folderEmpty"]); bad += 1
            out("✗ \(d)：" + L("資料夾裡沒有 PDF", "no PDFs in this folder"))
        }
        for (n, url) in all.enumerated() {
            let name = url.lastPathComponent
            var r: [String: Any] = ["file": url.path]
            switch Inspect.check(url) {
            case .failure(let e):
                r["status"] = "skipped"; r["code"] = e.code.rawValue; bad += 1
                out("✗ \(name)：" + skipText(e.code))
            case .success(let info):
                r["before"] = info.bytes; r["pages"] = info.pages
                if (info.signed || info.hasForm) && !yes {
                    r["status"] = "skipped"; r["code"] = info.signed ? "signed" : "form"; bad += 1
                    out("✗ \(name)：" + (info.signed ? L("有電子簽章，壓了簽章會失效（確定要壓：加 --yes）", "digitally signed; compressing voids the signature (add --yes to proceed)")
                                                     : L("有可填寫的表單，壓了欄位不能再填（確定要壓：加 --yes）", "has fillable form fields that won’t survive (add --yes to proceed)")))
                    break
                }
                if all.count > 1 { progress(L("[\(n + 1)／\(all.count)] \(name)", "[\(n + 1)/\(all.count)] \(name)"), newline: true) }
                let c = makeCompressor(info, target: target, dest: nil)
                var last = -2
                c.onProgress = { lv, pg, pages in
                    if lv < 0 { if last != -1 { last = -1; progress(L("  核對每一頁的畫面…", "  checking every page…"), newline: true) }; return }
                    let label = levelLabel(info, lv)
                    if isatty(2) != 0 { progress("  \(label)・" + L("第 \(pg)／\(pages) 頁", "page \(pg)/\(pages)"), newline: false) }
                    else if lv != last { last = lv; progress("  \(label)…", newline: true) }
                }
                let o = c.runSync()
                if isatty(2) != 0 { progress("", newline: false) }
                if (c as? Compressor)?.iccFixed == true { r["iccFixed"] = true }
                switch o {
                case .saved(let s):
                    r["status"] = "saved"; r["after"] = s.bytes; r["out"] = s.out.path; r["level"] = "Q\(s.level + 1)"
                    r["label"] = levelLabel(info, s.level); r["kind"] = info.kind.rawValue; r["reached"] = s.reached; r["smallest"] = s.smallest
                    if let b = s.backup { r["backup"] = b.path }
                    if let note = s.note { r["note"] = note }
                    let bigger = Int((Double(s.bytes) / Double(max(1, info.bytes)) - 1) * 100)
                    let how = s.note == "converted" ? L("轉成 JPEG，大家都打得開・比原檔大 \(bigger)%", "converted to JPEG so anyone can open it · \(bigger)% larger")
                                                    : L("小了 \(pct(info.bytes, s.bytes))%・\(levelLabel(info, s.level))", "\(pct(info.bytes, s.bytes))% smaller · \(levelLabel(info, s.level))")
                    var line = "✓ \(name)：\(humanSize(info.bytes)) → \(humanSize(s.bytes))（" + how + "）→ \(s.out.path)"
                    if !s.reached, let t = target {
                        line += "\n  " + L("還是超過 \(humanSize(t))（這是畫質不犧牲的版本；最小能到 \(humanSize(s.smallest))）", "still over \(humanSize(t)) (quality kept; \(humanSize(s.smallest)) is possible)")
                    }
                    out(line)
                    if split, info.kind == .pdf, !s.reached, let t = target {
                        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Slimly-split-\(UUID().uuidString)", isDirectory: true)
                        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: work) }
                        progress(L("  拆成幾份…", "  splitting…"), newline: true)
                        switch Splitter.split(s.out, limit: t, work: work) {
                        case .success(let parts):
                            do {
                                let placed = try Splitter.place(parts, dir: s.out.deletingLastPathComponent(), compressedName: s.out.lastPathComponent)
                                r["parts"] = placed.map { ["path": $0.url.path, "bytes": $0.bytes, "pages": "\($0.first)-\($0.last)", "over": $0.over] as [String: Any] }
                                out("  " + L("拆成 \(placed.count) 份：", "split into \(placed.count): ") + placed.map { "\($0.url.lastPathComponent)（\(humanSize($0.bytes))）" }.joined(separator: "、"))
                                if placed.contains(where: \.over) { out("  " + L("有一頁單頁就超過目標，那一份還是太大", "one page alone is over the target; that part is still too big")) }
                            } catch {
                                r["splitError"] = "place"; bad += 1
                                out("  ✗ " + L("拆好的放不進「\(s.out.deletingLastPathComponent().path)」", "couldn’t save the parts next to it"))
                            }
                        case .failure(let e):
                            r["splitError"] = "\(e)"; bad += 1
                            out("  ✗ " + L("拆不了（\(e)），整份的還在", "couldn’t split (\(e)); the whole file is still there"))
                        }
                    }
                case .noGain(let best):
                    r["status"] = "nogain"; r["after"] = best
                    out("－ \(name)：" + (best >= info.bytes ? L("已經很精簡，壓了反而變大，沒另存", "already lean — it would get bigger, nothing saved")
                                                           : L("已經很精簡，只小 \(pct(info.bytes, best))%，沒另存", "already lean — only \(pct(info.bytes, best))% smaller, nothing saved")))
                case .failed(let code, let detail):
                    r["status"] = "failed"; r["code"] = code; r["detail"] = detail; bad += 1
                    out("✗ \(name)：" + failText(code, detail))
                }
            }
            results.append(r)
        }
        let summary: [String: Any] = ["app": "Slimly", "version": Engine.appVersion,
                                      "build": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "",
                                      "targetMB": Prefs.targetMB, "results": results]
        if let d = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) {
            print((jsonOnly ? "" : "JSON ") + s)
        }
        return bad == 0 ? 0 : 2
    }

    // MARK: 工具（2.0）

    static let flags: Set<String> = ["each", "all", "list", "flatten", "restrict", "date", "keep_text", "json", "yes", "split", "scan"]

    static func printTools() {
        let cats = [("convert", "轉檔（一個入口）"), ("organize", "整理"), ("optimize", "優化"), ("topdf", "轉成 PDF"), ("frompdf", "從 PDF 轉出"), ("edit", "編輯"), ("security", "安全"), ("ai", "裝置端智慧")]
        for (c, zh) in cats {
            print("【\(L(zh, c))】")
            for s in Tools.specs where s.cat == c { print("  \(s.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(s.name)" + (s.accepts.isEmpty ? "" : "（" + s.accepts.joined(separator: " ") + "）")) }
        }
        print(L("用法：Slimly --cli <工具> [--選項 值] <檔案…>；例：Slimly --cli merge a.pdf b.pdf、Slimly --cli split --every 5 a.pdf、Slimly --cli html2pdf --url example.com",
                "Usage: Slimly --cli <tool> [--option value] <files…>"))
    }

    /// 跑一個工具：選項 --key value（旗標不帶值），其餘是檔案。每個產出一行，最後一行 JSON
    static func tool(_ id: String, _ args: [String]) -> Int32 {
        var opts: [String: Any] = [:], files: [URL] = [], jsonOnly = false
        var dest: URL? = nil
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let k = String(a.dropFirst(2)).replacingOccurrences(of: "-", with: "_")
                if k == "password" || k == "owner" {
                    err(L("密碼不能寫在指令裡（會留在紀錄）：直接執行，Slimly 會問", "Don’t put passwords on the command line; Slimly will ask")); return 64
                }
                if flags.contains(k) { if k == "json" { jsonOnly = true } else { opts[k] = true }; i += 1; continue }
                guard i + 1 < args.count else { err(L("--\(k) 要接一個值", "--\(k) needs a value")); return 64 }
                if k == "dest" { dest = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true) }
                else if k != "lang" || id == "ocr" || id == "summarize" { opts[k] = args[i + 1] }
                i += 2; continue
            }
            files.append(URL(fileURLWithPath: (a as NSString).expandingTildeInPath).standardizedFileURL)
            i += 1
        }
        Store.resetTestDefaults()
        // 加密、解鎖：密碼只從終端機問（看不到輸入的字）
        let needPw = id == "protect" || (id == "unlock" && files.first.flatMap { PDFDocument(url: $0) }.map { $0.isLocked || PDFs.restricted($0) } == true)
        let noPw = L("這個工具要密碼：在終端機直接執行，或用 app 的「所有工具」（密碼不經過指令）", "This tool needs a password: run it in Terminal or use the app")
        if needPw {
            guard isatty(0) != 0 else { err(noPw); return 64 }
            guard let pw = ask(L("密碼：", "Password: ")), !pw.isEmpty else { return 64 }
            if id == "protect" {
                guard let again = ask(L("再輸入一次：", "Again: ")), again == pw else { err(L("兩次不一樣", "They don’t match")); return 64 }
            }
            opts["password"] = pw
        }
        let t0 = Date()
        let r = Tools.run(id, inputs: files, options: opts, dest: dest) { text, frac in
            if isatty(2) != 0 { progress("  \(text)（\(Int(frac * 100))%）", newline: false) }
        }
        if isatty(2) != 0 { progress("", newline: false) }
        var summary: [String: Any] = ["app": "Slimly", "version": Engine.appVersion, "tool": id, "seconds": Int(Date().timeIntervalSince(t0))]
        switch r {
        case .success(let res):
            summary["ok"] = true
            summary["outputs"] = res.outputs.map(\.path)
            summary["notes"] = res.notes
            if let t = res.text { summary["text"] = t }
            if !jsonOnly {
                for o in res.outputs { print("✓ \(o.path)") }
                for n in res.notes { print("  \(n)") }
                if let t = res.text { print(t) }
            }
        case .failure(let e):
            summary["ok"] = false; summary["error"] = e.text
            if !jsonOnly { print("✗ \(e.text)") }
        }
        if let d = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), let s = String(data: d, encoding: .utf8) {
            print((jsonOnly ? "" : "JSON ") + s)
        }
        if case .success = r { return 0 }
        return 2
    }

    private static func ask(_ prompt: String) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard let p = readpassphrase(prompt, &buf, buf.count, 0) else { return nil }
        return String(cString: p)
    }

    private static func pct(_ b: Int64, _ a: Int64) -> Int { max(0, Int(((1 - Double(a) / Double(max(1, b))) * 100).rounded())) }
    /// 壓前預估：Slimly --cli estimate <PDF> [--exact]——每一級大概會壓到多大；--exact＝整份每一級都真的壓（對照用，慢）
    static func estimate(_ args: [String]) -> Int32 {
        let exact = args.contains("--exact")
        guard let f = args.first(where: { !$0.hasPrefix("--") }) else { err(L("用法：Slimly --cli estimate <PDF> [--exact]", "Usage: Slimly --cli estimate <PDF> [--exact]")); return 64 }
        let url = URL(fileURLWithPath: (f as NSString).expandingTildeInPath).standardizedFileURL
        var d: [String: Any] = ["file": url.path]
        switch Inspect.check(url) {
        case .failure(let e): d["ok"] = false; d["code"] = e.code.rawValue
        case .success(let info):
            d["bytes"] = info.bytes; d["pages"] = info.pages
            if let r = Estimator(info: info).run(exact: exact) { d.merge(r.dict) { $1 }; d["ok"] = true } else { d["ok"] = false; d["code"] = "engine" }
        }
        if let j = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]), let s = String(data: j, encoding: .utf8) { print(s) }
        return (d["ok"] as? Bool) == true ? 0 : 2
    }

    private static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    private static func progress(_ s: String, newline: Bool) {
        if isatty(2) != 0 && !newline { FileHandle.standardError.write(Data(("\r\u{1B}[2K" + s).utf8)); return }
        FileHandle.standardError.write(Data(((isatty(2) != 0 ? "\r\u{1B}[2K" : "") + s + "\n").utf8))
    }

    private static func skipText(_ c: SkipCode) -> String {
        switch c {
        case .notPDF: return L("不是 PDF、照片或 Office 檔", "not a PDF, photo or Office file")
        case .empty: return L("空檔（0 KB）", "empty file")
        case .damaged: return L("打不開：不是完整的 PDF", "not a complete PDF")
        case .unreadable: return L("沒有權限讀取", "no permission to read it")
        case .locked: return L("有密碼：先用預覽程式解鎖、輸出一份沒有密碼的（Slimly 不破解）", "password-protected: unlock it in Preview first (Slimly never cracks passwords)")
        case .protected: return L("有權限保護：壓縮會拿掉這層保護，不動它", "permission-protected: compressing would strip that, so it’s left alone")
        case .signed: return L("有電子簽章", "digitally signed")
        case .duplicate: return L("重複", "duplicate")
        case .legacy: return L("舊格式（doc／ppt／xls）不支援，請先另存新格式（docx／pptx／xlsx）", "old format (doc/ppt/xls) not supported: save as docx/pptx/xlsx first")
        case .officeLocked: return L("Office 檔有密碼：先取消密碼另存一份（Slimly 不破解）", "password-protected Office file: remove the password first")
        case .officeSigned: return L("有數位簽章：重新打包會失效，不動它", "digitally signed: repacking would invalidate it")
        case .officeOle: return L("嵌了 OLE 物件（插入的 Excel 工作表、Word 文件、ActiveX 控制項）：不動它", "embeds OLE objects (inserted worksheets, documents, ActiveX controls): left alone")
        case .officeMacro: return L("有巨集：不動它", "has macros: left alone")
        case .officeDamaged: return L("打不開：不是完整的 Office 檔", "not a complete Office file")
        }
    }

    private static func failText(_ code: String, _ detail: String) -> String {
        switch code {
        case "timeout": return L("卡住了：超過 \(detail) 秒沒有進度，停掉了；原檔沒動", "stuck for \(detail) s, stopped; original untouched")
        case "pages": return L("壓完頁數對不上（\(detail)），沒交出去；原檔沒動", "page count changed (\(detail)), not saved; original untouched")
        case "permission": return L("存不進「\(detail)」（唯讀或沒有權限）；原檔沒動", "can’t write to “\(detail)”; original untouched")
        case "space": return L("磁碟空間不夠；原檔沒動", "not enough disk space; original untouched")
        case "quality":
            let p = detail.split(separator: "|")
            return L("壓完的畫面跟原檔對不上（第 \(p.first ?? "?") 頁有 \(p.count > 1 ? p[1] : "?")% 的地方變了），沒交出去；原檔沒動",
                     "the result doesn’t match the original (page \(p.first ?? "?"), \(p.count > 1 ? p[1] : "?")% changed), not saved; original untouched")
        default: return L("壓縮引擎讀不懂這份的某些內容；原檔沒動", "the engine couldn’t read part of this file; original untouched") + (detail.isEmpty ? "" : "\n  " + detail.replacingOccurrences(of: "\n", with: "\n  "))
        }
    }
}
