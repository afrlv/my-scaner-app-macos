import SwiftUI

struct SummaryPanel: View {
    let app: AppState

    var body: some View {
        let area = app.scanAreaMM
        let pxW = ScanGeometry.mmToPixels(area.width, dpi: app.dpi)
        let pxH = ScanGeometry.mmToPixels(area.height, dpi: app.dpi)
        VStack(alignment: .leading, spacing: 8) {
            card {
                label("Области")
                if app.regions.isEmpty {
                    row("Всё стекло", "\(mm(app.glassSizeMM.width))×\(mm(app.glassSizeMM.height)) мм")
                } else {
                    ForEach(Array(app.regions.enumerated()), id: \.element.id) { index, region in
                        row("\(index + 1)", "\(mm(region.rectMM.width))×\(mm(region.rectMM.height)) мм")
                    }
                }
            }
            card {
                label("Итог скана")
                row("Проход", "\(mm(area.width))×\(mm(area.height)) мм")
                row("Размер", "\(pxW)×\(pxH)")
                row("Последний скан", app.lastScanDuration.map(AppState.formatSeconds) ?? "—")
            }
        }
        .font(.system(size: 12))
        .frame(width: 210)
    }

    private func mm(_ v: CGFloat) -> Int { Int(v.rounded()) }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10.5)).tracking(0.6).foregroundStyle(.secondary)
    }

    private func row(_ left: String, _ right: String) -> some View {
        HStack(spacing: 8) {
            Text(left)
            Spacer(minLength: 4)
            Text(right).font(.system(size: 12, design: .monospaced)).monospacedDigit()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
