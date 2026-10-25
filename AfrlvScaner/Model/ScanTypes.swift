import CoreGraphics
import Foundation

enum ColorMode: String, CaseIterable, Sendable {
    case color, gray, bw

    var title: String {
        switch self {
        case .color: "Цвет"
        case .gray: "Серый"
        case .bw: "Ч/Б"
        }
    }
}

enum OutputFormat: String, CaseIterable, Sendable {
    case pdf, jpeg
}

enum SplitMode: String, CaseIterable, Sendable {
    case singleFile, separateFiles

    var title: String {
        switch self {
        case .singleFile: "Один файл"
        case .separateFiles: "Каждая отдельно"
        }
    }
}

struct ScanRegion: Identifiable, Equatable, Sendable {
    var id = UUID()
    var rectMM: CGRect
}

struct ScannedPage: Identifiable, @unchecked Sendable {
    let id = UUID()
    var image: CGImage
    var dpi: Int
    var quarterTurns: Int = 0
    var colorMode: ColorMode = .color
}

struct ScannerInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let transport: String
}

struct ScannerCapabilities: Equatable, Sendable {
    var glassSizeMM: CGSize
    var resolutions: [Int]
    var previewDPI: Int
    var colorModes: [ColorMode]
}

enum ScannerState: Equatable, Sendable {
    case searching, noScanner, connecting, ready, previewing, scanning
    case error(String)
}
