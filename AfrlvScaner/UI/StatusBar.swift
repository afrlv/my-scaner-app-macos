import AppKit
import SwiftUI

struct StatusBar: View {
    let app: AppState
    /// Подписка на смену папки в настройках, чтобы путь обновлялся
    @AppStorage(AppSettings.outputFolderKey) private var folderPath = ""

    var body: some View {
        let line = app.statusLine
        HStack(spacing: 16) {
            Text(line.text)
                .foregroundStyle(line.isError ? Color.red : Color.secondary)
                .lineLimit(1)
            if case .error = app.scanner.state {
                Button("Переподключить") { Task { await app.reconnect() } }
                    .controlSize(.small)
            }
            if app.busy {
                ProgressView(value: app.scanner.progress).frame(width: 120)
            }
            Spacer(minLength: 0)
            Button {
                reveal()
            } label: {
                Text("→ " + app.pathLabel).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Показать в Finder")
            .id(folderPath)
        }
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 5)
        .overlay(alignment: .top) { Divider() }
    }

    private func reveal() {
        if !app.lastSavedURLs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(app.lastSavedURLs)
        } else if FileManager.default.fileExists(atPath: app.outputFolder.path) {
            NSWorkspace.shared.open(app.outputFolder)
        }
    }
}
