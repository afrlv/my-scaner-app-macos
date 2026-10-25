import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.outputFolderKey) private var folderPath = ""

    private var current: URL {
        folderPath.isEmpty ? AppSettings.defaultOutputFolder : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    var body: some View {
        Form {
            LabeledContent("Папка для сканов") {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(AppState.abbreviate(current.path))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Выбрать…") { choose() }
                        Button("Показать в Finder") {
                            try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(current)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}
