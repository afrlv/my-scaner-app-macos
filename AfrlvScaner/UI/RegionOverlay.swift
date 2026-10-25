import SwiftUI

/// Редактор областей: одна Canvas-рамка для отрисовки и один жест для всех действий.
struct RegionOverlay: View {
    let regions: [ScanRegion]
    let selectedID: UUID?
    let glass: CGSize
    let app: AppState

    private enum Handle: CaseIterable {
        case nw, n, ne, e, se, s, sw, w

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .nw: CGPoint(x: r.minX, y: r.minY)
            case .n: CGPoint(x: r.midX, y: r.minY)
            case .ne: CGPoint(x: r.maxX, y: r.minY)
            case .e: CGPoint(x: r.maxX, y: r.midY)
            case .se: CGPoint(x: r.maxX, y: r.maxY)
            case .s: CGPoint(x: r.midX, y: r.maxY)
            case .sw: CGPoint(x: r.minX, y: r.maxY)
            case .w: CGPoint(x: r.minX, y: r.midY)
            }
        }

        var movesLeft: Bool { self == .nw || self == .w || self == .sw }
        var movesRight: Bool { self == .ne || self == .e || self == .se }
        var movesTop: Bool { self == .nw || self == .n || self == .ne }
        var movesBottom: Bool { self == .sw || self == .s || self == .se }
    }

    private enum Mode {
        case move(UUID, CGRect)
        case resize(UUID, CGRect, Handle)
        case create
        case close(UUID)
        case none
    }

    private static let minSizeMM: CGFloat = 4

    /// Черновик рамки во время жеста: в AppState попадает только по окончании.
    private struct Draft {
        /// nil — рамка создаётся и ещё не существует в AppState
        var id: UUID?
        var rect: CGRect
    }

    @State private var mode: Mode?
    @State private var draft: Draft?

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / glass.width
            Canvas { context, _ in
                draw(context: context, k: k)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in changed(value, k: k) }
                    .onEnded { value in ended(value, k: k) }
            )
        }
    }

    // MARK: - Отрисовка

    private func viewRect(_ r: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
    }

    private func draw(context: GraphicsContext, k: CGFloat) {
        let accent = Color.accentColor
        var items = regions.map { region in
            (id: Optional(region.id), mm: draft?.id == region.id ? draft!.rect : region.rectMM)
        }
        if let draft, draft.id == nil { items.append((id: nil, mm: draft.rect)) }
        for (index, item) in items.enumerated() {
            let rect = viewRect(item.mm, k)
            let selected = item.id == nil || item.id == selectedID
            context.fill(Path(rect), with: .color(accent.opacity(0.14)))
            context.stroke(Path(rect), with: .color(accent), lineWidth: selected ? 2 : 1.5)

            let label = "\(index + 1) · \(Int(item.mm.width.rounded()))×\(Int(item.mm.height.rounded())) мм"
            let text = context.resolve(
                Text(label).font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundColor(.white))
            let size = text.measure(in: CGSize(width: 400, height: 40))
            let tagH = size.height + 4
            let tagY = rect.minY >= tagH ? rect.minY - tagH : rect.minY
            let tag = CGRect(x: rect.minX, y: tagY, width: size.width + 12, height: tagH)
            context.fill(Path(roundedRect: tag, cornerRadius: 3), with: .color(accent))
            context.draw(text, at: CGPoint(x: tag.minX + 6, y: tag.midY), anchor: .leading)

            if selected {
                for handle in Handle.allCases {
                    let p = handle.point(in: rect)
                    let box = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                    context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(.white))
                    context.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(accent), lineWidth: 1.5)
                }
                let c = closeCenter(rect)
                let circle = CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)
                context.fill(Path(ellipseIn: circle), with: .color(.black.opacity(0.85)))
                context.draw(
                    context.resolve(Text("×").font(.system(size: 13, weight: .medium)).foregroundColor(.white)),
                    at: c)
            }
        }
    }

    private func closeCenter(_ rect: CGRect) -> CGPoint {
        CGPoint(x: min(rect.maxX + 0, rect.maxX), y: rect.minY)
    }

    // MARK: - Жесты

    private func toMM(_ p: CGPoint, _ k: CGFloat) -> CGPoint {
        CGPoint(x: min(max(p.x / k, 0), glass.width), y: min(max(p.y / k, 0), glass.height))
    }

    private func hitTest(_ p: CGPoint, k: CGFloat) -> Mode {
        if let id = selectedID, let region = regions.first(where: { $0.id == id }) {
            let rect = viewRect(region.rectMM, k)
            let c = closeCenter(rect)
            if hypot(p.x - c.x, p.y - c.y) <= 10 { return .close(id) }
            for handle in Handle.allCases {
                let hp = handle.point(in: rect)
                if abs(p.x - hp.x) <= 7, abs(p.y - hp.y) <= 7 { return .resize(id, region.rectMM, handle) }
            }
        }
        if let region = regions.last(where: { viewRect($0.rectMM, k).contains(p) }) {
            return .move(region.id, region.rectMM)
        }
        return .create
    }

    /// Рамка, получающаяся из текущего положения указателя; nil — жест ещё не считается перетаскиванием.
    private func draftRect(value: DragGesture.Value, k: CGFloat) -> Draft? {
        let start = toMM(value.startLocation, k)
        let now = toMM(value.location, k)
        let dx = now.x - start.x
        let dy = now.y - start.y
        let moved = hypot(value.translation.width, value.translation.height) > 3

        switch mode {
        case .move(let id, let orig):
            guard moved else { return nil }
            var r = orig
            r.origin.x = min(max(orig.minX + dx, 0), glass.width - orig.width)
            r.origin.y = min(max(orig.minY + dy, 0), glass.height - orig.height)
            return Draft(id: id, rect: r)
        case .resize(let id, let orig, let handle):
            var minX = orig.minX, maxX = orig.maxX, minY = orig.minY, maxY = orig.maxY
            if handle.movesLeft { minX += dx }
            if handle.movesRight { maxX += dx }
            if handle.movesTop { minY += dy }
            if handle.movesBottom { maxY += dy }
            minX = min(max(minX, 0), glass.width); maxX = min(max(maxX, 0), glass.width)
            minY = min(max(minY, 0), glass.height); maxY = min(max(maxY, 0), glass.height)
            return Draft(
                id: id,
                rect: CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY)))
        case .create:
            guard moved else { return nil }
            return Draft(
                id: nil, rect: CGRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(dx), height: abs(dy)))
        default:
            return nil
        }
    }

    private func changed(_ value: DragGesture.Value, k: CGFloat) {
        if mode == nil {
            app.stripHasFocus = false
            let hit = hitTest(value.startLocation, k: k)
            mode = hit
            switch hit {
            case .move(let id, _), .resize(let id, _, _): app.selectedRegionID = id
            case .create: app.selectedRegionID = nil
            default: break
            }
        }
        if let next = draftRect(value: value, k: k) { draft = next }
    }

    private func ended(_ value: DragGesture.Value, k: CGFloat) {
        defer { mode = nil; draft = nil }
        let moved = hypot(value.translation.width, value.translation.height) > 3
        if case .close(let id) = mode {
            if !moved { app.deleteRegion(id) }
            return
        }
        guard let final = draftRect(value: value, k: k) ?? draft else { return }
        let big = final.rect.width >= Self.minSizeMM && final.rect.height >= Self.minSizeMM
        switch mode {
        case .create:
            if big { app.addRegion(final.rect) }
        case .move(let id, _), .resize(let id, _, _):
            if big { app.updateRegion(id, rect: final.rect) }
        default:
            break
        }
    }
}
