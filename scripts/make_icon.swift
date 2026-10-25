// Генерация иконки приложения: swift scripts/make_icon.swift
// Каждый размер рисуется векторно, без даунскейла мастера.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    // continuous-corner приближение: обычный скруглённый прямоугольник с чуть увеличенным радиусом
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let small = px <= 32
    let tiny = px <= 16

    // Плитка: поле ~10%
    let inset = s * 0.10
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tileR = tile.width * 0.225
    let tilePath = squircle(tile, radius: tileR)

    // Тень плитки
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.025, color: rgb(0x000000, 0.45))
    ctx.setFillColor(rgb(0x1E2126))
    ctx.addPath(tilePath); ctx.fillPath()
    ctx.restoreGState()

    // Фон-градиент
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x3A3F47), rgb(0x1E2126)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    // Лист бумаги (с поворотом −6°)
    let paperW = tile.width * 0.56
    let paperH = tile.width * 0.68
    let center = CGPoint(x: tile.midX, y: tile.midY)
    let paper = CGRect(x: -paperW / 2, y: -paperH / 2, width: paperW, height: paperH)
    let paperR = paperW * 0.06
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: -6 * .pi / 180)
    ctx.saveGState()
    if !tiny {
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: rgb(0x000000, 0.4))
    }
    ctx.setFillColor(rgb(0xF4F5F7))
    ctx.addPath(squircle(paper, radius: paperR)); ctx.fillPath()
    ctx.restoreGState()

    // Строки текста
    let lines = tiny ? 4 : (small ? 5 : 6)
    let padX = paperW * 0.12
    let top = paper.maxY - paperH * 0.12
    let bottom = paper.minY + paperH * 0.10
    let step = (top - bottom) / CGFloat(lines)
    let lh = max(step * (tiny ? 0.5 : 0.36), 1)
    for i in 0..<lines {
        let y = top - CGFloat(i) * step - lh
        var w = paperW - 2 * padX
        let color: CGColor
        if i == 0 { w *= 0.55; color = rgb(0x8A9099) } else {
            color = rgb(0xB5BAC2)
            if i == lines - 1 { w *= 0.7 }
        }
        let r = CGRect(x: paper.minX + padX, y: y, width: w, height: lh)
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: lh / 2, cornerHeight: lh / 2, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Рамка выделения (без поворота): нижние ~2/3 листа
    let selW = paperW * 0.92
    let selH = paperH * 0.64
    let sel = CGRect(x: center.x - selW / 2 + paperW * 0.02, y: center.y - paperH / 2 + paperH * 0.02 - s * 0.01,
                     width: selW, height: selH)
    let lw = max(s * 0.03, tiny ? 1.6 : 1.0)
    ctx.setStrokeColor(rgb(0x0A84FF))
    ctx.setLineWidth(lw)
    ctx.setFillColor(rgb(0x0A84FF, 0.12))
    ctx.addRect(sel); ctx.drawPath(using: .fillStroke)

    // Линия сканирования на ~40% высоты листа (от верха)
    let scanY = center.y + paperH / 2 - paperH * 0.40
    let scanX0 = center.x - paperW * 0.62
    let scanX1 = center.x + paperW * 0.62
    let scanLW = max(s * 0.016, tiny ? 1.2 : 1.0)
    ctx.saveGState()
    if !tiny {
        ctx.setShadow(offset: .zero, blur: s * 0.03, color: rgb(0x4DA3FF, 0.95))
    }
    ctx.setStrokeColor(rgb(0x4DA3FF))
    ctx.setLineWidth(scanLW)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: scanX0, y: scanY)); ctx.addLine(to: CGPoint(x: scanX1, y: scanY))
    ctx.strokePath()
    ctx.restoreGState()

    // Ручки по углам
    if !tiny {
        let hs = max(s * 0.036, 3)
        for p in [CGPoint(x: sel.minX, y: sel.minY), CGPoint(x: sel.maxX, y: sel.minY),
                  CGPoint(x: sel.minX, y: sel.maxY), CGPoint(x: sel.maxX, y: sel.maxY)] {
            let h = CGRect(x: p.x - hs / 2, y: p.y - hs / 2, width: hs, height: hs)
            ctx.setFillColor(rgb(0xFFFFFF))
            ctx.setStrokeColor(rgb(0x0A84FF))
            ctx.setLineWidth(max(s * 0.008, 0.8))
            ctx.addRect(h); ctx.drawPath(using: .fillStroke)
        }
    } else {
        let hs = 3.0
        for p in [CGPoint(x: sel.minX, y: sel.minY), CGPoint(x: sel.maxX, y: sel.maxY)] {
            ctx.setFillColor(rgb(0xFFFFFF))
            ctx.fill(CGRect(x: p.x - hs / 2, y: p.y - hs / 2, width: hs, height: hs))
        }
    }
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    guard CGImageDestinationFinalize(d) else { fatalError("PNG write failed: \(url.path)") }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = root.appendingPathComponent("AfrlvScaner/Assets.xcassets")
let set = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let info = #"{"info":{"author":"xcode","version":1}}"#
try info.write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

var entries: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        writePNG(render(px), to: set.appendingPathComponent(name))
        entries.append(
            #"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(base)x\#(base)"}"#)
    }
}
let contents = #"{"images":["# + entries.joined(separator: ",") + #"],"info":{"author":"xcode","version":1}}"#
try contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// Превью для проверки (64 — дополнительно, в каталог не входит)
if CommandLine.arguments.count > 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for px in [1024, 64, 32, 16] { writePNG(render(px), to: out.appendingPathComponent("icon-\(px).png")) }
}
print("OK")
