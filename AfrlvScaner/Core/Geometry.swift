import CoreGraphics

enum ScanGeometry {
    static func mmToPixels(_ mm: CGFloat, dpi: Int) -> Int {
        Int((mm / 25.4 * CGFloat(dpi)).rounded())
    }

    static func union(_ rects: [CGRect]) -> CGRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }

    static func clamp(_ rect: CGRect, to glass: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: glass)
        let clipped = rect.standardized.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }

    /// Прямоугольник пикселей изображения, отсканированного по области `scan`, соответствующий `regionMM`.
    static func pixelRect(of regionMM: CGRect, inScanAreaMM scan: CGRect, imageSize: CGSize) -> CGRect {
        guard scan.width > 0, scan.height > 0 else { return .zero }
        let sx = imageSize.width / scan.width
        let sy = imageSize.height / scan.height
        let region = regionMM.standardized
        let minX = ((region.minX - scan.minX) * sx).rounded()
        let minY = ((region.minY - scan.minY) * sy).rounded()
        let maxX = ((region.maxX - scan.minX) * sx).rounded()
        let maxY = ((region.maxY - scan.minY) * sy).rounded()
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let clipped = rect.intersection(CGRect(origin: .zero, size: imageSize))
        return clipped.isNull ? .zero : clipped
    }

    static func viewToMM(_ p: CGPoint, viewSize: CGSize, glass: CGSize) -> CGPoint {
        CGPoint(x: p.x / viewSize.width * glass.width, y: p.y / viewSize.height * glass.height)
    }

    static func mmToView(_ p: CGPoint, viewSize: CGSize, glass: CGSize) -> CGPoint {
        CGPoint(x: p.x / glass.width * viewSize.width, y: p.y / glass.height * viewSize.height)
    }
}
