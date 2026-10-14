// ImageEngine.swift — 照片壓縮（擴充提案 #3）：HEIC、JPEG、PNG 也用同一顆鍵、同一套目標（25／10／5 MB、不限）
//
// 做法（系統內建 ImageIO，不加依賴）：
//   ・照片（沒有透明的地方）→ JPEG；真的有透明的 PNG → 還是 PNG（透明留著，只縮尺寸）
//   ・EXIF 方向直接轉正寫進像素、方向標記設回 1：各家看圖程式、網頁、Email 顯示都一樣
//   ・相機、拍攝時間（EXIF、IPTC）照留；GPS 位置預設照留，設定可以拿掉（Prefs.stripGPS）
//   ・六級：畫質 0.90／0.80／0.62（原尺寸；ImageIO 的品質是一格一格跳的：0.92–0.98 壓出來一樣大、0.80–0.84 一樣、0.62 再掉一大格，
//     實測），再往下縮長邊 3000／2400／1600 px（畫質同第三級）；跟 PDF 一樣第一個壓到目標以下就停，
//     壓不到目標交最小的那一版（照片不能「拆開寄」）；不限大小只做第一級
//   ・HEIC 一律轉成 JPEG 交出（Windows、Email 都打得開），就算比原檔大；其他沒小到 97% 以下＝不另存（原檔就是最好的版本）
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageLevel {
    let q: Double            // JPEG 品質（PNG 不用）
    let edge: Int?           // 長邊縮到幾 px；nil＝原尺寸
    let zh: String, en: String
    var label: String { L(zh, en) }
}

enum ImageLadder {
    static let levels: [ImageLevel] = [
        ImageLevel(q: 0.90, edge: nil, zh: "近無損", en: "Near-lossless"),
        ImageLevel(q: 0.80, edge: nil, zh: "高畫質", en: "High quality"),
        ImageLevel(q: 0.62, edge: nil, zh: "中畫質", en: "Medium quality"),
        ImageLevel(q: 0.62, edge: 3000, zh: "長邊 3000 px", en: "3000 px"),      // 縮尺寸的三級跟第三級同畫質：一級一定比前一級小
        ImageLevel(q: 0.62, edge: 2400, zh: "長邊 2400 px", en: "2400 px"),      //（用 0.80 時 3600 px 的圖縮到 3000 反而比第三級大，實測）
        ImageLevel(q: 0.62, edge: 1600, zh: "長邊 1600 px", en: "1600 px"),
    ]

    /// 透明的地方真的有嗎（縮成 1024 px 看每一點的 alpha）：沒有＝當照片轉 JPEG
    static func hasTransparency(_ src: CGImageSource) -> Bool {
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary) else { return false }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data else { return true }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var i = 3
        while i < w * h * 4 { if p[i] < 255 { return true }; i += 4 }
        return false
    }

    /// 整張轉正解一次。不用 ImageIO 直接縮小解碼：HEIC 縮小解碼走另一條路，跟整張解完再縮對不齊（差 1–2 px、PSNR 只剩 31 dB；
    /// JPEG 沒這個問題，實測）——前後對照的黃線兩邊會錯開，所以一律整張解、自己縮
    static func decode(_ src: CGImageSource, info: PDFInfo) -> CGImage? {
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: max(info.width, info.height, 1), kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }
    /// 長邊縮到 edge（比原本大就不動）；色彩空間照原圖、透明照留
    static func scaled(_ img: CGImage, edge: Int) -> CGImage? {
        let long = max(img.width, img.height)
        guard edge < long else { return img }
        let k = Double(edge) / Double(long), w = max(1, Int((Double(img.width) * k).rounded())), h = max(1, Int((Double(img.height) * k).rounded()))
        let gray = img.colorSpace?.model == .monochrome
        let alpha = ![.none, .noneSkipLast, .noneSkipFirst].contains(img.alphaInfo)
        let cs = gray ? CGColorSpaceCreateDeviceGray() : (img.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!)
        let info = gray ? CGImageAlphaInfo.none.rawValue : (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 照這一級（需要時縮小）編成 JPEG 或 PNG（在記憶體裡）；full＝整張轉正的圖、props＝原檔的中繼資料
    static func encode(_ full: CGImage, props: [CFString: Any], level i: Int, png: Bool, stripGPS: Bool) -> Data? {
        let lv = levels[i]
        guard let img = lv.edge.map({ scaled(full, edge: $0) }) ?? full else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return nil }
        var keep: [CFString: Any] = [:]
        for k in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] { if let v = props[k] { keep[k] = v } }
        if !stripGPS, let g = props[kCGImagePropertyGPSDictionary] { keep[kCGImagePropertyGPSDictionary] = g }
        if var t = keep[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { t[kCGImagePropertyTIFFOrientation] = 1; keep[kCGImagePropertyTIFFDictionary] = t }
        if var e = keep[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            e[kCGImagePropertyExifPixelXDimension] = img.width; e[kCGImagePropertyExifPixelYDimension] = img.height; keep[kCGImagePropertyExifDictionary] = e
        }
        keep[kCGImagePropertyOrientation] = 1
        if !png { keep[kCGImageDestinationLossyCompressionQuality] = lv.q }
        CGImageDestinationAddImage(dst, img, keep as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return data as Data
    }
}

/// 這一份的第 i 級叫什麼（PDF 跟照片的後三級不一樣：dpi／長邊 px）
func levelLabel(_ info: PDFInfo, _ i: Int) -> String {
    info.kind != .pdf ? ImageLadder.levels[max(0, min(i, ImageLadder.levels.count - 1))].label : Ladder.levels[max(0, min(i, Ladder.levels.count - 1))].label
}

/// 照種類挑引擎：PDF＝gs 階梯、照片＝ImageIO、Office 檔＝只重壓裡面的圖（主視窗、命令列、監看資料夾共用）
func makeCompressor(_ info: PDFInfo, target: Int64?, dest: URL?) -> Compressing {
    switch info.kind {
    case .image: return ImageCompressor(info: info, target: target, dest: dest)
    case .office: return OfficeCompressor(info: info, target: target, dest: dest)
    case .pdf: return Compressor(info: info, target: target, dest: dest)
    }
}

/// 壓一張照片。介面跟 PDF 的 Compressor 一樣（主視窗、命令列共用一條排隊）
final class ImageCompressor: Compressing {
    let info: PDFInfo
    let target: Int64?
    let destOverride: URL?
    var onProgress: ((Int, Int, Int) -> Void)?

    private let q = DispatchQueue(label: "slimly.image", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    init(info: PDFInfo, target: Int64?, dest: URL? = nil) { self.info = info; self.target = target; self.destOverride = dest }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(_ done: @escaping (Outcome) -> Void) { q.async { let r = self.ladder(); DispatchQueue.main.async { done(r) } } }
    func runSync() -> Outcome { ladder() }

    private func ladder() -> Outcome {
        guard let src = CGImageSourceCreateWithURL(info.url as CFURL, nil), let full = ImageLadder.decode(src, info: info) else { return .failed(code: "engine", detail: "") }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let png = info.alpha && ImageLadder.hasTransparency(src)
        let idx = target == nil ? [0] : Array(ImageLadder.levels.indices)
        var first: (i: Int, d: Data)? = nil, last: (i: Int, d: Data)? = nil, small: (i: Int, d: Data)? = nil
        for i in idx {
            if isCancelled { return .failed(code: "cancelled", detail: "") }
            if png && (i == 1 || i == 2) { continue }                         // PNG 沒有畫質這回事：只縮尺寸
            onProgress?(i, 0, 1)
            guard let d = ImageLadder.encode(full, props: props, level: i, png: png, stripGPS: Prefs.stripGPS) else { return .failed(code: "engine", detail: "") }
            if first == nil { first = (i, d) }
            last = (i, d); if small == nil || d.count < small!.d.count { small = (i, d) }
            if let t = target, Int64(d.count) <= t { break }
        }
        guard let first, let last, let small else { return .failed(code: "engine", detail: "") }
        let reached = target.map { Int64(last.d.count) <= $0 } ?? true
        // 壓不到目標：PDF 交第一級（還能「拆開寄」）；照片沒辦法拆，交最小的那一版（最接近目標），介面講還是超過
        let pick = reached ? last : (small.d.count < first.d.count ? small : first)
        let smallest = Int64(small.d.count)
        let convert = info.format == "HEIC"
        if !convert && Double(pick.d.count) >= Double(info.bytes) * Engine.minGain { return .noGain(best: Int64(pick.d.count)) }
        if isCancelled { return .failed(code: "cancelled", detail: "") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Slimly-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let ext = png ? "png" : "jpg", tmp = dir.appendingPathComponent("out.\(ext)")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true); try pick.d.write(to: tmp) }
        catch { return .failed(code: "space", detail: error.localizedDescription) }
        let note = convert && Int64(pick.d.count) > info.bytes ? "converted" : nil       // HEIC 轉 JPEG 變大：介面講一聲為什麼還是交
        return Compressor.place(tmp, src: info.url, destOverride: destOverride, ext: ext, bytes: Int64(pick.d.count),
                                level: pick.i, reached: reached, smallest: smallest, note: note)
    }
}
