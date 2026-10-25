import CoreGraphics
import Observation

@MainActor
protocol ScannerControlling: AnyObject, Observable {
    var scanners: [ScannerInfo] { get }
    var selectedID: String? { get }
    var capabilities: ScannerCapabilities? { get }
    var state: ScannerState { get }
    /// Частичное изображение во время превью/скана (полосами по мере прихода), nil если нет
    var partialImage: CGImage? { get }
    /// 0...1
    var progress: Double { get }
    func start()
    func select(_ id: String) async
    /// Всё стекло на capabilities.previewDPI
    func preview() async throws -> CGImage
    func scan(areaMM: CGRect, dpi: Int, mode: ColorMode) async throws -> CGImage
}
