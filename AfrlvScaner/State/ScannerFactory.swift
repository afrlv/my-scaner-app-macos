import Foundation

enum ScannerFactory {
    @MainActor
    static func make() -> any ScannerControlling {
        let env = ProcessInfo.processInfo.environment
        // Под XCTest хост-приложение не должно занимать сессию реального сканера
        return env["AFRLV_MOCK"] == "1" || env["XCTestConfigurationFilePath"] != nil ? MockScanner() : ScannerService()
    }
}
