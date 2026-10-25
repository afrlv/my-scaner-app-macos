import SwiftUI

/// Изображение превью — отдельная Equatable-view, не перерисовывается при правке рамок.
struct PreviewImageView: View, Equatable {
    let image: CGImage?
    let stale: Bool

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .saturation(stale ? 0 : 1)
                .opacity(stale ? 0.35 : 1)
        }
    }
}

struct PartialImageView: View, Equatable {
    let image: CGImage
    let areaMM: CGRect
    let scale: CGFloat

    var body: some View {
        let w = areaMM.width * scale
        let h = w * CGFloat(image.height) / CGFloat(max(image.width, 1))
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.low)
            .frame(width: w, height: h)
            .position(x: areaMM.minX * scale + w / 2, y: areaMM.minY * scale + h / 2)
    }
}

struct PreviewCanvas: View {
    let app: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let glass = app.glassSizeMM
            let pad: CGFloat = 18
            let availW = max(geo.size.width - pad * 2, 10)
            let availH = max(geo.size.height - pad * 2, 10)
            let k = min(availW / glass.width, availH / glass.height)
            let size = CGSize(width: glass.width * k, height: glass.height * k)

            ZStack(alignment: .topLeading) {
                Rectangle().fill(colorScheme == .dark ? Color(white: 0.06) : Color(red: 0.17, green: 0.18, blue: 0.21))
                // Во время превью старая картинка скрыта: частичное изображение заполняет стекло сверху вниз
                PreviewImageView(image: app.activity == .previewing ? nil : app.preview, stale: app.previewStale).equatable()
                if let partial = app.scanner.partialImage, let area = app.activeAreaMM {
                    PartialImageView(image: partial, areaMM: area, scale: k).equatable()
                }
                if app.preview == nil, app.scanner.partialImage == nil {
                    Text("Нажмите «Превью» (⌘P)")
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                RegionOverlay(regions: app.regions, selectedID: app.selectedRegionID, glass: glass, app: app)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)

            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, pad).padding(.bottom, 14)
                .allowsHitTesting(false)

            SummaryPanel(app: app)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(pad)
        }
    }

    private var hint: String {
        let g = app.glassSizeMM
        let dpi = app.capabilities?.previewDPI ?? 75
        return "Стекло \(Int(g.width)) × \(Int(g.height)) мм · превью \(dpi) dpi"
    }
}
