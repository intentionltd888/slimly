// Watch.swift — 監看資料夾（擴充提案 #5）：掃描器、報表固定丟進某個資料夾，Slimly 開著就自動壓
//
// 規則：
//   ・設定裡加資料夾（預設一個都沒有），每個資料夾各自選目標（25／10／5 MB、不限；預設 25）
//   ・只看資料夾第一層、加進來之後才出現的檔（原本就在的不動）。大小跟修改時間 2 秒沒變＝寫完了才壓（掃描器、下載還在寫的不碰）
//   ・PDF、HEIC、JPEG、PNG 照主視窗同一套引擎壓；其他類型記一筆「略過」
//   ・壓好的放進同一層的「Slimly 已壓縮」，原檔不動；子資料夾不看、檔名帶「（已壓縮）」的不壓＝不會自己壓自己；同名自動加序號
//   ・有電子簽章或表單的不壓（沒人在旁邊問），記一筆原因
//   ・資料夾被移走、沒有權限：狀態改「找不到」「沒有權限」，不當掉；回來了繼續看（回來那一刻已經在的檔不壓）
//   ・可以暫停；暫停時進來的檔記著，繼續之後再壓
// 全部在主執行緒上跑（一秒看一次；壓縮在引擎自己的背景佇列，一次一份）。
import Foundation

final class WatchFolders {
    static let shared = WatchFolders()
    static var outName: String { L("Slimly 已壓縮", "Slimly Compressed") }

    struct Folder { var path: String; var target: Int; var state = "ok" }           // state：ok｜missing｜denied
    private struct Seen { var size: Int64; var mtime: Date; var since: Date; var done: Bool }

    private(set) var folders: [Folder] = []
    private(set) var recent: [[String: Any]] = []                                  // 最新的在前面，最多 30 筆
    private(set) var busyName: String?
    var paused: Bool { get { Store.d.bool(forKey: "SlimlyWatchPaused") } set { Store.d.set(newValue, forKey: "SlimlyWatchPaused") } }
    var onChange: (() -> Void)?

    private var seen: [String: [String: Seen]] = [:]
    private var queue: [(folder: String, url: URL)] = []
    private var comp: Compressing?
    private var timer: Timer?
    private let stable: TimeInterval = 2

    func start() {
        paused_ = false
        folders = ((Store.d.array(forKey: "SlimlyWatch") as? [[String: Any]]) ?? []).compactMap {
            guard let p = $0["path"] as? String else { return nil }
            return Folder(path: p, target: ($0["target"] as? Int) ?? 25)
        }
        for f in folders { baseline(f.path) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    func stop() { timer?.invalidate(); timer = nil; paused_ = true; comp?.cancel() }
    var isBusy: Bool { comp != nil }
    private var paused_ = false                                                  // 結束 app 時：不再接新的

    private func save() { Store.d.set(folders.map { ["path": $0.path, "target": $0.target] }, forKey: "SlimlyWatch") }

    func add(_ path: String, target: Int = 25) {
        let p = Self.norm(path)
        guard !folders.contains(where: { $0.path == p }) else { return }
        folders.append(Folder(path: p, target: target)); save(); baseline(p); tick()
    }
    /// 路徑一律照 standardized 比（/private/tmp 會變成 /tmp：加的時候存的就是這個樣子）
    private static func norm(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
    func remove(_ path: String) {
        let p = Self.norm(path)
        folders.removeAll { $0.path == p || $0.path == path }; seen[p] = nil; queue.removeAll { $0.folder == p }; save(); onChange?()
    }
    func setTarget(_ path: String, _ mb: Int) {
        let p = Self.norm(path)
        if let i = folders.firstIndex(where: { $0.path == p || $0.path == path }) { folders[i].target = max(0, mb); save(); onChange?() }
    }
    func setPaused(_ on: Bool) { paused = on; onChange?(); if !on { tick() } }

    /// 加進來（或資料夾回來）那一刻已經在的檔：當作看過了，不壓
    private func baseline(_ dir: String) {
        var m: [String: Seen] = [:]
        for (u, s, t) in list(dir) ?? [] { m[u.path] = Seen(size: s, mtime: t, since: Date(), done: true) }
        seen[dir] = m
    }

    /// 資料夾第一層的檔（跳過子資料夾、隱藏檔、下載到一半的暫存檔）；nil＝讀不到
    private func list(_ dir: String) -> [(URL, Int64, Date)]? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                                       options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }
        let partial: Set<String> = ["download", "crdownload", "part", "partial", "tmp"]
        return items.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), v.isRegularFile == true,
                  !partial.contains(u.pathExtension.lowercased()), !u.lastPathComponent.hasPrefix("~$") else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
    }

    private func tick() {
        let fm = FileManager.default, now = Date()
        var changed = false
        for i in folders.indices {
            let dir = folders[i].path
            var isDir: ObjCBool = false
            let state: String
            if !fm.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue { state = "missing" }
            else if let files = list(dir) {
                state = "ok"
                if folders[i].state != "ok" { baseline(dir) }                                // 回來了：那一刻已經在的不壓
                var m = seen[dir] ?? [:]
                var present = Set<String>()
                for (u, size, mtime) in files {
                    present.insert(u.path)
                    if var s = m[u.path] {
                        if s.size != size || s.mtime != mtime { s = Seen(size: size, mtime: mtime, since: now, done: false) }   // 新的一版、或還在寫
                        else if !s.done && now.timeIntervalSince(s.since) >= stable && !paused {
                            s.done = true
                            if !queue.contains(where: { $0.url.path == u.path }) { queue.append((dir, u)) }
                        }
                        m[u.path] = s
                    } else {
                        m[u.path] = Seen(size: size, mtime: mtime, since: now, done: false)
                    }
                }
                for k in m.keys where !present.contains(k) { m[k] = nil }
                seen[dir] = m
            } else { state = "denied" }
            if folders[i].state != state { folders[i].state = state; changed = true }
        }
        if changed { onChange?() }
        next()
    }

    private func log(_ d: [String: Any]) {
        var e = d; e["at"] = Date().timeIntervalSince1970
        recent.insert(e, at: 0); if recent.count > 30 { recent.removeLast(recent.count - 30) }
        onChange?()
    }

    private func next() {
        guard comp == nil, !paused, !paused_, !queue.isEmpty else { return }
        let (dir, u) = queue.removeFirst()
        guard let f = folders.first(where: { $0.path == dir }), FileManager.default.fileExists(atPath: u.path) else { next(); return }
        let name = u.lastPathComponent
        let base: [String: Any] = ["name": name, "folder": (dir as NSString).lastPathComponent, "path": u.path]
        // 自己壓出來的（主視窗壓在原檔旁邊的那份）不再壓
        if name.contains("（已壓縮）") || name.contains(" (compressed)") { log(base.merging(["status": "skip", "code": "ours"]) { $1 }); next(); return }
        guard u.pathExtension.lowercased() == "pdf" || Inspect.isImage(u) || OfficeDoc.isOffice(u) else { log(base.merging(["status": "skip", "code": "type"]) { $1 }); next(); return }
        switch Inspect.check(u) {
        case .failure(let e): log(base.merging(["status": "skip", "code": e.code.rawValue]) { $1 }); next()
        case .success(let info):
            if info.signed || info.hasForm { log(base.merging(["status": "skip", "code": info.signed ? "signed" : "form"]) { $1 }); next(); return }
            if info.slimmed { log(base.merging(["status": "skip", "code": "ours"]) { $1 }); next(); return }
            let dest = URL(fileURLWithPath: dir).appendingPathComponent(Self.outName, isDirectory: true)
            do { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true) }
            catch { log(base.merging(["status": "failed", "code": "permission"]) { $1 }); next(); return }
            let target: Int64? = f.target > 0 ? Int64(f.target) << 20 : nil
            let c = makeCompressor(info, target: target, dest: dest)
            comp = c; busyName = name; onChange?()
            c.run { [weak self] o in
                guard let self else { return }
                self.comp = nil; self.busyName = nil
                switch o {
                case .saved(let s):
                    self.log(base.merging(["status": "saved", "before": info.bytes, "after": s.bytes, "out": s.out.path, "outName": s.out.lastPathComponent, "reached": s.reached]) { $1 })
                    Prefs.remember(["name": name, "out": s.out.path, "before": info.bytes, "after": s.bytes, "at": Date().timeIntervalSince1970])
                case .noGain(let b): self.log(base.merging(["status": "nogain", "before": info.bytes, "after": b]) { $1 })
                case .failed(let code, _): self.log(base.merging(["status": "failed", "code": code]) { $1 })
                }
                self.next()
            }
        }
    }

    /// 給介面：資料夾、狀態、最近處理的
    var dict: [String: Any] {
        let home = NSHomeDirectory()
        return ["type": "watch", "paused": paused, "busy": busyName ?? "", "waiting": queue.count,
                "folders": folders.map { ["path": $0.path, "name": ($0.path as NSString).lastPathComponent, "target": $0.target, "state": $0.state,
                                          "shown": $0.path.hasPrefix(home) ? "~" + String($0.path.dropFirst(home.count)) : $0.path] },
                "recent": recent]
    }
}
