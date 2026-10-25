import SwiftUI

struct MainView: View {
    let app: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PreviewCanvas(app: app)
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            Divider()
            PageStrip(app: app)
            StatusBar(app: app)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.delete) { app.deleteSelection(); return .handled }
        .onKeyPress(.deleteForward) { app.deleteSelection(); return .handled }
        .onKeyPress(.escape) {
            app.selectedRegionID = nil
            return .handled
        }
        .onKeyPress("r") {
            guard app.stripHasFocus, let id = app.selectedPageID else { return .ignored }
            app.rotatePage(id)
            return .handled
        }
        .navigationTitle("")
        .toolbar { MainToolbar(app: app) }
        .onAppear {
            focused = true
            app.start()
        }
        .task {
            // Отладочный прогон цепочки для скриншотов: AFRLV_DEMO=1
            guard ProcessInfo.processInfo.environment["AFRLV_DEMO"] == "1" else { return }
            while !app.isReady { try? await Task.sleep(for: .milliseconds(100)) }
            await app.preview()
            await app.autoDetect()
            if ProcessInfo.processInfo.environment["AFRLV_DEMO_SCAN"] == "1" { await app.scan() }
        }
        .onChange(of: app.selectedRegionID) { focused = true }
        .onChange(of: app.selectedPageID) { focused = true }
    }
}

extension ToolbarContent {
    /// На macOS 26+ убирает общую стеклянную подложку элемента тулбара.
    @ToolbarContentBuilder
    fileprivate func noGlass() -> some ToolbarContent {
        if #available(macOS 26, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Тулбар macOS 26+ подменяет системные bordered/segmented стили плоскими,
/// поэтому прямоугольную форму рисуем сами, в размерах нижних контролов.
private struct RectButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Color.accentColor : Color.primary.opacity(0.12))
                    .brightness(configuration.isPressed ? -0.1 : 0))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct MenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct RectMenuStyle: MenuStyle {
    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration).buttonStyle(RectButtonStyle()).menuStyle(.button).menuIndicator(.visible)
    }
}

struct MainToolbar: ToolbarContent {
    let app: AppState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) { scannerMenu }.noGlass()
        ToolbarItem(placement: .navigation) { modePicker }.noGlass()
        ToolbarItem(placement: .navigation) { dpiMenu }.noGlass()
        ToolbarItem(placement: .primaryAction) {
            actionButton("Превью", "⌘P", enabled: app.canPreview) { await app.preview() }
        }.noGlass()
        ToolbarItem(placement: .primaryAction) {
            actionButton("Авто", "⌘A", enabled: app.canAutoDetect) { await app.autoDetect() }
        }.noGlass()
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await app.scan() }
            } label: {
                Text("Сканировать").fontWeight(.semibold)
            }
            .help("Сканировать (⌘↩)")
            .buttonStyle(RectButtonStyle(prominent: true))
            .disabled(!app.canScan)
        }.noGlass()
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(app.capabilities?.colorModes ?? ColorMode.allCases, id: \.self) { mode in
                let on = app.colorMode == mode
                Button { app.colorMode = mode } label: {
                    Text(mode.title)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.accentColor : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.primary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize()
        .help("Режим цвета")
    }

    private var dpiMenu: some View {
        Menu {
            Picker("Разрешение", selection: Bindable(app).dpi) {
                ForEach(app.capabilities?.resolutions ?? [app.dpi], id: \.self) { Text("\($0) dpi").tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text("\(app.dpi) dpi")
                MenuChevron()
            }
        }
        .menuStyle(RectMenuStyle())
        .fixedSize()
        .help("Разрешение")
    }

    private var statusColor: Color {
        switch app.scanner.state {
        case .ready: .green
        case .searching, .connecting, .previewing, .scanning: .orange
        case .error: .red
        case .noScanner: .gray
        }
    }

    private var statusHelp: String {
        switch app.scanner.state {
        case .ready: "Сканер готов"
        case .searching: "Поиск сканеров…"
        case .connecting: "Подключение…"
        case .previewing, .scanning: "Сканер работает"
        case .error(let message): message
        case .noScanner: "Сканеры не найдены"
        }
    }

    private var scannerTitle: String {
        if let current = app.scanner.scanners.first(where: { $0.id == app.scanner.selectedID }) {
            return current.name
        }
        if app.scanner.scanners.isEmpty {
            return app.scanner.state == .noScanner ? "Сканеры не найдены" : "Поиск сканеров…"
        }
        return "Сканер"
    }

    private var scannerMenu: some View {
        Menu {
            Picker(
                "Сканер",
                selection: Binding(
                    get: { app.scanner.selectedID ?? "" },
                    set: { id in Task { await app.selectScanner(id) } })
            ) {
                ForEach(app.scanner.scanners) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(scannerTitle)
                MenuChevron()
            }
        }
        .menuStyle(RectMenuStyle())
        .fixedSize()
        .disabled(app.scanner.scanners.isEmpty)
        .help(statusHelp)
    }

    private func actionButton(
        _ title: String, _ shortcut: String, enabled: Bool, action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
        }
        .help("\(title) (\(shortcut))")
        .buttonStyle(RectButtonStyle())
        .disabled(!enabled)
    }
}
