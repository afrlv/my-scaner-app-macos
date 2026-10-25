import SwiftUI

@main
struct AfrlvScanerApp: App {
    @State private var app = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("AfrlvScaner", id: "main") {
            MainView(app: app)
                .frame(minWidth: 900, minHeight: 640)
        }
        .defaultSize(width: 1100, height: 800)
        .commands {
            CommandGroup(replacing: .printItem) {}
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .textEditing) {}
            CommandMenu("Скан") {
                Button("Превью") { Task { await app.preview() } }
                    .keyboardShortcut("p").disabled(!app.canPreview)
                Button("Авто") { Task { await app.autoDetect() } }
                    .keyboardShortcut("a").disabled(!app.canAutoDetect)
                Button("Сканировать") { Task { await app.scan() } }
                    .keyboardShortcut(.return).disabled(!app.canScan)
                Button("Сохранить") { Task { await app.save() } }
                    .keyboardShortcut("s").disabled(!app.canSave)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
