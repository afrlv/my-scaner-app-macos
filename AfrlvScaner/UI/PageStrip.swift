import SwiftUI

struct PageStrip: View {
    let app: AppState

    var body: some View {
        HStack(spacing: 10) {
            if app.pages.isEmpty {
                Text("Готовые страницы появятся здесь. Порядок меняется перетаскиванием, удалить можно клавишей ⌫, повернуть — клавишей R.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(Array(app.pages.enumerated()), id: \.element.id) { index, page in
                                PageThumb(
                                    thumbnail: app.thumbnails[page.id], number: index + 1,
                                    selected: page.id == app.selectedPageID
                                )
                                .equatable()
                                .id(page.id)
                                .onTapGesture {
                                    app.selectedPageID = page.id
                                    app.stripHasFocus = true
                                }
                                .draggable(page.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                                    app.movePage(id: id, before: page.id)
                                    return true
                                }
                            }
                        }
                        .padding(2)
                    }
                    .onChange(of: app.pages.count) {
                        if let last = app.pages.last { proxy.scrollTo(last.id) }
                    }
                }
            }
            saveControls.fixedSize().layoutPriority(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(height: 92)
        .background(.bar)
    }

    private var saveControls: some View {
        HStack(spacing: 8) {
            Picker("Формат", selection: Bindable(app).format) {
                Text("PDF").tag(OutputFormat.pdf)
                Text("JPEG").tag(OutputFormat.jpeg)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if app.format == .pdf {
                Picker("Несколько областей", selection: Bindable(app).split) {
                    ForEach(SplitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Button {
                Task { await app.save() }
            } label: {
                HStack(spacing: 6) {
                    Text("Сохранить").fontWeight(.semibold)
                    Text("⌘S").font(.system(size: 11, design: .monospaced)).opacity(0.75)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.canSave)
        }
    }
}

struct PageThumb: View, Equatable {
    let thumbnail: CGImage?
    let number: Int
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable().interpolation(.medium).scaledToFit()
            } else {
                Color.white
            }
            Text("\(number)")
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 2))
                .foregroundStyle(.white)
                .padding(3)
        }
        .frame(height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2.5 : 1))
        .contentShape(Rectangle())
    }
}
