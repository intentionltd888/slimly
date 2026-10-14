// Slimly — 把 PDF 壓到寄得出去，畫質幾乎看不出差別
//
// 這個檔是主控：視窗、拖放、排隊、停止、Dock 與通知、右鍵服務、驗收鉤。其他檔：
//   ・Engine.swift：壓一份（品質階梯＋驗收＋永不覆蓋）　・Inspect.swift：收件檢查（不是 PDF／有密碼／有簽章…）
//   ・Installer.swift：DMG 雙擊即裝＋釘 Dock　　　　　　・Prefs.swift：語言、設定、紀錄
//
// 形態（照 Fully／Talky）：Dock app＋一個視窗（WKWebView＝ui.html）。介面層只管畫面，
// 兩層用 WKScriptMessageHandler（JS→Swift）與 window.appEvent（Swift→JS）一來一往，一次一個 JSON 事件。

import AppKit
import PDFKit
import UniformTypeIdentifiers
import UserNotifications
import WebKit

// ─── 常數 ────────────────────────────────────────────────────────────

enum Const {
    static let appName = "Slimly"
    static let winSize = NSSize(width: 400, height: 640)   // 比 Fully 面板高 40：完成畫面要放「前後大小＋達標膠囊＋兩顆鍵」，一批時還有清單
    /// 材料色的亮／暗兩色（跟 ui.html 的 token 同值，家族共用 Talky 的 Neu 值），視窗底色與標題列跟著走
    static let materialColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0x2A/255, green: 0x2C/255, blue: 0x31/255, alpha: 1)
            : NSColor(red: 0xEE/255, green: 0xEF/255, blue: 0xF2/255, alpha: 1)
    }
}

// ─── 視窗裡的 WebView：收檔案（拖進來）＋把壓好的拖出去 ─────────────────

final class DropWebView: WKWebView, NSDraggingSource {
    var onFiles: (([URL]) -> Void)?
    var onHover: ((Bool) -> Void)?
    /// 介面層在 mousedown 時先告訴我們「要拖哪幾個檔」（dragArm），滑鼠真的拖動時開原生拖曳
    var armedFiles: [String] = []
    private var downEvent: NSEvent?

    private func fileURLs(_ s: NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func isOwn(_ s: NSDraggingInfo) -> Bool { (s.draggingSource as AnyObject?) === self }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        if isOwn(s) { return [] }                           // 自己拖出去的不要又收回來
        if !fileURLs(s).isEmpty { onHover?(true); return .copy }
        return super.draggingEntered(s)
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        if isOwn(s) { return [] }
        return fileURLs(s).isEmpty ? super.draggingUpdated(s) : .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { onHover?(false); super.draggingExited(s) }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool {
        fileURLs(s).isEmpty ? super.prepareForDragOperation(s) : true
    }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let urls = fileURLs(s)
        onHover?(false)
        if !urls.isEmpty, !isOwn(s) { onFiles?(urls); return true }
        return super.performDragOperation(s)
    }
    override func concludeDragOperation(_ s: NSDraggingInfo?) {
        if let s, !fileURLs(s).isEmpty { return }           // 檔案我們自己收了，不讓 WebView 拿去「打開」
        super.concludeDragOperation(s)
    }

    override func mouseDown(with e: NSEvent) { downEvent = e; super.mouseDown(with: e) }
    override func mouseUp(with e: NSEvent) { armedFiles = []; downEvent = nil; super.mouseUp(with: e) }
    override func mouseDragged(with e: NSEvent) {
        if !armedFiles.isEmpty, let d = downEvent,
           hypot(e.locationInWindow.x - d.locationInWindow.x, e.locationInWindow.y - d.locationInWindow.y) > 4 {
            let files = armedFiles.filter { FileManager.default.fileExists(atPath: $0) }
            armedFiles = []
            if !files.isEmpty {
                let p = convert(d.locationInWindow, from: nil)
                let items = files.enumerated().map { i, f -> NSDraggingItem in
                    let it = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: f) as NSURL)
                    let icon = NSWorkspace.shared.icon(forFile: f)
                    let side: CGFloat = 64
                    it.setDraggingFrame(NSRect(x: p.x - side / 2 + CGFloat(i * 6), y: p.y - side / 2 - CGFloat(i * 6),
                                               width: side, height: side), contents: icon)
                    return it
                }
                beginDraggingSession(with: items, event: d, source: self)
                return
            }
        }
        super.mouseDragged(with: e)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation {
        c == .outsideApplication ? .copy : []
    }
}

// ─── 視窗的底：接 iPhone 接力相機（「從 iPhone 輸入 → 掃描文件／拍照」拍好的東西會送到這裡）──────
//
// macOS 問整條回應鏈「誰收圖片／PDF」；WebView 的上一層就是這個 view，說「我收」，拍好了就交給「掃描為 PDF」。

final class HostView: NSView, NSServicesMenuRequestor {
    var onImport: (([URL]) -> Void)?
    private static let types: [NSPasteboard.PasteboardType] = [.pdf, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"), .png, .tiff]

    override func validRequestor(forSendType s: NSPasteboard.PasteboardType?, returnType r: NSPasteboard.PasteboardType?) -> Any? {
        if s == nil, let r, Self.types.contains(r) || NSImage.imageTypes.contains(r.rawValue) { return self }
        return super.validRequestor(forSendType: s, returnType: r)
    }
    /// 從 iPhone 拍進來的照片先放這裡（交給「掃描為 PDF」用）：打開 app 時清掉上次留下的，再拍時清掉一小時前的
    static let cameraDir = FileManager.default.temporaryDirectory.appendingPathComponent("Slimly-Camera", isDirectory: true)
    static func cleanCamera(olderThan age: TimeInterval) {
        let fm = FileManager.default, cut = Date().addingTimeInterval(-age)
        for f in (try? fm.contentsOfDirectory(at: cameraDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let t = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if t < cut { try? fm.removeItem(at: f) }
        }
    }
    func readSelection(from pb: NSPasteboard) -> Bool {
        let dir = Self.cameraDir
        Self.cleanCamera(olderThan: 3600)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var urls: [URL] = []
        for (k, item) in (pb.pasteboardItems ?? []).enumerated() {
            // 掃描文件＝PDF（已經拉正）；拍照＝JPEG／HEIC；都沒有就轉成 JPEG
            for (t, ext) in [(NSPasteboard.PasteboardType.pdf, "pdf"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"), (NSPasteboard.PasteboardType("public.heic"), "heic"), (.png, "png"), (.tiff, "tiff")] {
                if let data = item.data(forType: t) {
                    let u = dir.appendingPathComponent("iPhone-\(stamp)-\(k + 1).\(ext)")
                    if (try? data.write(to: u)) != nil { urls.append(u) }
                    break
                }
            }
        }
        if urls.isEmpty, let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
            let u = dir.appendingPathComponent("iPhone-\(stamp).jpg")
            if (try? jpg.write(to: u)) != nil { urls.append(u) }
        }
        guard !urls.isEmpty else { return false }
        onImport?(urls)
        return true
    }
}

// ─── Dock 圖示：進度條＋還有幾份 ──────────────────────────────────────

final class DockTileView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSApp.applicationIconImage?.draw(in: b)
        let s = min(b.width, b.height)
        // 標記下方的留白：方磚約佔畫布 10%–92%；條子放在 13%–20.5%，左右內縮到方磚直邊內
        let track = NSRect(x: b.minX + s * 0.22, y: b.minY + s * 0.13, width: s * 0.56, height: s * 0.075)
        let r = track.height / 2
        NSColor(red: 0x2B/255, green: 0x2D/255, blue: 0x33/255, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
        let inner = track.insetBy(dx: s * 0.012, dy: s * 0.012)
        let ir = inner.height / 2
        let w = max(inner.height, inner.width * CGFloat(min(1, max(0, progress))))
        NSColor(red: 0xF4/255, green: 0xF7/255, blue: 0xF5/255, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height), xRadius: ir, yRadius: ir).fill()
        // 進度的頭：家族共用的藍點（「正在做」只有這個顏色），大圖示才畫得出來
        if s >= 96, progress > 0.02, progress < 0.995 {
            let d = inner.height * 0.62
            NSColor(red: 0, green: 0x3C/255, blue: 1, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: inner.minX + w - inner.height / 2 - d / 2, y: inner.midY - d / 2, width: d, height: d)).fill()
        }
    }
}

enum DockTile {
    private static let view = DockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    /// frac＝nil：拿掉進度條；left＝還有幾份（含正在壓的），>1 才顯示數字
    static func set(_ frac: Double?, left: Int) {
        let t = NSApp.dockTile
        if let f = frac {
            view.progress = f
            if t.contentView !== view { t.contentView = view }
        } else {
            t.contentView = nil
        }
        t.badgeLabel = left > 1 ? "\(left)" : nil
        t.display()
    }
}

// ─── 一份排隊中的檔 ──────────────────────────────────────────────────

struct Item {
    let id: String
    let info: PDFInfo
    var dest: URL? = nil            // 指定存到哪（「改存到下載項目」重試）
    init(_ info: PDFInfo, dest: URL? = nil) {
        self.id = UUID().uuidString
        self.info = info
        self.dest = dest
    }
    var dict: [String: Any] {
        ["id": id, "name": info.url.lastPathComponent, "path": info.url.path, "bytes": info.bytes, "pages": info.pages,
         "slimmed": info.slimmed, "form": info.hasForm, "editable": info.editable, "icc": info.iccNew,
         "kind": info.kind.rawValue, "w": info.width, "h": info.height, "fmt": info.format]
    }
}

// ─── 主控 ────────────────────────────────────────────────────────────

final class Controller: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate,
                        NSWindowDelegate, UNUserNotificationCenterDelegate {

    private var window: NSWindow?
    private var web: DropWebView!
    private var uiReady = false
    private var pendingOpen: [(urls: [URL], auto: Bool)] = []     // 介面還沒好之前送進來的檔（例如拖到 Dock 圖示把 app 叫起來）

    // ── 佇列 ──
    private var staged: [Item] = []          // 放進來了、還沒開始
    private var queue: [Item] = []           // 這一批還沒輪到的
    private var cur: Item?
    private var comp: Compressing?
    private var running = false
    private var stopping = false
    private var stoppedItem: Item?
    private var results: [[String: Any]] = []
    private var lastResults: [[String: Any]] = []
    private var batchTotal = 0
    private var batchIndex = 0
    private var pendingSigned: [PDFInfo] = []
    private var autoAfterSigned = false
    private var activity: NSObjectProtocol?
    private var curLevel = -1
    private var passStart = Date()
    private var lastEmit = Date.distantPast

    // ── 所有工具（2.0）──
    private var toolTarget: String?           // 畫面開著哪個工具：拖進來的檔交給它，不是拿去壓縮
    private var toolCancel: ToolCancel?       // 正在跑的工具（按「停止」＝立旗子）
    private var toolActivity: NSObjectProtocol?
    // ── 編輯器（2.1）：一份 PDF 一個視窗 ──
    private var editors: [EditorWindowController] = []
    // ── 壓前預估：放進來一份、還沒壓 → 背景估每一級大概多大 ──
    private var estimator: Estimator?
    private var estimateID: String?                 // 正在估（或估好了）的是哪一份
    private var estimateDone: [String: Any]?        // 估好的結果（介面重新載入時再送一次）
    private let estimateGroup = DispatchGroup()

    private var args: [String] { CommandLine.arguments }
    private var isTest: Bool { Store.isTest }
    private var forceWizard: Bool { args.contains("--wizard") }

    // MARK: 啟動

    func applicationDidFinishLaunching(_ n: Notification) {
        HostView.cleanCamera(olderThan: 0)
        // 安裝器：DMG 裡雙擊 → 問一句 → 搬進 /Applications → 釘 Dock → 從那裡重開
        if Installer.isRunningFromDiskImage, !isTest {
            Installer.offerInstallFromDiskImage(autoYes: args.contains("--install"))
            return
        }
        if let i = args.firstIndex(of: "--eject"), i + 1 < args.count { Installer.ejectLater(args[i + 1]) }
        // 每次從「應用程式」打開都檢查 Dock 那格指對沒有；第一次打開還沒釘就釘（之後使用者自己拿掉就不再加回去）
        if Installer.isRunningFromApplications, !isTest {
            let first = !UserDefaults.standard.bool(forKey: "dockPinned")
            UserDefaults.standard.set(true, forKey: "dockPinned")
            Dock.ensure(appURL: Bundle.main.bundleURL, pinIfMissing: first)
        }
        if isTest {
            Store.resetTestDefaults()
            // 擺畫面（--demo）與 --no-wizard 不蓋精靈；單拍 --snapshot＝全新安裝的樣子（會有精靈）
            if (args.contains("--demo") || args.contains("--no-wizard")) && !forceWizard { Prefs.wizardDone = true }
        }

        NSApp.setActivationPolicy(.regular)
        applyTheme()

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "app")
        cfg.setURLSchemeHandler(CompareImages.shared, forURLScheme: CompareImages.scheme)   // 前後對照的圖
        web = DropWebView(frame: NSRect(origin: .zero, size: Const.winSize), configuration: cfg)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")      // 讓 CSS 的材料色自己畫
        if web.responds(to: Selector(("setInspectable:"))) { web.setValue(true, forKey: "inspectable") }
        web.onFiles = { [weak self] urls in
            guard let self else { return }
            if let t = self.toolTarget { self.toolFiles(urls, tool: t) } else { self.add(urls, autostart: false) }
        }
        web.onHover = { [weak self] on in self?.emit(["type": "hover", "on": on]) }
        guard let ui = Bundle.main.url(forResource: "ui", withExtension: "html") else { fatalError("ui.html 不在 bundle 裡") }
        web.loadFileURL(ui, allowingReadAccessTo: ui.deletingLastPathComponent())

        installMenu()
        NSApp.servicesProvider = self                      // Finder 右鍵「服務 → 用 Slimly 壓縮」
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self

        // 監看資料夾：app 開著就看；狀態一變就送給介面
        WatchFolders.shared.onChange = { [weak self] in self?.emit(WatchFolders.shared.dict) }
        WatchFolders.shared.start()

        if !isTest { showWindow() }
    }

    private func showWindow() {
        if window == nil {
            // Talky 式標題列：.titled 留在上面、透明、底色跟材料同色；紅＝收起（不結束）
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Const.winSize),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = Const.appName
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isOpaque = true
            w.backgroundColor = Const.materialColor
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.collectionBehavior = [.fullScreenNone]
            w.delegate = self
            let host = HostView(frame: NSRect(origin: .zero, size: Const.winSize))
            host.onImport = { [weak self] urls in self?.cameraImport(urls) }
            web.frame = host.bounds
            web.autoresizingMask = [.width, .height]
            host.addSubview(web)
            w.contentView = host
            w.setFrameAutosaveName("SlimlyWindow")
            if !w.setFrameUsingName("SlimlyWindow") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(web)
    }

    /// 點 Dock 圖示／在 Finder 再按一次＝叫回視窗
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 紅鍵＝收起，不結束（壓縮中也照樣在背景跑，Dock 圖示看得到進度）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// 壓縮中要結束：講清楚會停在哪、原檔都沒動
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard running, !isTest else { return .terminateNow }
        let a = NSAlert()
        a.messageText = L("還在壓縮，確定要結束？", "Still compressing — quit anyway?")
        let left = queue.count + (cur == nil ? 0 : 1)
        a.informativeText = L("還有 \(left) 份沒壓完。結束會停在這裡：已經壓好的留著，沒壓完的原檔都沒動。",
                              "\(left) still to go. Quitting stops here: finished files stay, and nothing unfinished was touched.")
        a.addButton(withTitle: L("繼續壓", "Keep Going"))
        a.addButton(withTitle: L("結束", "Quit"))
        if a.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        comp?.cancel()
        return .terminateNow
    }
    func applicationWillTerminate(_ n: Notification) {
        comp?.cancel(); toolCancel?.cancel()
        stopEstimate(wait: true)
        stopWatch(wait: true)
        // 編輯器的背景工作做完（最多等 5 秒）再收工作夾：不然結束的那一刻還在寫的檔會留在系統暫存夾
        editors.forEach { e in
            e.doc.closed = true
            let done = DispatchSemaphore(value: 0); e.doc.q.async { done.signal() }; _ = done.wait(timeout: .now() + 5)
            e.doc.cleanup()
        }
    }

    /// 最小的主選單：⌘O 選檔、⌘W 收起、⌘, 設定；編輯選單讓 ⌘C／⌘V 能用在輸入框
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("關於 Slimly", "About Slimly"), action: #selector(menuAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("設定…", "Settings…"), action: #selector(menuSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隱藏 Slimly", "Hide Slimly"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("結束 Slimly", "Quit Slimly"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)

        let fileItem = NSMenuItem(); let file = NSMenu(title: L("檔案", "File"))
        file.addItem(withTitle: L("選擇 PDF…", "Choose PDFs…"), action: #selector(menuOpen), keyEquivalent: "o").target = self
        file.addItem(withTitle: L("用編輯器打開…", "Open in Editor…"), action: #selector(menuEdit), keyEquivalent: "e").target = self
        file.addItem(withTitle: L("編輯與轉檔…", "Edit & Convert…"), action: #selector(menuTools), keyEquivalent: "t").target = self
        file.addItem(.separator())
        // 接力相機：macOS 自己把這一項換成「從 iPhone 輸入 → 拍照／掃描文件」，拍好的交給「掃描為 PDF」
        let cam = NSMenuItem(title: L("從 iPhone 輸入", "Import from iPhone"), action: nil, keyEquivalent: "")
        cam.identifier = NSMenuItem.importFromDeviceIdentifier
        file.addItem(cam)
        file.addItem(.separator())
        file.addItem(withTitle: L("關閉視窗", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file; main.addItem(fileItem)


        let editItem = NSMenuItem(); let edit = NSMenu(title: L("編輯", "Edit"))
        edit.addItem(withTitle: L("復原", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("剪下", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("拷貝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("貼上", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("全選", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)

        let winItem = NSMenuItem(); let win = NSMenu(title: L("視窗", "Window"))
        win.addItem(withTitle: L("縮到 Dock", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win; main.addItem(winItem)
        NSApp.mainMenu = main
    }
    @objc private func menuAbout() { showWindow(); emit(["type": "page", "name": "settings"]) }
    @objc private func menuSettings() { showWindow(); emit(["type": "page", "name": "settings"]) }
    @objc private func menuOpen() { showWindow(); pickFiles() }
    @objc private func menuTools() { showWindow(); emit(["type": "openTool", "id": ""]) }
    @objc private func menuEdit() { pickForEditor() }

    // MARK: 編輯器

    private func pickForEditor() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.pdf]
        p.message = L("選 PDF（選好幾份＝照順序合成一份來編輯）", "Choose PDFs (several are combined in order)")
        p.prompt = L("打開", "Open")
        guard p.runModal() == .OK else { return }
        openEditor(p.urls)
    }
    /// 打開編輯器：第一份開一個視窗，其他的接在後面（＝合併）；同一份已經開著就叫到前面
    func openEditor(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard let first = pdfs.first else { return }
        if pdfs.count == 1, let e = editors.first(where: { $0.doc.original.standardizedFileURL == first.standardizedFileURL }) { e.present(); return }
        let e = EditorWindowController(url: first)
        e.isTest = isTest
        e.pendingInsert = Array(pdfs.dropFirst())
        e.onClose = { [weak self] c in self?.editors.removeAll { $0 === c } }
        e.onCompress = { [weak self] u in self?.showWindowUnlessTest(); self?.add([u], autostart: true) }
        editors.append(e)
        if !isTest { e.present() }
    }

    // MARK: 外觀

    private func applyTheme() {
        switch Prefs.theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
        emit(["type": "theme", "mode": Prefs.theme])
    }

    // MARK: 檔案從哪進來：拖進視窗／拖到 Dock 圖示・打開檔案／右鍵服務／⌘O

    func application(_ application: NSApplication, open urls: [URL]) {
        showWindowUnlessTest()
        add(urls, autostart: true)
    }

    @objc func compressService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = L("沒有選到檔案", "No files selected") as NSString
            return
        }
        showWindowUnlessTest()
        add(urls, autostart: true)
    }

    private func showWindowUnlessTest() { if !isTest { showWindow() } }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.pdf, .folder, .heic, .heif, .jpeg, .png] + ["docx", "pptx", "xlsx"].compactMap { UTType(filenameExtension: $0) }
        p.message = L("選 PDF、照片或 Office 檔（HEIC、JPEG、PNG、docx、pptx、xlsx；也可以選整個資料夾）", "Choose PDFs, photos or Office files (or a whole folder)")
        p.prompt = L("選好了", "Choose")
        guard p.runModal() == .OK else { return }
        add(p.urls, autostart: false)
    }

    // MARK: 收件

    /// 放進來。autostart＝從 Dock／打開檔案／右鍵服務進來的：使用者已經表達「壓這個」，直接開始
    private func add(_ urls: [URL], autostart: Bool) {
        guard uiReady else { pendingOpen.append((urls, autostart)); return }
        let known = Set((staged + queue + [cur].compactMap { $0 }).map { $0.info.url.standardizedFileURL.path })
        emit(["type": "reading"])
        DispatchQueue.global(qos: .userInitiated).async {
            let (files, emptyFolders) = Inspect.expand(urls)
            var ok: [PDFInfo] = [], skipped: [[String: String]] = [], signed: [PDFInfo] = []
            var seen = known
            for f in files {
                let key = f.standardizedFileURL.path
                if seen.contains(key) { skipped.append(["name": f.lastPathComponent, "code": SkipCode.duplicate.rawValue, "path": f.path]); continue }
                seen.insert(key)
                switch Inspect.check(f) {
                // 有簽章（壓了會失效）或有可填寫的表單（gs 會把欄位丟掉）：先問，不默默壓。
                // 圖片帶新版色彩描述檔的，引擎自己修（ICCFix），不再問
                case .success(let info): if info.signed || info.hasForm { signed.append(info) } else { ok.append(info) }
                case .failure(let e): skipped.append(["name": e.name, "code": e.code.rawValue, "path": f.path])
                }
            }
            for d in emptyFolders { skipped.append(["name": d, "code": "folderEmpty"]) }
            DispatchQueue.main.async { self.accept(ok.map { Item($0) }, skipped: skipped, signed: signed, autostart: autostart) }
        }
    }

    private func accept(_ items: [Item], skipped: [[String: String]], signed: [PDFInfo], autostart: Bool) {
        if running {
            queue += items
            batchTotal += items.count
            updateDock()
            emit(["type": "queued", "added": items.count, "left": queue.count, "skipped": skipped])
        } else {
            staged += items
            emit(["type": "staged", "items": staged.map(\.dict), "added": items.count, "skipped": skipped])
            refreshEstimate()
        }
        if !signed.isEmpty {
            pendingSigned += signed
            autoAfterSigned = autoAfterSigned || autostart
            emit(["type": "signed", "names": pendingSigned.map { $0.url.lastPathComponent },
                  "kinds": pendingSigned.map(Self.askKind)])
            return
        }
        // 精靈還沒走完（第一次打開就直接丟檔進來）：先放著，走完精靈按「好了，開始用」才開始
        if autostart, !running, !staged.isEmpty, Prefs.wizardDone || isTest { start() }
    }

    /// 先問的原因（介面依這個講話）：簽章最嚴重，其次表單
    static func askKind(_ i: PDFInfo) -> String { i.signed ? "signed" : "form" }

    // MARK: 排隊與壓縮

    private func start() {
        guard !running else { return }                  // 壓縮中再按一次不會重來（主鍵在這時候是「停止」）
        guard !staged.isEmpty else { emit(["type": "nudge"]); return }
        stopEstimate(wait: false)                       // 開始壓了：預估不用了，gs 讓給壓縮
        running = true
        stopping = false
        queue = staged
        staged = []
        results = []
        batchTotal = queue.count
        batchIndex = 0
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Compressing PDFs")
        emit(["type": "start", "total": batchTotal, "target": Prefs.targetMB])
        next()
    }

    private func next() {
        guard running else { return }
        if stopping { finalizeStop(); return }
        guard !queue.isEmpty else { finish(stopped: false); return }
        let it = queue.removeFirst()
        cur = it
        batchIndex += 1
        curLevel = -1
        passStart = Date()
        // 先看存不存得進去：壓完才發現沒權限＝白等
        if let dir = destProblem(it) {
            record(it, ["status": "failed", "code": "permission", "detail": dir])
            cur = nil
            DispatchQueue.main.async { self.next() }
            return
        }
        let c = makeCompressor(it.info, target: Prefs.targetBytes, dest: it.dest)        // PDF／照片／Office 檔
        comp = c
        c.onProgress = { [weak self] lv, pg, n in DispatchQueue.main.async { self?.progress(it, lv, pg, n) } }
        c.run { [weak self] o in self?.finished(it, o) }
        progress(it, 0, 0, it.info.pages)
    }

    /// 壓前預估：清單剛好一份、還沒開始壓 → 背景估；同一份不重估；換檔、清掉、開始壓就停
    private func refreshEstimate() {
        let one = (!running && staged.count == 1) ? staged[0] : nil
        if let one, one.id == estimateID { return }
        stopEstimate(wait: false)
        guard let one else { return }
        let e = Estimator(info: one.info), id = one.id
        estimator = e; estimateID = id; estimateDone = nil
        e.onLevel = { [weak self] i, b in
            DispatchQueue.main.async { if self?.estimateID == id { self?.emit(["type": "estimate", "id": id, "state": "level", "i": i, "bytes": b]) } }
        }
        emit(["type": "estimate", "id": id, "state": "start", "bytes": one.info.bytes])
        estimateGroup.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = e.run()
            DispatchQueue.main.async {
                defer { self?.estimateGroup.leave() }
                guard let self, self.estimator === e else { return }
                self.estimator = nil
                var d = r?.dict ?? [:]
                d["type"] = "estimate"; d["id"] = id; d["state"] = r == nil ? "failed" : "done"; d["bytes"] = one.info.bytes
                self.estimateDone = d
                self.emit(d)
            }
        }
    }
    /// 監看資料夾：結束前停掉正在壓的那份，等它收工作夾（最多 5 秒）
    private func stopWatch(wait: Bool) {
        WatchFolders.shared.stop()
        guard wait else { return }
        let t = Date().addingTimeInterval(5)
        while WatchFolders.shared.isBusy && Date() < t { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
    /// wait＝結束 app 前：等它把工作夾收掉（最多 3 秒）
    private func stopEstimate(wait: Bool) {
        estimator?.cancel(); estimator = nil; estimateID = nil; estimateDone = nil
        if wait {
            let t = Date().addingTimeInterval(3)
            while estimateGroup.wait(timeout: .now()) == .timedOut && Date() < t { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
    }

    private func destProblem(_ it: Item) -> String? {
        let (dir, beside) = Compressor.destination(for: it.info.url, override: it.dest)
        let fm = FileManager.default
        if !beside { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        return fm.isWritableFile(atPath: dir.path) ? nil : dir.path
    }

    private func progress(_ it: Item, _ lv: Int, _ pg: Int, _ n: Int) {
        guard running, cur?.id == it.id else { return }
        if lv < 0 {                                                        // 壓好了、正在核對畫面（Engine 的 VisualGuard）
            emit(["type": "progress", "i": batchIndex, "total": batchTotal, "id": it.id, "name": it.info.url.lastPathComponent,
                  "bytes": it.info.bytes, "level": -1, "levels": 1, "label": "", "page": n, "pages": n, "frac": 1.0, "eta": -1, "left": queue.count])
            return
        }
        if lv != curLevel { curLevel = lv; passStart = Date() }
        let now = Date()
        // 每頁最多一次；很快的檔一秒幾十頁，節流到每 0.1 秒
        if pg > 0, pg < n, now.timeIntervalSince(lastEmit) < 0.1 { return }
        lastEmit = now
        let frac = n > 0 ? Double(pg) / Double(n) : 0
        let el = now.timeIntervalSince(passStart)
        let eta = (pg > 0 && el > 2) ? Double(n - pg) / (Double(pg) / el) : -1
        let levels = Prefs.targetBytes == nil ? 1 : Ladder.levels.count
        emit(["type": "progress", "i": batchIndex, "total": batchTotal, "id": it.id, "name": it.info.url.lastPathComponent,
              "bytes": it.info.bytes, "level": lv, "levels": levels, "label": levelLabel(it.info, lv), "kind": it.info.kind.rawValue,
              "page": pg, "pages": n, "frac": frac, "eta": eta, "left": queue.count])
        // Dock：整批的進度（完成的份數＋這份的這一輪）
        let overall = (Double(batchIndex - 1) + frac) / Double(max(1, batchTotal))
        DockTile.set(overall, left: queue.count + 1)
    }

    private func finished(_ it: Item, _ o: Outcome) {
        comp = nil
        switch o {
        case .saved(let s):
            let r: [String: Any] = ["status": "saved", "before": it.info.bytes, "after": s.bytes, "level": s.level,
                                    "label": levelLabel(it.info, s.level), "reached": s.reached, "smallest": s.smallest, "kind": it.info.kind.rawValue,
                                    "out": s.out.path, "outName": s.out.lastPathComponent, "backup": s.backup?.path ?? "",
                                    "note": s.note ?? "", "limit": Prefs.targetBytes ?? 0]
            record(it, r)
            Prefs.remember(["name": it.info.url.lastPathComponent, "out": s.out.path, "before": it.info.bytes, "after": s.bytes,
                            "at": Date().timeIntervalSince1970])
        case .noGain(let best):
            record(it, ["status": "nogain", "before": it.info.bytes, "after": best])
        case .failed(let code, let detail):
            if code == "cancelled" { stoppedItem = it }
            else { record(it, ["status": "failed", "code": code, "detail": detail]) }
        }
        cur = nil
        if stopping { finalizeStop(); return }
        next()
    }

    private func record(_ it: Item, _ r: [String: Any]) {
        var d = r
        d["id"] = it.id
        d["name"] = it.info.url.lastPathComponent
        d["path"] = it.info.url.path
        d["pages"] = it.info.pages
        d["kind"] = it.info.kind.rawValue; d["w"] = it.info.width; d["h"] = it.info.height; d["fmt"] = it.info.format
        if d["before"] == nil { d["before"] = it.info.bytes }
        results.append(d)
        emit(["type": "item", "item": d, "i": batchIndex, "total": batchTotal])
    }

    private func stop() {
        guard running else { return }
        stopping = true
        if let c = comp { c.cancel() } else { finalizeStop() }
    }

    /// 停下來：沒壓完的（當下那份＋排隊的）回到清單，再按一次主鍵就接著壓
    private func finalizeStop() {
        staged = (stoppedItem.map { [$0] } ?? []) + queue + staged
        queue = []
        stoppedItem = nil
        finish(stopped: true)
    }

    private func finish(stopped: Bool) {
        running = false
        stopping = false
        cur = nil
        comp = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        DockTile.set(nil, left: 0)
        lastResults = results
        let saved = results.filter { $0["status"] as? String == "saved" }
        let before = saved.reduce(Int64(0)) { $0 + (($1["before"] as? Int64) ?? 0) }
        let after = saved.reduce(Int64(0)) { $0 + (($1["after"] as? Int64) ?? 0) }
        emit(["type": "done", "items": results, "stopped": stopped, "remaining": staged.map(\.dict),
              "before": before, "after": after])
        refreshEstimate()
        if !stopped { notifyDone(saved: saved, before: before, after: after) }
    }

    // MARK: 拆開寄：壓到最小還是超過目標的那幾份，依頁拆成每份都在目標以下

    private var splitting = false
    private func split(_ ids: [String]) {
        guard !running, !splitting else { return }
        let todo = lastResults.filter { ids.contains($0["id"] as? String ?? "") && $0["status"] as? String == "saved" }
        guard !todo.isEmpty else { return }
        splitting = true
        let first = URL(fileURLWithPath: (todo[0]["out"] as? String) ?? "")
        emit(["type": "splitting", "name": todo.count > 1 ? L("\(todo.count) 份", "\(todo.count) files") : first.lastPathComponent, "i": 0, "n": 0])
        DispatchQueue.global(qos: .userInitiated).async {
            var allParts: [[String: Any]] = []
            var ev: [String: Any] = ["type": "split", "ok": true, "source": first.path, "name": first.lastPathComponent]
            for r in todo {
                let src = URL(fileURLWithPath: (r["out"] as? String) ?? "")
                let limit = (r["limit"] as? Int64).flatMap { $0 > 0 ? $0 : nil } ?? Prefs.targetBytes ?? 25 * 1024 * 1024
                ev["limit"] = limit
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("Slimly-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let res = Splitter.split(src, limit: limit, work: work) { i, n in
                    self.emit(["type": "splitting", "name": src.lastPathComponent, "i": i, "n": n])
                }
                switch res {
                case .success(let parts):
                    do {
                        let placed = try Splitter.place(parts, dir: src.deletingLastPathComponent(), compressedName: src.lastPathComponent)
                        allParts += placed.map { ["path": $0.url.path, "name": $0.url.lastPathComponent, "bytes": $0.bytes,
                                                  "first": $0.first, "last": $0.last, "over": $0.over] as [String: Any] }
                    } catch { ev["ok"] = false; ev["reason"] = "place"; ev["source"] = src.path }
                case .failure(let e):
                    ev["ok"] = false; ev["source"] = src.path
                    switch e { case .unreadable: ev["reason"] = "unreadable"; case .write: ev["reason"] = "write"; case .verify(let p): ev["reason"] = "verify|\(p)" }
                }
                if ev["ok"] as? Bool == false { break }
            }
            ev["parts"] = allParts
            DispatchQueue.main.async { self.splitting = false; self.emit(ev) }
        }
    }

    private func updateDock() {
        guard running else { return }
        DockTile.set((Double(batchIndex - 1)) / Double(max(1, batchTotal)), left: queue.count + (cur == nil ? 0 : 1))
    }

    // MARK: 通知（視窗不在前面時才發）

    private func notifyDone(saved: [[String: Any]], before: Int64, after: Int64) {
        guard !isTest, !(NSApp.isActive && window?.isVisible == true), !results.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            let failed = self.results.count - saved.count
            if saved.count == 1, self.results.count == 1, let n = saved.first?["outName"] as? String {
                c.title = L("壓好了", "Done")
                c.body = "\(n)：\(humanSize(before)) → \(humanSize(after))"
            } else if saved.isEmpty {
                c.title = L("這次沒有壓出新檔", "Nothing new was saved")
                c.body = L("打開 Slimly 看原因", "Open Slimly to see why")
            } else {
                c.title = L("\(saved.count) 份壓好了", "\(saved.count) done")
                c.body = L("省下 \(humanSize(before - after))", "Saved \(humanSize(before - after))") + (failed > 0 ? L("・\(failed) 份沒壓", " · \(failed) skipped") : "")
            }
            c.userInfo = ["files": saved.compactMap { $0["out"] as? String }]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
    /// 點通知＝在 Finder 選好壓好的檔
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let files = (response.notification.request.content.userInfo["files"] as? [String]) ?? []
        DispatchQueue.main.async {
            let urls = files.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) } else { self.showWindow() }
            done()
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // MARK: 所有工具（2.0）：收檔、跑、縮圖、表單欄位、簽名、接力相機

    /// 這個工具收哪些副檔名（空＝PDF）
    private func exts(_ tool: String) -> [String] {
        guard let s = Tools.spec(tool) else { return ["pdf"] }
        return s.accepts.isEmpty ? ["pdf"] : s.accepts
    }

    /// 放進工具的檔：資料夾展開（照檔名排）、不收的類型略過；PDF 讀頁數、看有沒有密碼
    private func toolFiles(_ urls: [URL], tool: String, extra: [String: Any] = [:]) {
        let want = Set(exts(tool))
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var files: [URL] = [], skipped: [[String: String]] = []
            for u in urls {
                var dir: ObjCBool = false
                let isPkg = NSWorkspace.shared.isFilePackage(atPath: u.path)          // Keynote／Pages 的舊格式是資料夾，當檔案收
                if fm.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue, !isPkg {
                    let inside = ((fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])?.allObjects as? [URL]) ?? [])
                        .filter { want.contains($0.pathExtension.lowercased()) }
                        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                    if inside.isEmpty { skipped.append(["name": u.lastPathComponent, "code": "folderEmpty"]) }
                    files += inside
                } else if want.contains(u.pathExtension.lowercased()) { files.append(u) }
                else { skipped.append(["name": u.lastPathComponent, "code": "type"]) }
            }
            let items: [[String: Any]] = files.map { f in
                var d: [String: Any] = ["path": f.path, "name": f.lastPathComponent, "bytes": PDFs.fileSize(f), "ext": f.pathExtension.lowercased()]
                if f.pathExtension.lowercased() == "pdf" {
                    if let doc = PDFDocument(url: f) { d["pages"] = doc.pageCount; d["locked"] = doc.isLocked; d["encrypted"] = doc.isEncrypted }
                    else { d["damaged"] = true }
                }
                return d
            }
            var ev: [String: Any] = ["type": "toolFiles", "tool": tool, "items": items, "skipped": skipped]
            for (k, v) in extra { ev[k] = v }
            self.emit(ev)
        }
    }

    private func toolPick(_ tool: String) {
        let p = NSOpenPanel()
        let one = (Tools.spec(tool)?.max ?? 1) <= 1
        p.allowsMultipleSelection = !one
        p.canChooseDirectories = !one
        p.canChooseFiles = true
        p.allowedContentTypes = exts(tool).compactMap { UTType(filenameExtension: $0) } + (one ? [] : [.folder])
        p.prompt = L("選好了", "Choose")
        guard p.runModal() == .OK else { return }
        toolFiles(p.urls, tool: tool)
    }

    private func runTool(_ tool: String, files: [String], options: [String: Any]) {
        guard toolCancel == nil else { return }
        let cancel = ToolCancel()
        toolCancel = cancel
        toolActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Slimly tool")
        let urls = files.map { URL(fileURLWithPath: $0) }
        let started = Date()
        let before = urls.reduce(Int64(0)) { $0 + PDFs.fileSize($1) }
        emit(["type": "toolStart", "tool": tool])
        DispatchQueue.global(qos: .userInitiated).async {
            var last = Date.distantPast
            let res = Tools.run(tool, inputs: urls, options: options, dest: nil, progress: { text, frac in
                let now = Date()
                guard now.timeIntervalSince(last) > 0.08 else { return }
                last = now
                self.emit(["type": "toolProgress", "tool": tool, "text": text, "frac": frac])
            }, cancel: cancel)
            DispatchQueue.main.async {
                self.toolCancel = nil
                if let a = self.toolActivity { ProcessInfo.processInfo.endActivity(a); self.toolActivity = nil }
                let secs = Date().timeIntervalSince(started)
                switch res {
                case .success(let r):
                    let fm = FileManager.default
                    let outs: [[String: Any]] = r.outputs.map { u in
                        var dir: ObjCBool = false
                        _ = fm.fileExists(atPath: u.path, isDirectory: &dir)
                        let bytes = dir.boolValue ? ((fm.enumerator(at: u, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []).reduce(Int64(0)) { $0 + PDFs.fileSize($1) } : PDFs.fileSize(u)
                        return ["path": u.path, "name": u.lastPathComponent, "bytes": bytes, "dir": dir.boolValue]
                    }
                    self.emit(["type": "toolDone", "tool": tool, "ok": true, "outputs": outs, "notes": r.notes, "text": r.text ?? "", "seconds": secs, "before": before])
                    for o in outs {
                        Prefs.remember(["name": (o["name"] as? String) ?? "", "out": (o["path"] as? String) ?? "", "before": before, "after": (o["bytes"] as? Int64) ?? 0,
                                        "at": Date().timeIntervalSince1970, "tool": tool])
                    }
                    self.notifyTool(tool, ok: true, outputs: outs.compactMap { $0["path"] as? String }, secs: secs)
                case .failure(let e):
                    self.emit(["type": "toolDone", "tool": tool, "ok": false, "error": e.text, "stopped": cancel.isCancelled, "seconds": secs])
                    if !cancel.isCancelled { self.notifyTool(tool, ok: false, outputs: [], secs: secs) }
                }
            }
        }
    }

    /// 跑超過 10 秒、視窗又不在前面：發通知（點了在 Finder 選好做出來的檔）
    private func notifyTool(_ tool: String, ok: Bool, outputs: [String], secs: Double) {
        guard !isTest, secs > 10, !(NSApp.isActive && window?.isVisible == true) else { return }
        let name = Tools.spec(tool)?.name ?? tool
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = ok ? L("好了：\(name)", "Done: \(name)") : L("沒做成：\(name)", "Didn’t finish: \(name)")
            c.body = ok ? outputs.map { URL(fileURLWithPath: $0).lastPathComponent }.prefix(3).joined(separator: "、") : L("打開 Slimly 看原因", "Open Slimly to see why")
            c.userInfo = ["files": outputs]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    /// 頁面縮圖（整理、移除、提取用）：一次送 12 頁，畫面邊收邊排
    private func thumbs(_ path: String, width: CGFloat) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let d = PDFDocument(url: URL(fileURLWithPath: path)), !d.isLocked else {
                self.emit(["type": "thumbs", "path": path, "start": 0, "total": 0, "pages": []]); return
            }
            let n = d.pageCount
            var batch: [String] = [], start = 0
            for i in 0..<n {
                var s = ""
                if let p = d.page(at: i) {
                    let img = p.thumbnail(of: NSSize(width: width * 2, height: width * 2 * 1.42), for: .cropBox)
                    if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
                       let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) {
                        s = "data:image/jpeg;base64," + jpg.base64EncodedString()
                    }
                }
                batch.append(s)
                if batch.count == 12 || i == n - 1 {
                    self.emit(["type": "thumbs", "path": path, "start": start, "total": n, "pages": batch])
                    start = i + 1; batch = []
                }
            }
        }
    }

    /// 表單欄位（填表單用）：名字、種類、現在的值、選項
    private func formFields(_ path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Tools.run("forms", inputs: [URL(fileURLWithPath: path)], options: ["list": true], dest: nil)
            switch r {
            case .success(let res):
                let fields = (try? JSONSerialization.jsonObject(with: Data((res.text ?? "[]").utf8))) ?? []
                self.emit(["type": "formFields", "path": path, "fields": fields])
            case .failure(let e):
                self.emit(["type": "formFields", "path": path, "fields": [], "error": e.text])
            }
        }
    }

    /// 簽名圖存在「應用程式支援」裡，下次直接用（只存在這台 Mac）
    private var signatureURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Slimly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(isTest ? "signature-test.png" : "signature.png")
    }
    private func dataURL(_ u: URL, maxSide: CGFloat = 0) -> String {
        guard let data = try? Data(contentsOf: u) else { return "" }
        if maxSide > 0, let img = NSImage(data: data), max(img.size.width, img.size.height) > maxSide,
           let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
            let k = maxSide / max(img.size.width, img.size.height)
            let small = NSImage(size: NSSize(width: img.size.width * k, height: img.size.height * k))
            small.lockFocus(); rep.draw(in: NSRect(origin: .zero, size: small.size)); small.unlockFocus()
            if let t2 = small.tiffRepresentation, let r2 = NSBitmapImageRep(data: t2), let png = r2.representation(using: .png, properties: [:]) {
                return "data:image/png;base64," + png.base64EncodedString()
            }
        }
        let type = u.pathExtension.lowercased() == "png" ? "png" : "jpeg"
        return "data:image/\(type);base64," + data.base64EncodedString()
    }
    private func emitSignature() {
        let u = signatureURL
        guard FileManager.default.fileExists(atPath: u.path) else { emit(["type": "signature", "path": "", "data": ""]); return }
        emit(["type": "signature", "path": u.path, "data": dataURL(u)])
    }

    /// 接力相機拍好的：打開「轉檔」、當成拍文件的照片放進去（找邊拉正；檔名用日期）
    private func cameraImport(_ urls: [URL]) {
        showWindowUnlessTest()
        emit(["type": "openTool", "id": "convert"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.toolFiles(urls, tool: "convert", extra: ["camera": true]) }
    }

    // MARK: Swift → JS

    private func emit(_ payload: [String: Any]) {
        guard uiReady || payload["type"] as? String == "ready",
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.web.evaluateJavaScript("window.appEvent(\(json))") }
    }

    private func pushPrefs() {
        let home = NSHomeDirectory()
        var shown = Prefs.folder.hasPrefix(home) ? "~" + String(Prefs.folder.dropFirst(home.count)) : Prefs.folder
        if shown.hasPrefix("~/Downloads") { shown = L("下載項目", "Downloads") + shown.dropFirst("~/Downloads".count) }
        let gsVer = (try? String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("engine-version.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        emit(["type": "prefs", "target": Prefs.targetMB, "place": Prefs.place, "folder": shown, "original": Prefs.original,
              "theme": Prefs.theme, "lang": Lang.setting, "version": Engine.appVersion, "stripGPS": Prefs.stripGPS,
              "build": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "",
              "engine": gsVer, "wizardDone": Prefs.wizardDone, "forceWizard": forceWizard,
              "wizardPage": wizardPage])
    }
    private var wizardPage: Int {
        guard let i = args.firstIndex(of: "--wizard-page"), args.count > i + 1 else { return 0 }
        return Int(args[i + 1]) ?? 0
    }

    // MARK: JS → Swift

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready":
            uiReady = true
            pushPrefs()
            emit(["type": "theme", "mode": Prefs.theme])
            emit(["type": "staged", "items": staged.map(\.dict), "added": 0, "skipped": []])
            if let d = estimateDone, staged.count == 1, staged[0].id == estimateID { emit(d) }
            emit(WatchFolders.shared.dict)
            let p = pendingOpen; pendingOpen = []
            for x in p { add(x.urls, autostart: x.auto) }
            if let i = args.firstIndex(of: "--demo"), args.count > i + 1 { demo(args[i + 1]) }
            else if let i = args.firstIndex(of: "--script"), args.count > i + 1 { runScript(args[i + 1]) }
            else if args.contains("--snapshot") { snapAndExit() }
        case "pick": pickFiles()
        case "start": start()
        case "stop": stop()
        case "clear":
            guard !running else { return }
            staged = []
            emit(["type": "staged", "items": [], "added": 0, "skipped": []])
            refreshEstimate()
        case "remove":
            guard !running, let id = body["id"] as? String else { return }
            staged.removeAll { $0.id == id }
            emit(["type": "staged", "items": staged.map(\.dict), "added": 0, "skipped": []])
            refreshEstimate()
        case "signed":
            let yes = body["yes"] as? Bool ?? false
            let infos = pendingSigned; pendingSigned = []
            let auto = autoAfterSigned; autoAfterSigned = false
            // 使用者看過「簽章會失效」還是要壓：已經明講兩次了，直接開始（不管原本是不是從 Dock 進來的）
            _ = auto
            if yes { accept(infos.map { Item($0) }, skipped: [], signed: [], autostart: true) }
            else { emit(["type": "staged", "items": staged.map(\.dict), "added": 0, "skipped": infos.map { ["name": $0.url.lastPathComponent, "code": Self.askKind($0), "path": $0.url.path] }]) }
        case "retry":
            // 重試上一批失敗的；toDownloads＝改存到「下載項目 › Slimly」（沒權限時的出口）；pickFolder＝自己選
            guard !running else { return }
            let ids = Set((body["ids"] as? [String]) ?? lastResults.filter { $0["status"] as? String == "failed" }.compactMap { $0["id"] as? String })
            var dest: URL? = nil
            if body["toDownloads"] as? Bool == true { dest = URL(fileURLWithPath: Prefs.defaultFolder, isDirectory: true) }
            if body["pickFolder"] as? Bool == true {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                p.prompt = L("存到這裡", "Save Here")
                guard p.runModal() == .OK, let u = p.url else { return }
                dest = u
            }
            let again = lastResults.filter { ids.contains($0["id"] as? String ?? "") }.compactMap { r -> Item? in
                guard let path = r["path"] as? String, case .success(let info) = Inspect.check(URL(fileURLWithPath: path)) else { return nil }
                return Item(info, dest: dest)
            }
            staged = again + staged
            start()
        case "reveal":
            if let p = body["path"] as? String, FileManager.default.fileExists(atPath: p) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
            }
        case "revealFiles":
            let urls = ((body["files"] as? [String]) ?? []).filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        case "share":
            // macOS 的分享選單（Mail、訊息、AirDrop、備忘錄、裝了的 LINE…），從按下去的那顆鍵彈出來
            let files = ((body["files"] as? [String]) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
            guard !files.isEmpty else { return }
            if isTest { print("SHARE \(files.count) \(files.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "|"))"); return }
            var r = NSRect(x: 0, y: 0, width: 1, height: 1)
            if let d = body["rect"] as? [String: Any], let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
               let w = (d["w"] as? NSNumber)?.doubleValue, let h = (d["h"] as? NSNumber)?.doubleValue {
                r = NSRect(x: x, y: web.isFlipped ? y : web.bounds.height - y - h, width: max(1, w), height: max(1, h))
            }
            NSSharingServicePicker(items: files.map { URL(fileURLWithPath: $0) }).show(relativeTo: r, of: web, preferredEdge: .minY)
        case "split":
            split((body["ids"] as? [String]) ?? [])
        case "revealAll":
            let urls = lastResults.compactMap { $0["out"] as? String }.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        case "open":
            if let p = body["path"] as? String, FileManager.default.fileExists(atPath: p) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        case "openWith":
            // 有密碼的 PDF：直接用「預覽程式」打開，讓使用者輸入密碼後另存一份沒有密碼的（Slimly 不碰密碼）
            if let p = body["path"] as? String, FileManager.default.fileExists(atPath: p) {
                let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
                NSWorkspace.shared.open([URL(fileURLWithPath: p)], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
            }
        case "dragArm":
            web.armedFiles = (body["files"] as? [String]) ?? []
        case "setTarget":
            if let v = body["mb"] as? Int { Prefs.targetMB = v } else if let v = body["mb"] as? Double { Prefs.targetMB = Int(v) }
            pushPrefs()
        case "setPlace":
            if let v = body["place"] as? String { Prefs.place = v }
            pushPrefs()
        case "pickFolder":
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = L("存到這裡", "Save Here")
            p.directoryURL = URL(fileURLWithPath: Prefs.folder)
            if p.runModal() == .OK, let u = p.url { Prefs.folder = u.path; Prefs.place = "folder" }
            pushPrefs()
        case "setStripGPS":
            if let v = body["on"] as? Bool { Prefs.stripGPS = v }
            pushPrefs()
        case "setOriginal":
            if let v = body["mode"] as? String { Prefs.original = v }
            pushPrefs()
        case "setTheme":
            if let v = body["mode"] as? String { Prefs.theme = v; applyTheme() }
        case "setLang":
            if let v = body["lang"] as? String { Lang.setting = v; installMenu(); pushPrefs() }
        case "wizardDone":
            Prefs.wizardDone = true
            pushPrefs()
            if !staged.isEmpty, body["start"] as? Bool == true { start() }
        case "history":
            emit(["type": "history", "items": Prefs.history.map { h -> [String: Any] in
                var d = h; d["exists"] = FileManager.default.fileExists(atPath: (h["out"] as? String) ?? ""); return d }])
        case "clearHistory":
            Prefs.history = []
            emit(["type": "history", "items": []])
        case "notices":
            if let u = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt") { NSWorkspace.shared.open(u) }
        case "openDoc":
            // 使用規範、隱私與權限、授權：用預設瀏覽器打開公開倉上的那一份（只開這三個固定網址；你按了才開）
            let docs = ["terms": "TERMS.md", "privacy": "PRIVACY.md", "license": "LICENSE"]
            if let f = docs[(body["doc"] as? String) ?? ""], let u = URL(string: "https://github.com/intentionltd888/slimly/blob/main/" + f) { NSWorkspace.shared.open(u) }

        // ── 所有工具 ──
        case "toolTarget":
            let t = (body["tool"] as? String) ?? ""
            toolTarget = t.isEmpty ? nil : t
        case "toolPick":
            if let t = body["tool"] as? String { toolPick(t) }
        case "toolRun":
            guard let t = body["tool"] as? String else { return }
            runTool(t, files: (body["files"] as? [String]) ?? [], options: (body["options"] as? [String: Any]) ?? [:])
        case "toolStop":
            toolCancel?.cancel()
        case "thumbs":
            if let p = body["path"] as? String { thumbs(p, width: CGFloat((body["w"] as? NSNumber)?.doubleValue ?? 100)) }
        case "compare":
            // 前後對照：照這次的結果找壓前（原檔；原檔收進備份夾的話用那份）與壓後
            guard let id = body["id"] as? String, let r = lastResults.last(where: { ($0["id"] as? String) == id }),
                  let out = r["out"] as? String else { emit(["type": "compareReady", "ok": false]); return }
            let b = (r["backup"] as? String) ?? "", before = b.isEmpty ? ((r["path"] as? String) ?? "") : b
            DispatchQueue.global(qos: .userInitiated).async {
                let o = CompareImages.shared.open(a: URL(fileURLWithPath: before), b: URL(fileURLWithPath: out))
                DispatchQueue.main.async {
                    guard let o else { self.emit(["type": "compareReady", "ok": false, "id": id]); return }
                    self.emit(["type": "compareReady", "ok": true, "id": id, "token": o.token, "pages": o.pages, "aspect": o.aspect])
                }
            }
        case "compareClose":
            CompareImages.shared.close()
        case "watchAdd":
            // 監看資料夾：選一個或幾個資料夾
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
            p.message = L("選要監看的資料夾：丟進來的 PDF、照片會自動壓，放進裡面的「Slimly 已壓縮」", "Choose folders to watch: PDFs and photos dropped in are compressed into “Slimly Compressed” inside")
            p.prompt = L("監看這裡", "Watch")
            if p.runModal() == .OK { for u in p.urls { WatchFolders.shared.add(u.path) } }
        case "watchRemove":
            if let path = body["path"] as? String { WatchFolders.shared.remove(path) }
        case "watchTarget":
            if let path = body["path"] as? String, let mb = (body["mb"] as? NSNumber)?.intValue { WatchFolders.shared.setTarget(path, mb) }
        case "watchPause":
            WatchFolders.shared.setPaused((body["on"] as? Bool) ?? false)
        case "watchReveal":
            if let path = body["path"] as? String {
                let out = URL(fileURLWithPath: path).appendingPathComponent(WatchFolders.outName)
                NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: out.path) ? out : URL(fileURLWithPath: path)])
            }
        case "formFields":
            if let p = body["path"] as? String { formFields(p) }
        case "signature":
            emitSignature()
        case "saveSignature":
            // 畫好的簽名（透明底 PNG，data URL）存起來；下次直接用
            if let s = body["data"] as? String, let comma = s.firstIndex(of: ","),
               let data = Data(base64Encoded: String(s[s.index(after: comma)...])) {
                try? data.write(to: signatureURL, options: .atomic)
            }
            emitSignature()
        case "useSignatureFile":
            // 選一張現成的簽名圖（透明底 PNG 最好）：照抄一份成「我的簽名」
            let p = NSOpenPanel(); p.allowedContentTypes = [.png, .jpeg, .heic, .tiff]; p.prompt = L("用這張", "Use")
            if p.runModal() == .OK, let u = p.url, let data = try? Data(contentsOf: u) {
                if let img = NSImage(data: data), let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: signatureURL, options: .atomic)
                }
            }
            emitSignature()
        case "pickImage":
            let key = (body["key"] as? String) ?? "image"
            let p = NSOpenPanel(); p.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]; p.prompt = L("用這張", "Use")
            if p.runModal() == .OK, let u = p.url {
                emit(["type": "image", "key": key, "path": u.path, "name": u.lastPathComponent, "data": dataURL(u, maxSide: 240)])
            }
        case "scanDevice":
            // 從按鈕彈出「從 iPhone 輸入」：macOS 自己列出附近的 iPhone／iPad 與「拍照／掃描文件」
            let menu = NSMenu()
            let item = NSMenuItem(title: L("從 iPhone 或 iPad 輸入", "Import from iPhone or iPad"), action: nil, keyEquivalent: "")
            item.identifier = NSMenuItem.importFromDeviceIdentifier
            menu.addItem(item)
            var pt = NSPoint(x: 28, y: 200)
            if let d = body["rect"] as? [String: Any], let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
               let h = (d["h"] as? NSNumber)?.doubleValue {
                pt = NSPoint(x: x, y: web.isFlipped ? y + h + 4 : web.bounds.height - y - h - 4)
            }
            if isTest { print("SCANMENU \(menu.items.map { $0.title })"); return }
            menu.popUp(positioning: nil, at: pt, in: web)
        case "copyText":
            if let t = body["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
        case "openEditor":
            // 主畫面「用編輯器打開」：放進來的那幾份；或自己選
            if let ps = body["paths"] as? [String], !ps.isEmpty { openEditor(ps.map { URL(fileURLWithPath: $0) }) }
            else { pickForEditor() }
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 介面裡的外部連結交給瀏覽器；WebView 自己只顯示 ui.html
        if let u = a.request.url, u.scheme == "https" || u.scheme == "http" {
            NSWorkspace.shared.open(u); decisionHandler(.cancel); return
        }
        decisionHandler(a.navigationType == .other ? .allow : .cancel)
    }

    // MARK: 驗收鉤（全部走真的程式路徑；只有 --demo 是餵假事件擺畫面）

    /// --snapshot <png>（不帶 --script／--demo）：拍待命畫面（沒跑過精靈的測試環境會蓋精靈，除非 --no-wizard）
    private func snapAndExit() {
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 else { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.snapshot(self.args[i + 1]) { exit(0) } }
    }

    private func snapshot(_ path: String, _ then: @escaping () -> Void) {
        web.evaluateJavaScript("document.body.classList.add('freeze')") { _, _ in
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(origin: .zero, size: Const.winSize)
            self.web.takeSnapshot(with: cfg) { img, _ in
                if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("SNAP \(path)")
                }
                self.web.evaluateJavaScript("document.body.classList.remove('freeze')") { _, _ in then() }
            }
        }
    }

    private func probe(_ then: @escaping (String) -> Void) {
        let js = """
        (() => { const t = id => ((document.getElementById(id) || {}).innerText || '').replace(/\\s+/g, ' ').trim();
          return JSON.stringify({ state: document.body.dataset.state, view: document.body.dataset.v, orb: document.body.dataset.o,
            big: t('state'), sub: t('sub'), note: t('note'), card: t('cardTitle'), cardSub: t('cardSub'), toast: t('toast'),
            list: t('list'), acts: t('acts'), wiz: !document.getElementById('wiz').classList.contains('hide'),
            tool: document.body.dataset.tool || '', toolId: (window.__tool || {}).id || '', tState: t('tState'), tSub: t('tSub'),
            tFiles: t('tFiles'), tOut: t('tOut'), tText: t('tText'), tHint: t('tHint'), segs: t('targetSeg'),
            est: window.__est ? window.__est() : null, cmp: window.__cmp ? window.__cmp() : null, watch: window.__watch ? window.__watch() : null }); })()
        """
        web.evaluateJavaScript(js) { r, e in then((r as? String) ?? "ERR \(e?.localizedDescription ?? "")") }
    }

    /// --script <json>：照步驟跑真的流程（加檔、按鍵、等狀態、拍照、印畫面文字）。設定寫在測試專用的 UserDefaults。
    ///   {"add":[路徑…],"auto":false} {"open":[路徑…]}（＝拖到 Dock／打開檔案） {"service":[路徑…]}（＝右鍵服務）
    ///   {"click":"元素 id"} {"js":"…"} {"wait":秒} {"waitFor":"run|done|idle|err","timeout":秒}
    ///   {"pref":{"target":10,"place":"folder","folder":"…","original":"backup","wizardDone":true}}
    ///   {"snap":"out.png"} {"probe":true} {"exit":true}
    private func runScript(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("SCRIPT 讀不到 \(path)"); exit(2)
        }
        var i = 0
        func after(_ t: Double) { DispatchQueue.main.asyncAfter(deadline: .now() + t) { step() } }
        func done() { editors.forEach { $0.doc.cleanup() }; stopEstimate(wait: true); stopWatch(wait: true); CompareImages.shared.close(); print("SCRIPT 完成"); exit(0) }
        func step() {
            guard i < steps.count else { done(); return }
            let s = steps[i]; i += 1
            if let note = s["say"] as? String { print("── \(note)") }
            if let p = s["add"] as? [String] {
                add(p.map { URL(fileURLWithPath: $0) }, autostart: s["auto"] as? Bool ?? false); after(s["then"] as? Double ?? 1.0)
            } else if let p = s["open"] as? [String] {
                application(NSApp, open: p.map { URL(fileURLWithPath: $0) }); after(1.0)
            } else if let p = s["service"] as? [String] {
                let pb = NSPasteboard(name: NSPasteboard.Name("slimly.selftest"))
                pb.clearContents(); pb.writeObjects(p.map { URL(fileURLWithPath: $0) as NSURL })
                var err: NSString? = nil
                compressService(pb, userData: nil, error: &err)
                if let err { print("SERVICE ERR \(err)") }
                after(1.0)
            } else if let id = s["click"] as? String {
                web.evaluateJavaScript("(() => { const e = document.getElementById('\(id)'); if (!e) return 'no ' + '\(id)'; e.click(); return 'clicked'; })()") { r, _ in
                    print("CLICK \(id) \(r ?? "")"); after(s["then"] as? Double ?? 0.4)
                }
            } else if let js = s["js"] as? String {
                web.evaluateJavaScript(js) { r, e in print("JS \(r ?? e?.localizedDescription ?? "")"); after(0.3) }
            } else if let p = s["edit"] as? [String] {
                openEditor(p.map { URL(fileURLWithPath: $0) }); after(s["then"] as? Double ?? 1.5)
            } else if let js = s["ejs"] as? String {
                guard let e = editors.last else { print("EJS 沒有編輯器"); after(0); return }
                e.web.evaluateJavaScript(js) { r, err in print("EJS \(r ?? err?.localizedDescription ?? "")"); after(s["then"] as? Double ?? 0.3) }
            } else if let want = s["ewait"] as? String {
                guard let e = editors.last else { print("EWAIT 沒有編輯器"); after(0); return }
                let limit = Date().addingTimeInterval(s["timeout"] as? Double ?? 60)
                func poll() {
                    e.web.evaluateJavaScript("document.body.dataset.ed || ''") { r, _ in
                        if (r as? String) == want { after(0.3) }
                        else if Date() > limit { print("WAIT 逾時：編輯器要 \(want)，現在 \(r ?? "?")"); after(0) }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() } }
                    }
                }
                poll()
            } else if s["eprobe"] != nil {
                guard let e = editors.last else { print("EPROBE 沒有編輯器"); after(0); return }
                e.web.evaluateJavaScript("window.__edProbe ? JSON.stringify(window.__edProbe()) : '{}'") { r, _ in print("EPROBE \(r ?? "")"); after(0.1) }
            } else if let p = s["esnap"] as? String {
                guard let e = editors.last else { print("ESNAP 沒有編輯器"); after(0); return }
                e.web.evaluateJavaScript("document.body.classList.add('freeze')") { _, _ in
                    let cfg = WKSnapshotConfiguration(); cfg.rect = e.web.bounds
                    e.web.takeSnapshot(with: cfg) { img, _ in
                        if let img, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: p)); print("SNAP \(p)")
                        }
                        e.web.evaluateJavaScript("document.body.classList.remove('freeze')") { _, _ in after(0.1) }
                    }
                }
            } else if let p = s["toolFiles"] as? [String] {
                // 等同把檔拖進開著的工具頁（沒開就用 tool 指定）
                toolFiles(p.map { URL(fileURLWithPath: $0) }, tool: (s["tool"] as? String) ?? toolTarget ?? "merge",
                          extra: (s["camera"] as? Bool == true) ? ["camera": true] : [:])
                after(s["then"] as? Double ?? 1.0)
            } else if let want = s["waitTool"] as? String {
                let limit = Date().addingTimeInterval(s["timeout"] as? Double ?? 120)
                func poll() {
                    web.evaluateJavaScript("document.body.dataset.tool || ''") { r, _ in
                        if (r as? String) == want { after(0.3) }
                        else if Date() > limit { print("WAIT 逾時：工具要 \(want)，現在 \(r ?? "?")"); after(0) }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() } }
                    }
                }
                poll()
            } else if let w = s["watch"] as? [String: Any] {
                // 監看資料夾（測試用）：加、拿掉、暫停（選資料夾的視窗測不了）
                if let p = w["add"] as? String { WatchFolders.shared.add(p, target: (w["target"] as? Int) ?? 25) }
                if let p = w["remove"] as? String { WatchFolders.shared.remove(p) }
                if let v = w["pause"] as? Bool { WatchFolders.shared.setPaused(v) }
                after(s["then"] as? Double ?? 0.5)
            } else if let p = s["mkdir"] as? String {
                try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true); after(0.2)
            } else if let c = s["copy"] as? [String], c.count == 2 {
                // 丟一份檔進資料夾（測試用；抄到暫存名再改名＝一次出現，跟 Finder 拖進去一樣）
                let src = URL(fileURLWithPath: c[0]), dst = URL(fileURLWithPath: c[1]).appendingPathComponent(s["as"] as? String ?? src.lastPathComponent)
                let tmp = URL(fileURLWithPath: c[1]).appendingPathComponent(".copy-\(UUID().uuidString)")
                do { try FileManager.default.copyItem(at: src, to: tmp); try FileManager.default.moveItem(at: tmp, to: dst); print("COPY \(dst.lastPathComponent)") } catch { print("COPY 失敗 \(error.localizedDescription)") }
                after(s["then"] as? Double ?? 0.3)
            } else if let c = s["slowcopy"] as? [String], c.count == 2 {
                // 慢慢寫一份檔（測試用：模擬掃描器、下載還在寫）——分 5 段、每段隔 secs/5 秒
                let src = URL(fileURLWithPath: c[0]), dst = URL(fileURLWithPath: c[1]).appendingPathComponent(s["as"] as? String ?? src.lastPathComponent)
                let secs = s["secs"] as? Double ?? 6
                DispatchQueue.global().async {
                    guard let data = try? Data(contentsOf: src) else { return }
                    FileManager.default.createFile(atPath: dst.path, contents: nil)
                    guard let h = try? FileHandle(forWritingTo: dst) else { return }
                    let n = 5, step = (data.count + n - 1) / n
                    for i in 0..<n {
                        h.write(data.subdata(in: (i * step)..<min(data.count, (i + 1) * step)))
                        try? h.synchronize()
                        if i < n - 1 { Thread.sleep(forTimeInterval: secs / Double(n)) }
                    }
                    try? h.close(); print("SLOWCOPY 寫完 \(dst.lastPathComponent)")
                }
                after(s["then"] as? Double ?? 0.3)
            } else if let c = s["chmod"] as? [String], c.count == 2, let mode = Int(c[1], radix: 8) {
                try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: c[0]); after(0.3)   // 測試用：「沒有權限」
            } else if let m = s["move"] as? [String], m.count == 2 {
                do { try FileManager.default.moveItem(atPath: m[0], toPath: m[1]); print("MOVE ok") } catch { print("MOVE 失敗 \(error.localizedDescription)") }
                after(s["then"] as? Double ?? 0.3)
            } else if let js = s["waitJS"] as? String {
                // 等到這段 JS 回 true（例：預估算完、對照的圖畫好）
                let limit = Date().addingTimeInterval(s["timeout"] as? Double ?? 60)
                func poll() {
                    web.evaluateJavaScript(js) { r, _ in
                        if (r as? Bool) == true || (r as? NSNumber)?.boolValue == true { after(0.2) }
                        else if Date() > limit { print("WAIT 逾時：\(js)"); after(0) }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() } }
                    }
                }
                poll()
            } else if let w = s["wait"] as? Double {
                after(w)
            } else if let want = s["waitFor"] as? String {
                let limit = Date().addingTimeInterval(s["timeout"] as? Double ?? 300)
                func poll() {
                    web.evaluateJavaScript("document.body.dataset.state") { r, _ in
                        if (r as? String) == want { after(0.3) }
                        else if Date() > limit { print("WAIT 逾時：要 \(want)，現在 \(r ?? "?")"); after(0) }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() } }
                    }
                }
                poll()
            } else if let pr = s["pref"] as? [String: Any] {
                if let v = pr["target"] as? Int { Prefs.targetMB = v }
                if let v = pr["place"] as? String { Prefs.place = v }
                if let v = pr["folder"] as? String { Prefs.folder = v }
                if let v = pr["original"] as? String { Prefs.original = v }
                if let v = pr["wizardDone"] as? Bool { Prefs.wizardDone = v }
                if let v = pr["stripGPS"] as? Bool { Prefs.stripGPS = v }
                pushPrefs(); after(0.3)
            } else if let p = s["snap"] as? String {
                snapshot(p) { after(0.1) }
            } else if s["probe"] != nil {
                probe { print("PROBE \($0)"); after(0.1) }
            } else if s["exit"] != nil {
                done()
            } else {
                after(0)
            }
        }
        after(0.3)
    }

    /// --demo <狀態>：餵假事件把畫面擺好（設計審查與官網截圖；不碰檔案、不跑引擎）
    private func demo(_ state: String) {
        let one: [String: Any] = ["id": "d1", "name": "品牌提案_2026.pdf", "path": "/tmp/品牌提案_2026.pdf", "bytes": 65_300_000, "pages": 48, "slimmed": false, "form": false]
        switch state {
        case "ready": emit(["type": "staged", "items": [one], "added": 1, "skipped": []])
        case "run":
            emit(["type": "staged", "items": [one], "added": 1, "skipped": []])
            emit(["type": "start", "total": 1, "target": 25])
            emit(["type": "progress", "i": 1, "total": 1, "id": "d1", "name": "品牌提案_2026.pdf", "bytes": 65_300_000, "level": 0, "levels": 6,
                  "label": Ladder.levels[0].label, "page": 31, "pages": 48, "frac": 31.0 / 48, "eta": 14, "left": 0])
        case "done":
            emit(["type": "staged", "items": [one], "added": 1, "skipped": []])
            emit(["type": "start", "total": 1, "target": 25])
            var r = one; r["status"] = "saved"; r["before"] = 65_300_000; r["after"] = 10_300_000; r["level"] = 0; r["label"] = Ladder.levels[0].label
            r["reached"] = true; r["smallest"] = 10_300_000; r["out"] = "/tmp/品牌提案_2026（已壓縮）.pdf"; r["outName"] = "品牌提案_2026（已壓縮）.pdf"; r["backup"] = ""; r["note"] = ""
            emit(["type": "done", "items": [r], "stopped": false, "remaining": [], "before": 65_300_000, "after": 10_300_000])
        default: break
        }
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.snapshot(self.args[i + 1]) { exit(0) } }
        }
    }
}

// ─── 進入點 ──────────────────────────────────────────────────────────

// 命令列（終端機、其他程式）：不開視窗、不上 Dock，壓完就結束（CLI.swift）
if CommandLine.arguments.contains("--cli") { exit(CLI.main(CommandLine.arguments)) }

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
