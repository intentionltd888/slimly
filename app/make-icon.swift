// make-icon — 產 Slimly 的 1024 App icon（捲尺黃磚＋深灰 ›‹）
//
// 直接用 AppKit 畫向量，不經網頁截圖：磚角要透明、標記邊要銳利。幾何與顏色跟品牌正本
// ../4_品牌/標準字/slimly_brand.swift 同一組（改那邊要同步改這裡）：
//   磚＝滿版 1024、圓角 22.37%、上亮下暗 #FFD233→#F7B900（夾著品牌黃 #FFC814）、7% 黑細邊
//   ⚠ 一定要滿版不留邊：macOS 26 會自己套系統圓角遮罩，留邊的舊式圖示會被塞進一塊淺灰底板
//   標記＝兩個直角折線尖端相對 ›‹：高＝磚的 40%、筆粗 0.23H（垂直量）、尖端間距 0.12H、平切口；深灰 #2B2D33
//
// 用法：swift make-icon.swift <輸出 icon_1024.png>
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法：swift make-icon.swift <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let N: CGFloat = 1024
func rgb(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let brickTop = rgb(0xFFD233), brickBottom = rgb(0xF7B900), ink = rgb(0x2B2D33)
let T_RATIO: CGFloat = 0.23, GAP_RATIO: CGFloat = 0.12, MARK_H: CGFloat = 0.40

/// 一個直角折線的六個頂點（尖端朝 right ? 右 : 左；y 向上）
func chevron(tipX: CGFloat, midY: CGFloat, half: CGFloat, t: CGFloat, right: Bool) -> [CGPoint] {
    let d: CGFloat = right ? -1 : 1
    let ct = t / sqrt(2)
    return [CGPoint(x: tipX, y: midY),
            CGPoint(x: tipX + d * half, y: midY + half),
            CGPoint(x: tipX + d * (half + ct), y: midY + half - ct),
            CGPoint(x: tipX + d * t * sqrt(2), y: midY),
            CGPoint(x: tipX + d * (half + ct), y: midY - half + ct),
            CGPoint(x: tipX + d * half, y: midY - half)]
}
func mark(cx: CGFloat, cy: CGFloat, H: CGFloat) -> NSBezierPath {
    let t = T_RATIO * H, gap = GAP_RATIO * H
    let p = NSBezierPath()
    for poly in [chevron(tipX: cx - gap / 2, midY: cy, half: H / 2, t: t, right: true),
                 chevron(tipX: cx + gap / 2, midY: cy, half: H / 2, t: t, right: false)] {
        p.move(to: poly[0]); for q in poly.dropFirst() { p.line(to: q) }; p.close()
    }
    return p
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(N), pixelsHigh: Int(N), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let brick = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: N, height: N), xRadius: N * 0.2237, yRadius: N * 0.2237)
NSGradient(starting: brickTop, ending: brickBottom)!.draw(in: brick, angle: -90)
NSColor.black.withAlphaComponent(0.07).setStroke()
brick.lineWidth = 8; brick.stroke()            // 一半落在畫布外，實際看得到約 4px：放在黃色桌布上也分得出輪廓
ink.setFill()
mark(cx: N / 2, cy: N / 2, H: N * MARK_H).fill()
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: args[1])) } catch {
    FileHandle.standardError.write("寫檔失敗：\(error)\n".data(using: .utf8)!); exit(1)
}
print("icon → \(args[1])")
