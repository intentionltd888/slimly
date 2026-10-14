// Compare.swift — 壓完的前後對照（擴充提案 #2）：同一頁，壓前（原檔或收進備份夾的那份）／壓後各畫一張給主視窗
//
// 圖走自訂網址 slimly-cmp://img?side=a|b&page=0&w=1600&t=<代號>（不轉 base64，大圖也不卡）；畫成 PNG，對照時不會多一層 JPEG 的失真。
// 換一組或關掉＝代號作廢，晚到的圖不給。放大時網頁照放大倍數重新要一張更大的。照片也行：一張＝一頁，照 EXIF 方向轉正。
import AppKit
import PDFKit
import WebKit
import ImageIO

final class CompareImages: NSObject, WKURLSchemeHandler {
    static let shared = CompareImages()
    static let scheme = "slimly-cmp"

    private let lock = NSLock()
    private enum Src { case pdf(PDFDocument), image(CGImageSource) }
    private var docs: [String: Src] = [:]
    private var token = ""
    private var live = Set<ObjectIdentifier>()
    private let q = DispatchQueue(label: "slimly.compare", qos: .userInitiated)

    /// 換一組（壓前 a、壓後 b）；回傳代號、頁數、第一頁的高寬比
    func open(a: URL, b: URL) -> (token: String, pages: Int, aspect: Double)? {
        guard let sa = Self.load(a), let sb = Self.load(b) else { return nil }
        let t = String(UUID().uuidString.prefix(8))
        lock.lock(); docs = ["a": sa, "b": sb]; token = t; lock.unlock()
        let s = Self.firstSize(sa)
        return (t, min(Self.count(sa), Self.count(sb)), Double(s.height / max(1, s.width)))
    }
    private static func load(_ u: URL) -> Src? {
        if u.pathExtension.lowercased() == "pdf" {
            guard let d = PDFDocument(url: u), !d.isLocked, PDFs.usable(d), d.pageCount > 0 else { return nil }
            return .pdf(d)
        }
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), CGImageSourceGetCount(s) > 0 else { return nil }
        return .image(s)
    }
    private static var fulls: [ObjectIdentifier: CGImage] = [:]
    private static let fullLock = NSLock()
    private static func fullImage(_ i: CGImageSource, long: Int) -> CGImage? {
        fullLock.lock(); defer { fullLock.unlock() }
        if let f = fulls[ObjectIdentifier(i)] { return f }
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(1, long)]
        let f = CGImageSourceCreateThumbnailAtIndex(i, 0, o as CFDictionary)
        if fulls.count > 4 { fulls = [:] }
        fulls[ObjectIdentifier(i)] = f
        return f
    }
    private static func count(_ s: Src) -> Int { if case .pdf(let d) = s { return d.pageCount }; return 1 }
    /// 照片轉正之後的寬高（EXIF 方向 5–8＝對調）
    private static func imageSize(_ s: CGImageSource) -> CGSize {
        let p = (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]) ?? [:]
        let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1, h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
        return ((p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
    private static func firstSize(_ s: Src) -> CGSize {
        switch s { case .pdf(let d): return d.page(at: 0).map(size) ?? CGSize(width: 1, height: 1.414)
                   case .image(let i): return imageSize(i) }
    }
    private static func render(_ s: Src, page: Int, width: CGFloat) -> Data? {
        switch s {
        case .pdf(let d): return d.page(at: page).flatMap { png($0, width: width) }
        case .image(let i):
            // 整張轉正解一次（同一組只解一次）再自己縮：HEIC 縮小解碼跟整張縮出來對不齊，黃線兩邊會錯開
            let sz = imageSize(i), long = max(sz.width, sz.height), edge = Int(min(long, (long * width / max(1, sz.width)).rounded()))
            guard let full = fullImage(i, long: Int(long)), let img = ImageLadder.scaled(full, edge: edge) else { return nil }
            return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        }
    }
    func close() { lock.lock(); docs = [:]; token = ""; lock.unlock() }

    /// 轉過的頁照轉過的樣子算寬高
    static func size(_ p: PDFPage) -> CGSize {
        let r = p.bounds(for: .cropBox)
        return p.rotation % 180 == 0 ? r.size : CGSize(width: r.height, height: r.width)
    }
    static func png(_ p: PDFPage, width: CGFloat) -> Data? {
        let s = size(p), h = (width * s.height / max(1, s.width)).rounded()
        let img = p.thumbnail(of: NSSize(width: width, height: h), for: .cropBox)
        guard let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func webView(_ w: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task), url = task.request.url
        lock.lock(); live.insert(id); lock.unlock()
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        func v(_ k: String) -> String? { items.first { $0.name == k }?.value }
        q.async {
            self.lock.lock(); let ok = v("t") == self.token && !self.token.isEmpty; let d = self.docs[v("side") ?? ""]; self.lock.unlock()
            var data: Data? = nil
            if ok, let d {
                data = Self.render(d, page: Int(v("page") ?? "0") ?? 0, width: CGFloat(min(4000, max(100, Int(v("w") ?? "1600") ?? 1600))))
            }
            DispatchQueue.main.async {
                self.lock.lock(); let alive = self.live.remove(id) != nil; self.lock.unlock()
                guard alive else { return }                                             // 網頁已經不要了（關掉、換頁）
                guard let data, let url else { task.didFailWithError(URLError(.cancelled)); return }
                task.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            }
        }
    }
    func webView(_ w: WKWebView, stop task: WKURLSchemeTask) { lock.lock(); live.remove(ObjectIdentifier(task)); lock.unlock() }
}
