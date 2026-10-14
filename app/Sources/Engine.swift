// Engine.swift — 壓一份 PDF：品質階梯＋驗收＋放到該放的地方
//
// 做法跟 cli/compress_pdf.sh 同一套（引擎＝包內自帶的 Ghostscript）：
//   從「近無損」開始逐級試，第一個 ≤ 目標大小的就停——剛好壓到就好，不一次砍到底。
// app 比腳本多做的（腳本沒有、出事會把壞檔交出去的地方）：
//   ① 看 gs 的結束碼：失敗時 gs 仍可能留下一個「有東西」的殘檔（例如 1 頁的空白 PDF），只看檔案不是空的會誤判成功
//   ② 每一級都驗頁數：頁數對不上＝不交出去
//   ③ 沒變小（或只小不到 3%）＝不另存，原檔就是最好的版本
//   ④ 壓不到目標：交「畫質不犧牲」的那一版（第一級），不交畫質最差又照樣超標的最後一級
//   ⑤ 看門狗：超過 stallLimit 秒沒有新的一頁＝卡住，停掉
//   ⑥ 永不覆蓋：先寫暫存，再搬到一個不存在的檔名；原檔只可能被「搬進備份夾」（使用者選的），不會被蓋、不會被刪
import Foundation

struct Level {
    let key: String       // Q1…Q6
    let q: Double         // 彩色圖的 JPEG QFactor（越小畫質越好）
    let gq: Double        // 灰階圖的 QFactor（灰階比照彩色；第一級用 0.30，見下）
    let res: Int          // 降採樣後的解析度 dpi
    let thr: Double       // 降採樣門檻：1.5＝只降超過 res×1.5（225 dpi）的圖；1.0＝超過 res 就降
    let deep: Bool        // 降解析度的三級：色度 4:2:0、原本的 JPEG 也重壓（不直接照抄）
    let zh: String, en: String
    var label: String { L(zh, en) }
}

enum Ladder {
    /// 階梯的幾個決定：
    ///   ・灰階圖只用 gs 預設（約品質 55）的話，灰階檔 Q1–Q4 一樣大、都是 44 dB，所以比照彩色；第一級用 0.30 不用 0.15——
    ///     0.15 讓灰階 JPEG 掃描檔 1.7 → 5.9 MB 只多 0.6 dB，不划算
    ///   ・Q4 若用 0.30，畫質反而比 Q3 的 0.50 高、檔案比 Q3 大（實測 46 份裡 30 份）。所以降解析度的三級用 4:2:0、
    ///     QFactor 往下單調 0.50／0.60／0.76，原本的 JPEG 也重壓：PowerPoint 那份 Q4–Q6 實測 14.2／11.8／9.0 MB
    ///   命令列也走 app 的 --cli，階梯只定義在這裡
    static let levels: [Level] = [
        Level(key: "Q1", q: 0.15, gq: 0.30, res: 150, thr: 1.5, deep: false, zh: "近無損",  en: "Near-lossless"),
        Level(key: "Q2", q: 0.30, gq: 0.30, res: 150, thr: 1.5, deep: false, zh: "高畫質",  en: "High quality"),
        Level(key: "Q3", q: 0.50, gq: 0.50, res: 150, thr: 1.5, deep: false, zh: "中畫質",  en: "Medium quality"),
        Level(key: "Q4", q: 0.50, gq: 0.50, res: 150, thr: 1.0, deep: true,  zh: "150 dpi", en: "150 dpi"),
        Level(key: "Q5", q: 0.60, gq: 0.60, res: 120, thr: 1.0, deep: true,  zh: "120 dpi", en: "120 dpi"),
        Level(key: "Q6", q: 0.76, gq: 0.76, res: 100, thr: 1.0, deep: true,  zh: "100 dpi", en: "100 dpi"),
    ]

    static func gsArgs(_ lv: Level, input: String, output: String) -> [String] {
        let chroma = lv.deep ? "/HSamples [2 1 1 2] /VSamples [2 1 1 2]" : "/HSamples [1 1 1 1] /VSamples [1 1 1 1]"
        return [
            "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5", "-dNOPAUSE", "-dBATCH", "-dSAFER",
            // 盤點 47 份實檔後加的兩個（修的是「壓出壞檔」，不是調畫質）：
            //   AutoRotatePages＝gs 預設會照文字方向把頁面轉 90°（橫式頁、直排字實測被轉掉）
            //   PreserveMarkedContent＝保留 Keynote 的標記內容時，gs 讓 q／Q 跨過標記區段，macOS 的 PDF 引擎
            //   （預覽程式、郵件預覽）會把後面的圖片裁掉；結構樹本來就保不住，標記留著也沒用
            "-dAutoRotatePages=/None", "-dPreserveMarkedContent=false",
            "-o", output,
            "-dDownsampleColorImages=true", "-dColorImageResolution=\(lv.res)", "-dColorImageDownsampleThreshold=\(lv.thr)",
            "-dDownsampleGrayImages=true", "-dGrayImageResolution=\(lv.res)", "-dGrayImageDownsampleThreshold=\(lv.thr)",
            "-dAutoFilterColorImages=false", "-dColorImageFilter=/DCTEncode",
            "-dAutoFilterGrayImages=false", "-dGrayImageFilter=/DCTEncode",
        ] + (lv.deep ? ["-dPassThroughJPEGImages=false"] : []) + [
            "-c", "<< /ColorImageDict << /QFactor \(lv.q) /Blend 1 \(chroma) >> /GrayImageDict << /QFactor \(lv.gq) /Blend 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >> >> setdistillerparams",
            "-f", input,
            // 在文件資訊裡記一筆（下次拖進來認得出「壓過了」）；原本的標題、作者、建立程式照留
            "-c", "[ /SlimlyVersion (\(Engine.appVersion) \(lv.key)) /DOCINFO pdfmark",
        ]
    }
}

/// 一份檔的結果
enum Outcome {
    case saved(Saved)
    case noGain(best: Int64)                    // 壓了沒變小（或只小一點），不另存
    case failed(code: String, detail: String)   // engine／timeout／pages／permission／space／cancelled
}

struct Saved {
    let out: URL
    let bytes: Int64
    let level: Int                 // 交出去的是第幾級（0 起算）
    let reached: Bool              // 有沒有壓到目標（沒設目標＝true）
    let smallest: Int64            // 這次試過最小的（壓不到目標時告訴使用者「最多能到多小」）
    let backup: URL?               // 原檔收進備份夾的位置（原檔模式＝backup 時）
    let note: String?              // 原檔有不標準的地方（gs 修補過），請打開看一下
}

enum Engine {
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
    /// 包內 gs；測試可用 --engine <路徑> 換成假的引擎（模擬當掉、卡住）
    static var gsPath: String {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--engine"), a.count > i + 1 { return a[i + 1] }
        return Bundle.main.resourceURL!.appendingPathComponent("bin/gs").path
    }
    /// 幾秒沒有新的一頁算卡住。盤點實測最慢的一頁 147 秒（Keynote 帶 ICC v4 的大圖），給 180 秒。測試可用 --stall <秒>
    static var stallLimit: TimeInterval {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--stall"), a.count > i + 1, let v = Double(a[i + 1]) { return v }
        return 180
    }
    /// 不含睡眠的時鐘：Mac 闔上蓋子睡一覺醒來，看門狗不能把睡著的時間算成「卡住」
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// 第一級壓出來比原檔大這麼多倍＝檔案結構的問題（新版色彩描述檔、字型被拆），後面幾級也救不回來，不再往下跑
    static let hopeless = 1.5
    /// 測試用：--fake-free <bytes> 假裝磁碟只剩這麼多（驗「空間不夠」那一條）
    static var fakeFree: Int64? {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--fake-free"), a.count > i + 1 { return Int64(a[i + 1]) }
        return nil
    }
    /// 小於這個比例的節省不值得另存一份（原檔就是最好的版本）
    static let minGain = 0.97
}

/// 壓一份的共同介面：PDF（Compressor，gs 階梯）與照片（ImageCompressor，ImageIO 階梯）
protocol Compressing: AnyObject {
    var onProgress: ((Int, Int, Int) -> Void)? { get set }
    func run(_ done: @escaping (Outcome) -> Void)
    func runSync() -> Outcome
    func cancel()
}

/// 壓一份。在自己的背景佇列上跑完整條階梯，結果回主執行緒。
final class Compressor: Compressing {
    let info: PDFInfo
    let target: Int64?
    /// (第幾級, 第幾頁, 共幾頁)
    var onProgress: ((Int, Int, Int) -> Void)?

    private let q = DispatchQueue(label: "slimly.compressor", qos: .userInitiated)
    private let lock = NSLock()
    private var proc: Process?
    private var cancelled = false
    private var stalled = false
    private var work: URL?
    /// gs 讀的那一份：平常＝原檔；圖帶新版色彩描述檔時＝工作夾裡改好標頭的副本（ICCFix）。原檔永遠只讀
    private var input: URL
    /// 這次有沒有改過色彩描述檔的標頭（給介面／命令列講一聲）
    private(set) var iccFixed = false

    /// 這一份指定存到哪（「改存到下載項目」重試用）；nil＝照設定
    let destOverride: URL?

    init(info: PDFInfo, target: Int64?, dest: URL? = nil) {
        self.info = info
        self.target = target
        self.destOverride = dest
        self.input = info.url
    }

    /// 這份壓好要放進哪個資料夾（照設定或指定）；beside＝跟原檔同一夾
    static func destination(for src: URL, override: URL?) -> (dir: URL, beside: Bool) {
        if let o = override { return (o, false) }
        if Prefs.effectivePlace == "beside" { return (src.deletingLastPathComponent(), true) }
        return (URL(fileURLWithPath: Prefs.folder, isDirectory: true), false)
    }

    func cancel() {
        lock.lock(); cancelled = true; let p = proc; lock.unlock()
        if let p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(_ done: @escaping (Outcome) -> Void) {
        q.async {
            let r = self.ladder()
            self.cleanup()
            DispatchQueue.main.async { done(r) }
        }
    }

    /// 命令列用：在呼叫的這條執行緒上跑完（沒有 app 的主迴圈）
    func runSync() -> Outcome {
        let r = ladder()
        cleanup()
        return r
    }

    // MARK: 階梯

    private func ladder() -> Outcome {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Slimly-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return .failed(code: "space", detail: error.localizedDescription) }
        work = dir

        // 暫存要放得下：第一級＋當下這級，各最多原檔大小
        // （圖帶新版色彩描述檔、原檔又在別的磁碟時，改標頭的副本是真的複製一份：多算一份）
        if let free = Engine.fakeFree ?? freeBytes(dir), free < info.bytes * (info.iccNew ? 3 : 2) + 64 * 1024 * 1024 {
            return .failed(code: "space", detail: humanSize(free))
        }

        // 圖帶新版色彩描述檔（Chrome、Canva、部分 Keynote）：先在工作夾做一份改好標頭的副本給 gs 讀（ICCFix）。
        // 改不了（結構看不懂）就照原檔壓——後面的「第一級大 1.5 倍就停」與畫面核對照樣把關
        if info.iccNew, let fixed = ICCFix.patchedCopy(of: info.url, in: dir) {
            input = fixed
            iccFixed = true
        }

        let levels = target == nil ? [Ladder.levels[0]] : Ladder.levels   // 不限大小＝只做看不出差別的那一級
        var tried: [(i: Int, url: URL, bytes: Int64)] = []
        var note: String? = nil
        var skipQ3 = false
        for (i, lv) in levels.enumerated() {
            if isCancelled { return .failed(code: "cancelled", detail: "") }
            // 第二級跟第一級差不到 1%＝圖都照抄或沒超過門檻，第三級（同門檻、只換品質）也不會不一樣：跳過。
            // 第四級不跳：它會降解析度、重壓所有 JPEG，跟第二級不同，跳過去會多砍一級畫質
            if i == 2, skipQ3 { continue }
            let out = dir.appendingPathComponent("\(lv.key).pdf")
            let r = runGS(lv, index: i, output: out)
            if isCancelled { return .failed(code: "cancelled", detail: "") }
            if stalled { return .failed(code: "timeout", detail: "\(Int(Engine.stallLimit))") }
            guard r.status == 0 else { return .failed(code: "engine", detail: r.tail) }
            let bytes = (try? fm.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 else { return .failed(code: "engine", detail: r.tail) }
            guard let n = Inspect.pageCount(out), n == info.pages else {
                return .failed(code: "pages", detail: "\(info.pages)→\(Inspect.pageCount(out) ?? 0)")
            }
            if r.repaired { note = "repaired" }
            tried.append((i, out, bytes))
            if i == 0, Double(bytes) > Double(info.bytes) * Engine.hopeless { break }   // 結構問題：後面幾級也救不回來
            if i == 1, let q1 = tried.first, Double(bytes) >= Double(q1.bytes) * 0.99 { skipQ3 = true }
            // 只留第一級（保底）跟這一級；中間的暫存丟掉
            if tried.count > 2, tried[tried.count - 2].i != 0 {
                try? fm.removeItem(at: tried[tried.count - 2].url)
            }
            if let t = target, bytes <= t { break }
        }
        guard let first = tried.first, let last = tried.last else { return .failed(code: "engine", detail: "") }
        let smallest = tried.map(\.bytes).min() ?? last.bytes
        // 選哪一版：達標＝達標的那一級；沒設目標＝第一級；壓不到目標＝第一級（畫質不犧牲，反正都超標）
        var reached = target.map { last.bytes <= $0 } ?? true
        var pick = reached ? last : first
        if Double(pick.bytes) >= Double(info.bytes) * Engine.minGain { return .noGain(best: pick.bytes) }
        // 交出去之前看一眼：抽頁畫成小圖跟原檔比（見 Guard.swift）。
        //   深級（降解析度）差太多＝變糊了 → 退回第一級（畫質不犧牲，只是沒壓到目標）
        //   第一級也差太多＝壓壞了（東西不見、變色、macOS 畫不出來）→ 不交
        if isCancelled { return .failed(code: "cancelled", detail: "") }
        onProgress?(-1, 0, info.pages)                                   // 介面：正在核對畫面
        guard let w = VisualGuard.worstPage(original: info.url, output: pick.url) else { return .failed(code: "quality", detail: "?") }
        if !VisualGuard.passes(w) {
            if pick.i != 0, let w1 = VisualGuard.worstPage(original: info.url, output: first.url), VisualGuard.passes(w1),
               Double(first.bytes) < Double(info.bytes) * Engine.minGain {
                pick = first; reached = target.map { first.bytes <= $0 } ?? true
                note = "blurry"
            } else {
                return .failed(code: "quality", detail: "\(w.index + 1)|\(Int((w.fraction * 100).rounded()))")
            }
        }
        return place(pick.url, bytes: pick.bytes, level: pick.i, reached: reached, smallest: smallest, note: note)
    }

    private struct GSResult { let status: Int32; let tail: String; let repaired: Bool }

    private func runGS(_ lv: Level, index: Int, output: URL) -> GSResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Engine.gsPath)
        p.arguments = Ladder.gsArgs(lv, input: input.path, output: output.path)
        p.currentDirectoryURL = work
        // gs 自己的暫存（gs_XXXXXX，大檔一級就幾百 MB）也放進這一份的工作夾：按停止、逾時把 gs 收掉時它來不及清，
        // 原本會一直留在系統暫存夾；放在這裡就跟著 cleanup() 一起收
        var env = ProcessInfo.processInfo.environment
        if let w = work { env["TMPDIR"] = w.path }
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        var lastTick = Engine.now
        var errBuf = Data()
        var outBuf = Data()
        let tickLock = NSLock()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            tickLock.lock()
            outBuf.append(d)
            var lines: [String] = []
            while let nl = outBuf.firstIndex(of: 0x0A) {
                lines.append(String(decoding: outBuf[outBuf.startIndex..<nl], as: UTF8.self))
                outBuf.removeSubrange(outBuf.startIndex...nl)
            }
            tickLock.unlock()
            for l in lines where l.hasPrefix("Page ") {
                if let n = Int(l.dropFirst(5).trimmingCharacters(in: .whitespaces)) {
                    tickLock.lock(); lastTick = Engine.now; tickLock.unlock()
                    self.onProgress?(index, n, self.info.pages)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            tickLock.lock(); errBuf.append(d); if errBuf.count > 16_384 { errBuf = errBuf.suffix(8192) }; tickLock.unlock()
        }

        lock.lock(); proc = p; lock.unlock()
        do { try p.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return GSResult(status: -1, tail: error.localizedDescription, repaired: false)
        }
        onProgress?(index, 0, info.pages)

        // 看門狗：每秒看一次，超過 stallLimit 秒沒有新的一頁＝卡住
        let dog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        dog.schedule(deadline: .now() + 1, repeating: 1)
        dog.setEventHandler { [weak self] in
            tickLock.lock(); let idle = Engine.now - lastTick; tickLock.unlock()
            if idle > Engine.stallLimit, p.isRunning {
                self?.lock.lock(); self?.stalled = true; self?.lock.unlock()
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            }
        }
        dog.resume()
        p.waitUntilExit()
        dog.cancel()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); proc = nil; lock.unlock()

        tickLock.lock()
        let err = String(decoding: errBuf, as: UTF8.self)
        tickLock.unlock()
        let tail = err.split(separator: "\n").suffix(6).joined(separator: "\n")
        // pdfi 修補過原檔的毛病時會講「Output may be incorrect」：照樣交，但提醒打開看一下
        let repaired = err.contains("may be incorrect") || err.contains("**** Error")
        return GSResult(status: p.terminationStatus, tail: tail, repaired: repaired)
    }

    // MARK: 放到該放的地方（永不覆蓋）

    private func place(_ tmp: URL, bytes: Int64, level: Int, reached: Bool, smallest: Int64, note: String?) -> Outcome {
        Compressor.place(tmp, src: info.url, destOverride: destOverride, ext: "pdf", bytes: bytes, level: level, reached: reached, smallest: smallest, note: note)
    }

    /// 放到該放的地方（PDF、照片共用）：ext＝壓好那份的副檔名（照片 HEIC／PNG 可能變 jpg）
    static func place(_ tmp: URL, src: URL, destOverride: URL?, ext: String, bytes: Int64, level: Int, reached: Bool, smallest: Int64, note: String?) -> Outcome {
        let fm = FileManager.default
        let (dir, beside) = Compressor.destination(for: src, override: destOverride)
        if !beside {
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { return .failed(code: "permission", detail: dir.path) }
        }
        guard fm.isWritableFile(atPath: dir.path) else { return .failed(code: "permission", detail: dir.path) }

        // 原檔模式＝backup（只在原檔旁邊時）：原檔先收進「未壓縮備份」，壓好的接手原檔名
        if beside && Prefs.original == "backup" {
            let bdir = dir.appendingPathComponent(L("未壓縮備份", "Uncompressed Originals"), isDirectory: true)
            do {
                try fm.createDirectory(at: bdir, withIntermediateDirectories: true)
                let moved = try Files.moveNoClobber(src, into: bdir, name: src.lastPathComponent)
                do {
                    let final = try Files.moveNoClobber(tmp, into: dir, name: cleanName(src, ext: ext))
                    return .saved(Saved(out: final, bytes: bytes, level: level, reached: reached, smallest: smallest, backup: moved, note: note))
                } catch {
                    try? fm.moveItem(at: moved, to: src)     // 放不進去就把原檔搬回來，當作什麼都沒發生
                    return .failed(code: "permission", detail: dir.path)
                }
            } catch {
                return .failed(code: "permission", detail: dir.path)
            }
        }

        // 一般：原檔不動，壓好的另存一份
        let clean = cleanName(src, ext: ext)
        let name: String
        if clean != src.lastPathComponent, src.deletingPathExtension().lastPathComponent != (clean as NSString).deletingPathExtension,
           !fm.fileExists(atPath: dir.appendingPathComponent(clean).path) {
            name = clean      // 「提案_未壓縮.pdf」→「提案.pdf」：檔名本來就在等壓好的那份
        } else {
            let stem = src.deletingPathExtension().lastPathComponent
            name = stem + L("（已壓縮）", " (compressed)") + "." + ext
        }
        do {
            let final = try Files.moveNoClobber(tmp, into: dir, name: name)
            return .saved(Saved(out: final, bytes: bytes, level: level, reached: reached, smallest: smallest, backup: nil, note: note))
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && [NSFileWriteOutOfSpaceError].contains(ns.code) {
                return .failed(code: "space", detail: dir.path)
            }
            return .failed(code: "permission", detail: dir.path)
        }
    }

    /// 檔名去掉「未壓縮」「uncompressed」這類尾綴（壓好的那份就該叫原本的名字）
    static func cleanName(_ u: URL, ext: String) -> String {
        var stem = u.deletingPathExtension().lastPathComponent
        let pats = [#"[\s_\-－—（(]*(未壓縮|未压缩|uncompressed|Uncompressed|UNCOMPRESSED|原檔|原始檔)[）)]*$"#]
        for p in pats {
            if let r = stem.range(of: p, options: .regularExpression) { stem.removeSubrange(r) }
        }
        stem = stem.trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = u.deletingPathExtension().lastPathComponent }
        return stem + "." + ext
    }

    private func freeBytes(_ u: URL) -> Int64? {
        (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// 暫存是本程式自己開的資料夾，做完收掉
    private func cleanup() {
        if let w = work { try? FileManager.default.removeItem(at: w) }
    }
}

enum Files {
    /// 搬到 dir/name；同名已存在就加「 2」「 3」…（跟 Finder 一樣），絕不覆蓋。回傳實際的位置。
    static func moveNoClobber(_ from: URL, into dir: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for n in 1...999 {
            let cand = dir.appendingPathComponent(n == 1 ? name : "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if fm.fileExists(atPath: cand.path) { continue }
            do {
                try fm.moveItem(at: from, to: cand)      // 目的地已存在時 moveItem 會失敗，不會蓋掉——搶到同名就換下一個號碼
                return cand
            } catch {
                if fm.fileExists(atPath: cand.path) { continue }
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
