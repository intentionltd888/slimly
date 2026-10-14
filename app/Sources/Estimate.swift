// Estimate.swift — 壓前預估（擴充提案 #2）：還沒按壓縮，先告訴使用者每一級大概會壓到多大
//
// 做法：抽幾頁原樣搬成一份小 PDF（MuPDF，串流不重壓），每一級用同一套 gs 參數壓一次，
//       「樣本壓完／樣本原本」的比例 × 整份大小＝這一級的預估。
//   ・64 MB 以內＝整份直接壓（數字就是真的壓出來的大小；gs 一秒處理 50–90 MB，六級約 10 秒內）
//   ・更大的才抽樣：樣本控制在 64 MB、最多 24 頁，一定含最重的那一頁（大圖多半在那裡），其餘平均分布。
//     抽太少頁誤差會很大：每頁一張不同照片的 60 頁檔，抽 4 頁偏 +17%、抽 8 頁 +33%、抽 18 頁 +5%（實測）
//   ・跑在背景、比壓縮低一階；使用者一按壓縮、換檔、清掉就停（工作夾跟著收，不留在系統暫存夾）
import Foundation
import ImageIO

struct Estimate {
    let bytes: [Int64?]      // 每一級（Q1…Q6）預估多大；nil＝那一級沒算出來
    let exact: Bool          // 整份直接壓（不是抽樣）
    let sample: [Int]        // 抽了哪幾頁（0 起算）
    let seconds: Double

    var dict: [String: Any] {
        ["exact": exact, "sample": sample, "seconds": (seconds * 10).rounded() / 10,
         "levels": bytes.enumerated().map { i, b in ["key": Ladder.levels[i].key, "label": Ladder.levels[i].label, "bytes": b.map { NSNumber(value: $0) } ?? NSNull()] }]
    }
}

final class Estimator {
    let info: PDFInfo
    /// 每算好一級回報一次（第幾級, 預估位元組）；在背景執行緒上叫
    var onLevel: ((Int, Int64) -> Void)?

    private let lock = NSLock()
    private var cancelled = false
    private var proc: Process?
    private static let exactBytes: Int64 = 64 << 20, sampleBudget: Int64 = 64 << 20, maxSample = 24

    init(info: PDFInfo) { self.info = info }

    func cancel() {
        lock.lock(); cancelled = true; let p = proc; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// 抽哪幾頁：最重的一頁＋平均分布的幾頁（不重複、照頁序）
    static func pick(weights w: [Int64], pages n: Int, k: Int) -> [Int] {
        guard n > 0 else { return [] }
        let k = max(1, min(k, n))
        var s = Set<Int>()
        if let heavy = w.indices.max(by: { w[$0] < w[$1] }), heavy < n { s.insert(heavy) }
        var j = 0
        while s.count < k && j < k * 4 {
            let i = k == 1 ? 0 : Int((Double(j % k) + 0.5) * Double(n) / Double(k))
            s.insert(min(n - 1, i)); j += 1
        }
        var i = 0
        while s.count < k && i < n { s.insert(i); i += 1 }
        return s.sorted()
    }

    /// 在呼叫的這條執行緒上跑完；被取消回 nil。exact＝不抽樣、整份每一級都壓（命令列對照用）
    func run(exact forceExact: Bool = false) -> Estimate? {
        if info.kind == .image { return runImage() }
        if info.kind == .office { return runOffice() }
        let t0 = Date(), fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Slimly-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? fm.removeItem(at: dir) }

        let n = max(1, info.pages)
        var src = info.url, sample: [Int] = Array(0..<n), exact = true
        if !forceExact && info.bytes > Self.exactBytes {
            let w = ((try? MuTool.run(["weights", info.url.path], timeout: 60))?["w"] as? [NSNumber])?.map { $0.int64Value } ?? []
            let avg = max(1, info.bytes / Int64(n))
            let k = Int(max(1, min(Int64(Self.maxSample), Self.sampleBudget / avg)))
            if k < n {
                sample = Self.pick(weights: w, pages: n, k: k)
                let s = dir.appendingPathComponent("sample.pdf")
                guard !isCancelled, (try? MuTool.run(["sample", info.url.path, s.path, sample.map(String.init).joined(separator: ",")], timeout: 120)) != nil else { return nil }
                src = s; exact = false
            }
        }
        if info.iccNew, let fixed = ICCFix.patchedCopy(of: src, in: dir) { src = fixed }   // 跟壓縮同一套：圖帶新版色彩描述檔的先改標頭
        let inBytes = exact ? info.bytes : size(src)
        guard inBytes > 0 else { return nil }

        var out: [Int64?] = Array(repeating: nil, count: Ladder.levels.count)
        for (i, lv) in Ladder.levels.enumerated() {
            if isCancelled { return nil }
            let o = dir.appendingPathComponent("\(lv.key).pdf")
            guard gs(lv, input: src, output: o, work: dir) == 0, !isCancelled else { if isCancelled { return nil }; continue }
            let b = size(o); try? fm.removeItem(at: o)
            guard b > 0 else { continue }
            let est = exact ? b : Int64((Double(info.bytes) * Double(b) / Double(inBytes)).rounded())
            out[i] = est
            onLevel?(i, est)
        }
        return Estimate(bytes: out, exact: exact, sample: sample, seconds: Date().timeIntervalSince(t0))
    }

    /// 照片：每一級直接在記憶體裡編一次（一張照片一秒內），數字就是真的
    private func runImage() -> Estimate? {
        let t0 = Date()
        guard let src = CGImageSourceCreateWithURL(info.url as CFURL, nil), let full = ImageLadder.decode(src, info: info) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let png = info.alpha && ImageLadder.hasTransparency(src)
        var out: [Int64?] = Array(repeating: nil, count: ImageLadder.levels.count)
        for i in ImageLadder.levels.indices {
            if isCancelled { return nil }
            if png && (i == 1 || i == 2) { out[i] = out[0]; if let b = out[i] { onLevel?(i, b) }; continue }   // PNG 只縮尺寸：跟第一級一樣
            guard let d = ImageLadder.encode(full, props: props, level: i, png: png, stripGPS: Prefs.stripGPS) else { continue }
            out[i] = Int64(d.count); onLevel?(i, Int64(d.count))
        }
        return Estimate(bytes: out, exact: true, sample: [0], seconds: Date().timeIntervalSince(t0))
    }

    /// Office 檔：解開、每一級把裡面的圖都重壓一次算整份多大（其他部分不動，數字幾乎就是真的）
    private func runOffice() -> Estimate? {
        let t0 = Date(), fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Slimly-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        guard (try? fm.createDirectory(at: work, withIntermediateDirectories: true)) != nil,
              OfficeDoc.sh("/usr/bin/unzip", ["-q", "-o", info.url.path, "-d", work.path]).0 <= 1,
              let plan = OfficeCompressor.plan(info, dir: work, target: nil, every: true, cancelled: { self.isCancelled }, onLevel: { i, b in self.onLevel?(i, b) }) else { return nil }
        return Estimate(bytes: plan.levels, exact: true, sample: [], seconds: Date().timeIntervalSince(t0))
    }

    private func size(_ u: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0 }

    private func gs(_ lv: Level, input: URL, output: URL, work: URL) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Engine.gsPath)
        p.arguments = Ladder.gsArgs(lv, input: input.path, output: output.path)
        p.currentDirectoryURL = work
        var env = ProcessInfo.processInfo.environment; env["TMPDIR"] = work.path; p.environment = env   // gs 的暫存也放工作夾
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        p.qualityOfService = .utility                                                                   // 比壓縮低一階
        lock.lock()
        if cancelled { lock.unlock(); return -1 }
        do { try p.run() } catch { lock.unlock(); return -1 }
        proc = p; lock.unlock()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }                              // 一級最多 3 分鐘
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: killer)
        p.waitUntilExit(); killer.cancel()
        lock.lock(); proc = nil; lock.unlock()
        return p.terminationStatus
    }
}
