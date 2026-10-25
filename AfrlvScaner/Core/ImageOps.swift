import CoreGraphics
import Foundation

enum ImageOps {
    static func makeContext(width: Int, height: Int, gray: Bool = false) -> CGContext? {
        if gray {
            return CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Контекст, совместимый с исходником: серый остаётся серым, цвет сохраняет свой colorspace.
    static func makeContext(like image: CGImage, width: Int, height: Int) -> CGContext? {
        if let space = image.colorSpace {
            switch space.model {
            case .monochrome:
                return makeContext(width: width, height: height, gray: true)
            case .rgb:
                if let ctx = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                {
                    return ctx
                }
            default:
                break
            }
        }
        return makeContext(width: width, height: height)
    }

    /// Нарезка: каждый фрагмент копируется в собственный буфер и не держит исходное изображение.
    static func crop(_ image: CGImage, regionsMM: [CGRect], scanAreaMM: CGRect) -> [CGImage] {
        let size = CGSize(width: image.width, height: image.height)
        return regionsMM.compactMap { region in
            let rect = ScanGeometry.pixelRect(of: region, inScanAreaMM: scanAreaMM, imageSize: size)
            let w = Int(rect.width), h = Int(rect.height)
            guard w >= 1, h >= 1 else { return nil }
            guard let ctx = makeContext(like: image, width: w, height: h) else { return image.cropping(to: rect) }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            // В CGContext начало внизу слева, а rect считается сверху вниз.
            ctx.draw(
                image,
                in: CGRect(x: -rect.minX, y: -(size.height - rect.maxY), width: size.width, height: size.height))
            return ctx.makeImage()
        }
    }

    /// Поворот по часовой стрелке на `quarterTurns` четвертей оборота.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let swapped = turns != 2
        let outW = swapped ? image.height : image.width
        let outH = swapped ? image.width : image.height
        guard let ctx = makeContext(like: image, width: outW, height: outH) else { return image }
        switch turns {
        case 1:
            ctx.translateBy(x: 0, y: w)
            ctx.rotate(by: -.pi / 2)
        case 2:
            ctx.translateBy(x: w, y: h)
            ctx.rotate(by: .pi)
        default:
            ctx.translateBy(x: h, y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func toGray(_ image: CGImage) -> CGImage {
        guard let ctx = makeContext(width: image.width, height: image.height, gray: true) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    static func toBW(_ image: CGImage, threshold: UInt8 = 128) -> CGImage {
        let gray = toGray(image)
        guard let ctx = makeContext(width: gray.width, height: gray.height, gray: true),
              let data = ctx.data
        else { return gray }
        ctx.draw(gray, in: CGRect(x: 0, y: 0, width: gray.width, height: gray.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<ctx.height {
            let row = bytes + y * ctx.bytesPerRow
            for x in 0..<ctx.width { row[x] = row[x] >= threshold ? 255 : 0 }
        }
        return ctx.makeImage() ?? gray
    }
}
