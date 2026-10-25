import CoreGraphics
import Foundation
import Observation

enum MockScene {
    static let glassSizeMM = CGSize(width: 216, height: 297)
    static let sheetMM = CGRect(x: 12, y: 10, width: 126, height: 166)
    static let photoMM = CGRect(x: 120, y: 192, width: 84, height: 64)

    static func render(areaMM: CGRect, dpi: Int) -> CGImage? {
        let w = max(1, ScanGeometry.mmToPixels(areaMM.width, dpi: dpi))
        let h = max(1, ScanGeometry.mmToPixels(areaMM.height, dpi: dpi))
        guard let ctx = ImageOps.makeContext(width: w, height: h) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / areaMM.width, y: -CGFloat(h) / areaMM.height)
        ctx.translateBy(x: -areaMM.minX, y: -areaMM.minY)

        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: glassSizeMM))

        ctx.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.9, alpha: 1))
        ctx.fill(sheetMM)
        ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
        var y = sheetMM.minY + 12
        var index = 0
        while y < sheetMM.maxY - 12 {
            let width = sheetMM.width - 24 - (index % 4 == 3 ? 40 : 0)
            ctx.fill(CGRect(x: sheetMM.minX + 12, y: y, width: width, height: 2.5))
            y += 8
            index += 1
        }

        let colors = [
            CGColor(red: 0.95, green: 0.45, blue: 0.2, alpha: 1),
            CGColor(red: 0.2, green: 0.55, blue: 0.9, alpha: 1),
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            ctx.saveGState()
            ctx.clip(to: photoMM)
            ctx.drawLinearGradient(
                gradient, start: photoMM.origin, end: CGPoint(x: photoMM.maxX, y: photoMM.maxY), options: [])
            ctx.restoreGState()
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: photoMM.minX + 15, y: photoMM.minY + 15, width: 28, height: 28))
        return ctx.makeImage()
    }
}

enum MockScannerError: Error, LocalizedError {
    case renderFailed
    case notReady

    var errorDescription: String? {
        switch self {
        case .renderFailed: "Не удалось получить изображение"
        case .notReady: "Сканер не готов"
        }
    }
}

@MainActor
@Observable
final class MockScanner: ScannerControlling {
    private(set) var scanners: [ScannerInfo] = []
    private(set) var selectedID: String?
    private(set) var capabilities: ScannerCapabilities?
    private(set) var state: ScannerState = .searching
    private(set) var partialImage: CGImage?
    private(set) var progress: Double = 0

    private let info = ScannerInfo(id: "mock", name: "Демо-сканер", transport: "Демо")
    private let stepDelay: Duration

    init(stepDelay: Duration = .milliseconds(150)) {
        self.stepDelay = stepDelay
    }

    func start() {
        scanners = [info]
        Task { await select(info.id) }
    }

    func select(_ id: String) async {
        guard id == info.id else { return }
        state = .connecting
        selectedID = id
        try? await Task.sleep(for: .milliseconds(100))
        capabilities = ScannerCapabilities(
            glassSizeMM: MockScene.glassSizeMM,
            resolutions: [75, 150, 300, 600],
            previewDPI: 75,
            colorModes: ColorMode.allCases)
        state = .ready
    }

    func preview() async throws -> CGImage {
        guard let caps = capabilities, state == .ready else { throw MockScannerError.notReady }
        state = .previewing
        defer { state = .ready; partialImage = nil; progress = 0 }
        let area = CGRect(origin: .zero, size: caps.glassSizeMM)
        return try await run(area: area, dpi: caps.previewDPI, steps: 6)
    }

    func scan(areaMM: CGRect, dpi: Int, mode: ColorMode) async throws -> CGImage {
        guard capabilities != nil, state == .ready else { throw MockScannerError.notReady }
        state = .scanning
        defer { state = .ready; partialImage = nil; progress = 0 }
        let image = try await run(area: areaMM, dpi: dpi, steps: 4)
        switch mode {
        case .color: return image
        case .gray: return ImageOps.toGray(image)
        case .bw: return ImageOps.toBW(image)
        }
    }

    private func run(area: CGRect, dpi: Int, steps: Int) async throws -> CGImage {
        guard let image = MockScene.render(areaMM: area, dpi: dpi) else { throw MockScannerError.renderFailed }
        for step in 1...steps {
            try await Task.sleep(for: stepDelay)
            let rows = image.height * step / steps
            partialImage = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: rows))
            progress = Double(step) / Double(steps)
        }
        return image
    }
}
