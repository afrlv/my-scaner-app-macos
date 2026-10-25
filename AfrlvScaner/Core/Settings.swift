import Foundation

enum AppSettings {
    static let outputFolderKey = "outputFolder"

    static var defaultOutputFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Scans", isDirectory: true)
    }

    static var outputFolder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: outputFolderKey), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return defaultOutputFolder
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: outputFolderKey)
        }
    }
}
