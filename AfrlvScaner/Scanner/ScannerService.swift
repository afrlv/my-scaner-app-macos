import AppKit
import CoreGraphics
import Foundation
import ImageCaptureCore
import Observation
import UniformTypeIdentifiers

// MARK: - Ошибки

enum ScannerError: LocalizedError {
    case noScanner
    case timeout
    case busy
    case disconnected
    case emptyResult
    case incomplete
    case device(String)

    var errorDescription: String? {
        switch self {
        case .noScanner: "Сканер не выбран или не найден"
        case .timeout: "Сканер не ответил вовремя"
        case .busy: "Сканер занят"
        case .disconnected: "Сканер отключился"
        case .emptyResult: "Сканер не вернул изображение"
        case .incomplete: "Сканер передал неполное изображение"
        case .device(let text): "Ошибка сканера: \(text)"
        }
    }

    static func wrap(_ error: Error) -> ScannerError {
        if let own = error as? ScannerError { return own }
        return .device((error as NSError).localizedDescription)
    }
}

// MARK: - Единицы измерения устройства

/// Единственное место пересчёта мм <-> единицы устройства.
struct DeviceUnits: Equatable, Sendable {
    enum Kind: Sendable { case centimeters, inches }
    let kind: Kind

    var measurementUnit: ICScannerMeasurementUnit {
        kind == .centimeters ? .centimeters : .inches
    }

    private var mmPerUnit: CGFloat { kind == .centimeters ? 10 : 25.4 }
    func toUnit(_ mm: CGFloat) -> CGFloat { mm / mmPerUnit }
    func toMM(_ value: CGFloat) -> CGFloat { value * mmPerUnit }

    func rectToUnit(_ mm: CGRect) -> CGRect {
        CGRect(x: toUnit(mm.minX), y: toUnit(mm.minY), width: toUnit(mm.width), height: toUnit(mm.height))
    }
}


// MARK: - Сервис

enum ScannerTransferPath: String, Sendable { case memory, file }

@MainActor
@Observable
final class ScannerService: NSObject, ScannerControlling {
    private(set) var scanners: [ScannerInfo] = []
    private(set) var selectedID: String?
    private(set) var capabilities: ScannerCapabilities?
    private(set) var state: ScannerState = .searching
    private(set) var partialImage: CGImage?
    private(set) var progress: Double = 0

    // Диагностика (для живого теста и отладки)
    private(set) var lastTransferPath: ScannerTransferPath?
    private(set) var overviewBandCount = 0
    private(set) var scanBandCount = 0
    /// Через сколько после старта операции пришла первая полоса
    private(set) var firstBandDelay: Duration?
    private(set) var diagnostics: [String] = []

    /// Максимальная длинная сторона результата preview()
    static let previewMaxSide = 1600
    /// Максимальная длинная сторона промежуточных изображений
    static let partialMaxSide = 1000

    private static let curatedResolutions = [75, 100, 150, 200, 300, 400, 600, 1200]

    @ObservationIgnored private var browser: ICDeviceBrowser?
    @ObservationIgnored private var devices: [ICDevice] = []
    @ObservationIgnored private var device: ICScannerDevice?
    @ObservationIgnored private var unit: ICScannerFunctionalUnit?
    @ObservationIgnored private var units = DeviceUnits(kind: .centimeters)
    @ObservationIgnored private var glassMM = CGSize.zero
    @ObservationIgnored private var supportedDPI: [Int] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closingDevice: ICDevice?
    /// Устройство, для которого requestOpenSession отправлен, а ответа ещё нет
    @ObservationIgnored private var pendingOpen: ICDevice?
    @ObservationIgnored private var selectChain: Task<Void, Never>?
    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private var didAutoSelect = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?
    /// Рабочий способ передачи для устройства (по id)
    @ObservationIgnored private var transferPaths: [String: ScannerTransferPath] = [:]

    // Ожидание делегатных колбэков
    private enum WaitKind: Hashable { case open, select, overview, scan, close, abandonedOpen }
    @ObservationIgnored private var waits: [WaitKind: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var timeouts: [WaitKind: Task<Void, Never>] = [:]

    // Приём данных текущей операции
    @ObservationIgnored private var pipeline: ScanPipeline?
    @ObservationIgnored private var opToken = 0
    @ObservationIgnored private var opStart = ContinuousClock.now
    @ObservationIgnored private var receivedBands = 0

    override init() {
        super.init()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeCurrentSession() }
        }
    }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    // MARK: Поиск

    func start() {
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.scanner.rawValue
                | UInt(ICDeviceLocationTypeMask.local.rawValue)
                | UInt(ICDeviceLocationTypeMask.shared.rawValue)
                | UInt(ICDeviceLocationTypeMask.bonjour.rawValue)
                | UInt(ICDeviceLocationTypeMask.bluetooth.rawValue))!
        self.browser = browser
        state = .searching
        browser.start()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            if self.scanners.isEmpty, self.state == .searching { self.state = .noScanner }
        }
    }

    private static func locationMask(_ device: ICDevice) -> UInt {
        device.type.rawValue & 0xFF00
    }

    private static func rank(_ device: ICDevice) -> Int {
        let loc = locationMask(device)
        if loc & UInt(ICDeviceLocationTypeMask.bonjour.rawValue) != 0 { return 3 }
        if loc & UInt(ICDeviceLocationTypeMask.shared.rawValue) != 0 { return 2 }
        return 1
    }

    private static func transport(_ device: ICDevice) -> String {
        let loc = locationMask(device)
        if loc & UInt(ICDeviceLocationTypeMask.bonjour.rawValue) != 0 { return "AirScan" }
        if loc & UInt(ICDeviceLocationTypeMask.shared.rawValue) != 0 { return "Сеть" }
        if loc & UInt(ICDeviceLocationTypeMask.local.rawValue) != 0 { return "USB" }
        if loc & UInt(ICDeviceLocationTypeMask.bluetooth.rawValue) != 0 { return "Bluetooth" }
        return device.transportType == ICDeviceTransport.transportTypeUSB.rawValue ? "USB" : "Сеть"
    }

    private static func id(of device: ICDevice) -> String {
        device.uuidString ?? device.name ?? "scanner"
    }

    private func rebuildScanners() {
        var byName: [String: ICDevice] = [:]
        var order: [String] = []
        for d in devices {
            let name = d.name ?? "Сканер"
            if let existing = byName[name] {
                if Self.rank(d) > Self.rank(existing) { byName[name] = d }
            } else {
                byName[name] = d
                order.append(name)
            }
        }
        scanners = order.compactMap { byName[$0] }.map {
            ScannerInfo(id: Self.id(of: $0), name: $0.name ?? "Сканер", transport: Self.transport($0))
        }
        if scanners.isEmpty == false, state == .noScanner { state = .searching }
        if selectedID == nil, !didAutoSelect, let first = scanners.first {
            didAutoSelect = true
            Task { await select(first.id) }
        }
    }

    // MARK: Ожидание колбэков

    /// Ждёт колбэк `kind`. Если для этого kind уже есть ожидание - оно завершается CancellationError.
    private func wait(
        _ kind: WaitKind, timeout: Duration, cancellable: Bool = true, start: () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            if waits[kind] != nil { finish(kind, .failure(CancellationError())) }
            waits[kind] = c
            timeouts[kind] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(kind, .failure(ScannerError.timeout))
            }
            if cancellable, Task.isCancelled {
                finish(kind, .failure(CancellationError()))
                return
            }
            start()
        }
    }

    private func finish(_ kind: WaitKind, _ result: Result<Void, Error>) {
        timeouts.removeValue(forKey: kind)?.cancel()
        waits.removeValue(forKey: kind)?.resume(with: result)
    }

    private func finishAll(_ error: Error) {
        for kind in Array(waits.keys) { finish(kind, .failure(error)) }
    }

    private static func result(_ error: Error?) -> Result<Void, Error> {
        if let error { return .failure(ScannerError.wrap(error)) }
        return .success(())
    }

    // MARK: Сессия

    private func closeCurrentSession() {
        finishAll(CancellationError())
        if let device {
            device.delegate = nil
            if device.hasOpenSession { device.requestCloseSession() }
        }
        device = nil
        unit = nil
    }

    /// Закрывает сессию и ждёт подтверждения (чтобы повторное открытие не упёрлось в закрывающуюся сессию).
    /// Если открытие ещё не завершилось - сначала дожидается его ответа.
    private func close(_ old: ICDevice) async {
        if old === pendingOpen {
            try? await wait(.abandonedOpen, timeout: .seconds(20), cancellable: false) {}
        }
        if old.hasOpenSession {
            closingDevice = old
            try? await wait(.close, timeout: .seconds(3), cancellable: false) { old.requestCloseSession() }
            closingDevice = nil
        }
        // Если ответ на открытие так и не пришёл, делегат оставляем: поздний успех закроем в колбэке
        if old !== pendingOpen { old.delegate = nil }
    }

    private func closeCurrentSessionAndWait() async {
        finishAll(CancellationError())
        guard let old = device else { return }
        device = nil
        unit = nil
        await close(old)
    }

    /// Закрывает сессию и прекращает работу (для тестов и корректного выхода).
    func shutdown() async {
        generation += 1
        finishAll(CancellationError())
        await selectChain?.value
        await closeCurrentSessionAndWait()
        state = .searching
    }

    /// Серия выборов выполняется строго по одному: открытие/закрытие не пересекаются.
    func select(_ id: String) async {
        guard let target = devices.first(where: { Self.id(of: $0) == id }) as? ICScannerDevice else { return }
        if target === device, state == .connecting || state == .ready {
            // Уже выбран: дождаться текущего подключения, если оно идёт
            await selectChain?.value
            return
        }
        guard !isBusy else { return }
        generation += 1
        let gen = generation
        finishAll(CancellationError())
        let previous = selectChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performSelect(target, id: id, gen: gen)
        }
        selectChain = task
        await task.value
    }

    private func performSelect(_ target: ICScannerDevice, id: String, gen: Int) async {
        guard gen == generation, !isBusy else { return }
        if target === device, state == .ready { return }
        await closeCurrentSessionAndWait()
        guard gen == generation else { return }
        device = target
        selectedID = id
        capabilities = nil
        state = .connecting
        await connect(target, gen: gen)
    }

    /// Открывает сессию на `target` и выбирает функциональный блок. Состояние: .ready или .error.
    private func connect(_ target: ICScannerDevice, gen: Int) async {
        target.delegate = self
        pendingOpen = target
        do {
            try await wait(.open, timeout: .seconds(20)) { target.requestOpenSession() }
            guard gen == generation, device === target else { return }

            // Функциональные блоки появляются чуть позже открытия сессии
            let deadline = ContinuousClock.now + .seconds(20)
            while target.availableFunctionalUnitTypes.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
                guard gen == generation, device === target else { return }
            }
            let types = target.availableFunctionalUnitTypes.compactMap {
                ICScannerFunctionalUnitType(rawValue: $0.uintValue)
            }
            guard let wanted = types.contains(.flatbed) ? .flatbed : types.first else {
                throw ScannerError.device("нет доступных блоков сканирования")
            }
            if Self.selectedUnit(of: target)?.type != wanted {
                try await wait(.select, timeout: .seconds(20)) { target.requestSelect(wanted) }
                guard gen == generation, device === target else { return }
            }
            guard let fu = Self.selectedUnit(of: target) else { throw ScannerError.emptyResult }
            unit = fu
            capabilities = readCapabilities(of: fu)
            state = .ready
        } catch {
            guard gen == generation, device === target else { return }
            if error is CancellationError { return }
            state = .error(ScannerError.wrap(error).localizedDescription)
        }
    }

    /// Закрывает и заново открывает сессию текущего устройства (после зависшей операции).
    private func recoverSession() async {
        guard let current = device else { return }
        let gen = generation
        unit = nil
        state = .connecting
        await close(current)
        guard gen == generation, device === current else { return }
        await connect(current, gen: gen)
    }

    /// selectedFunctionalUnit в заголовках non-null, но фактически бывает nil.
    private static func selectedUnit(of device: ICScannerDevice) -> ICScannerFunctionalUnit? {
        device.value(forKey: "selectedFunctionalUnit") as? ICScannerFunctionalUnit
    }

    private func readCapabilities(of fu: ICScannerFunctionalUnit) -> ScannerCapabilities {
        units = DeviceUnits(
            kind: fu.supportedMeasurementUnits.contains(Int(ICScannerMeasurementUnit.centimeters.rawValue))
                ? .centimeters : .inches)
        fu.measurementUnit = units.measurementUnit
        glassMM = CGSize(width: units.toMM(fu.physicalSize.width), height: units.toMM(fu.physicalSize.height))

        let supported = Array(fu.supportedResolutions).sorted()
        supportedDPI = supported
        var resolutions = Self.curatedResolutions.filter { supported.contains($0) }
        if resolutions.isEmpty { resolutions = Array(fu.preferredResolutions).sorted() }
        if resolutions.isEmpty {
            // Равномерная выборка не более 8 значений из поддерживаемых
            let step = max(1, Int((Double(supported.count) / 8).rounded(.up)))
            resolutions = stride(from: 0, to: supported.count, by: step).map { supported[$0] }
        }
        let previewDPI = supported.first(where: { $0 >= 50 }) ?? supported.first ?? resolutions.first ?? 75
        return ScannerCapabilities(
            glassSizeMM: glassMM, resolutions: resolutions, previewDPI: previewDPI,
            colorModes: ColorMode.allCases)
    }

    // MARK: Операции: ожидание, отмена, восстановление

    /// Выполняет запрос и ждёт didComplete*. При таймауте или отмене задачи: cancelScan, ожидание
    /// завершения до 10 с, иначе переоткрытие сессии. Возвращается (бросает) уже после восстановления.
    private func perform(_ kind: WaitKind, timeout: Duration, start: () -> Void) async throws {
        do {
            try await withTaskCancellationHandler {
                try await wait(kind, timeout: timeout, start: start)
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(kind, .failure(CancellationError())) }
            }
        } catch {
            var needsAbort = error is CancellationError
            if case ScannerError.timeout = error { needsAbort = true }
            if needsAbort { await abortOperation(kind) }
            throw error
        }
    }

    private func abortOperation(_ kind: WaitKind) async {
        guard let device else { return }
        do {
            try await wait(kind, timeout: .seconds(10), cancellable: false) { device.cancelScan() }
            return
        } catch ScannerError.timeout {
            diagnostics.append("cancelScan не завершился за 10 с: переоткрываем сессию")
        } catch {
            return  // didComplete с ошибкой, отключение или закрытие сервиса
        }
        await recoverSession()
    }

    // MARK: Превью

    func preview() async throws -> CGImage {
        guard let device, let unit, let caps = capabilities else { throw ScannerError.noScanner }
        guard !isBusy, state == .ready else { throw ScannerError.busy }
        isBusy = true
        state = .previewing
        let ticker = startTicker(unit)
        defer {
            ticker.cancel()
            endOperation()
            isBusy = false
            if case .previewing = state { state = .ready }
        }
        try Task.checkCancellation()

        unit.measurementUnit = units.measurementUnit
        unit.resolution = Self.nearest(caps.previewDPI, in: supportedDPI)
        unit.scanArea = units.rectToUnit(CGRect(origin: .zero, size: glassMM))
        unit.scanAreaOrientation = .orientation1
        _ = Self.setPixelFormat(unit, candidates: Self.candidates(for: .gray, unit: unit))
        do {
            return try await acquire(
                device: device, label: "preview", mode: .gray, target: nil,
                maxSide: Self.previewMaxSide, timeout: .seconds(120))
        } catch {
            if error is CancellationError { throw error }
            if case ScannerError.disconnected = error { throw error }
            diagnostics.append("preview: серый скан не удался (\(error)), откат на overview")
            guard self.device === device, state == .ready || state == .previewing else { throw error }
            state = .previewing
            return try await runOverview(device: device, unit: unit, dpi: caps.previewDPI)
        }
    }

    private func runOverview(device: ICScannerDevice, unit: ICScannerFunctionalUnit, dpi: Int) async throws -> CGImage {
        beginOperation()
        defer { endOperation() }
        unit.measurementUnit = units.measurementUnit
        _ = Self.setPixelFormat(unit, candidates: [(.RGB, 8)])
        unit.scanArea = units.rectToUnit(CGRect(origin: .zero, size: glassMM))
        unit.overviewResolution = dpi
        try await perform(.overview, timeout: .seconds(120)) { device.requestOverviewScan() }
        guard let pipeline else { throw ScannerError.emptyResult }
        await pipeline.drain()
        let (result, snapshot) = await pipeline.result(
            mode: .color, target: nil, maxSide: Self.previewMaxSide, external: unit.overviewImage)
        overviewBandCount = snapshot.bands
        record("overview", snapshot)
        return try result.get()
    }

    // MARK: Скан

    func scan(areaMM: CGRect, dpi: Int, mode: ColorMode) async throws -> CGImage {
        guard let device, let unit, capabilities != nil else { throw ScannerError.noScanner }
        guard !isBusy, state == .ready else { throw ScannerError.busy }
        isBusy = true
        state = .scanning
        let ticker = startTicker(unit)
        defer {
            ticker.cancel()
            endOperation()
            isBusy = false
            if case .scanning = state { state = .ready }
        }

        // Параметры
        unit.measurementUnit = units.measurementUnit
        let area = ScanGeometry.clamp(areaMM, to: glassMM)
        guard area.width > 0, area.height > 0 else { throw ScannerError.emptyResult }
        unit.resolution = Self.nearest(dpi, in: supportedDPI)
        unit.scanArea = units.rectToUnit(area)
        unit.scanAreaOrientation = .orientation1
        _ = Self.setPixelFormat(unit, candidates: Self.candidates(for: mode, unit: unit))

        let target = CGSize(
            width: max(1, ScanGeometry.mmToPixels(area.width, dpi: dpi)),
            height: max(1, ScanGeometry.mmToPixels(area.height, dpi: dpi)))
        return try await acquire(
            device: device, label: "scan \(mode.rawValue) \(dpi)", mode: mode, target: target,
            maxSide: nil, timeout: .seconds(300))
    }

    /// Скан с текущими параметрами: сначала запомненный способ передачи, затем второй.
    private func acquire(
        device: ICScannerDevice, label: String, mode: ColorMode, target: CGSize?, maxSide: Int?,
        timeout: Duration
    ) async throws -> CGImage {
        let deviceID = Self.id(of: device)
        let preferred = transferPaths[deviceID] ?? .memory
        let order: [ScannerTransferPath] = preferred == .memory ? [.memory, .file] : [.file, .memory]
        var lastError: Error = ScannerError.emptyResult
        for path in order {
            do {
                let image = try await runScan(
                    device: device, path: path, label: label, mode: mode, target: target,
                    maxSide: maxSide, timeout: timeout)
                transferPaths[deviceID] = path
                lastTransferPath = path
                return image
            } catch {
                if error is CancellationError { throw error }
                switch error as? ScannerError {
                case .timeout?, .disconnected?, .busy?, .noScanner?: throw error
                default: break
                }
                lastError = error
                diagnostics.append("\(label) \(path.rawValue): \(error)")
                guard self.device === device else { break }
            }
        }
        throw ScannerError.wrap(lastError)
    }

    private func runScan(
        device: ICScannerDevice, path: ScannerTransferPath, label: String, mode: ColorMode,
        target: CGSize?, maxSide: Int?, timeout: Duration
    ) async throws -> CGImage {
        beginOperation()
        var folder: URL?
        defer {
            endOperation()
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }
        switch path {
        case .memory:
            device.transferMode = .memoryBased
            device.maxMemoryBandSize = 2 * 1024 * 1024
        case .file:
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("afrlv-scan-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            folder = dir
            device.transferMode = .fileBased
            device.downloadsDirectory = dir
            device.documentName = "scan"
            device.documentUTI = UTType.tiff.identifier
        }
        try await perform(.scan, timeout: timeout) { device.requestScan() }
        guard let pipeline else { throw ScannerError.emptyResult }
        await pipeline.drain()
        let (result, snapshot) = await pipeline.result(mode: mode, target: target, maxSide: maxSide)
        scanBandCount = snapshot.bands
        record("\(label) \(path.rawValue)", snapshot)
        return try result.get()
    }

    private func record(_ title: String, _ snapshot: ScanPipeline.Snapshot) {
        var line = "\(title): bands \(snapshot.bands)"
        if let delay = firstBandDelay { line += ", first band after \(delay)" }
        diagnostics.append(line)
        if let first = snapshot.first { diagnostics.append("\(title) first band: \(first)") }
        if let last = snapshot.last, snapshot.bands > 1 { diagnostics.append("\(title) last band: \(last)") }
    }

    // MARK: Параметры формата

    private static func nearest(_ dpi: Int, in supported: [Int]) -> Int {
        if supported.isEmpty || supported.contains(dpi) { return dpi }
        return supported.min(by: { abs($0 - dpi) < abs($1 - dpi) }) ?? dpi
    }

    private static func candidates(
        for mode: ColorMode, unit: ICScannerFunctionalUnit
    ) -> [(ICScannerPixelDataType, Int)] {
        switch mode {
        case .color: [(.RGB, 8)]
        case .gray: [(.gray, 8), (.RGB, 8)]
        case .bw:
            unit.supportedBitDepths.contains(1)
                ? [(.BW, 1), (.gray, 8), (.RGB, 8)] : [(.gray, 8), (.RGB, 8)]
        }
    }

    /// Выставляет первый кандидат, который устройство приняло.
    @discardableResult
    private static func setPixelFormat(
        _ unit: ICScannerFunctionalUnit, candidates: [(ICScannerPixelDataType, Int)]
    ) -> Bool {
        for (type, depth) in candidates {
            unit.pixelDataType = type
            guard unit.pixelDataType == type else { continue }
            if let bits = ICScannerBitDepth(rawValue: UInt(depth)),
                unit.supportedBitDepths.contains(depth)
            {
                unit.bitDepth = bits
            }
            return true
        }
        return false
    }

    // MARK: Приём данных

    private func beginOperation() {
        opToken += 1
        let token = opToken
        receivedBands = 0
        firstBandDelay = nil
        partialImage = nil
        progress = 0
        opStart = ContinuousClock.now
        pipeline = ScanPipeline(thumbnailSide: Self.partialMaxSide) { [weak self] progress, thumbnail in
            Task { @MainActor in
                guard let self, self.opToken == token else { return }
                self.progress = progress
                if let thumbnail { self.partialImage = thumbnail }
            }
        }
    }

    private func endOperation() {
        opToken += 1
        pipeline = nil
        partialImage = nil
        progress = 0
    }

    private func startTicker(_ unit: ICScannerFunctionalUnit) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                if self.receivedBands == 0 {
                    let percent = Double(unit.scanProgressPercentDone)
                    self.progress = min(1, max(0, percent / 100))
                }
            }
        }
    }

    /// Вызывается на главном потоке: только копирует буфер и передаёт конвейеру.
    private func handleBand(_ band: ICScannerBandData) {
        receivedBands += 1
        if receivedBands == 1 { firstBandDelay = ContinuousClock.now - opStart }
        guard let pipeline, let buffer = band.dataBuffer else { return }
        let copy = buffer.withUnsafeBytes { Data($0) }
        let meta = BandMeta(
            fullWidth: Int(band.fullImageWidth), fullHeight: Int(band.fullImageHeight),
            bitsPerPixel: Int(band.bitsPerPixel), numComponents: Int(band.numComponents),
            bitsPerComponent: Int(band.bitsPerComponent), bytesPerRow: Int(band.bytesPerRow),
            dataStartRow: Int(band.dataStartRow), dataNumRows: Int(band.dataNumRows),
            dataCount: copy.count, pixelDataType: UInt(band.pixelDataType.rawValue),
            bigEndian: band.isBigEndian, profilePath: band.colorSyncProfilePath)
        pipeline.addBand(copy, meta: meta)
    }

    private func handleFile(_ url: URL) {
        pipeline?.addFile(url)
    }

    /// Завершение операции: сначала сборщик обрабатывает все полосы, потом просыпается ожидание.
    private func completeOperation(_ kind: WaitKind, error: Error?) {
        let result = Self.result(error)
        let token = opToken
        let pipeline = pipeline
        Task { [weak self] in
            await pipeline?.drain()
            guard let self, self.opToken == token else { return }
            self.finish(kind, result)
        }
    }

    private func handleDisconnect(_ gone: ICDevice) {
        devices.removeAll { $0 === gone }
        rebuildScanners()
        guard let current = device, current === gone else { return }
        gone.delegate = nil
        device = nil
        unit = nil
        generation += 1
        finishAll(ScannerError.disconnected)
        selectedID = nil
        capabilities = nil
        state = .error(ScannerError.disconnected.localizedDescription)
    }

    private func handleOpen(_ opened: ICDevice, error: Error?) {
        if opened === pendingOpen { pendingOpen = nil }
        if opened === device, waits[.open] != nil {
            finish(.open, Self.result(error))
            return
        }
        // Открытие было отменено (выбрали другой сканер) или завершилось таймаутом: сессия не нужна
        if error == nil, opened.hasOpenSession, waits[.abandonedOpen] == nil {
            if opened !== closingDevice { opened.requestCloseSession() }
        }
        finish(.abandonedOpen, .success(()))
    }

    private func handleClose(_ closed: ICDevice) {
        if closed === closingDevice {
            finish(.close, .success(()))
        } else if closed === device {
            // Сессию закрыли без нашего участия
            unit = nil
            capabilities = nil
            finishAll(ScannerError.disconnected)
            if case .error = state { return }
            state = .error(ScannerError.disconnected.localizedDescription)
        } else if closed !== pendingOpen {
            closed.delegate = nil
        }
    }

    private func handleAvailable(_ scanner: ICScannerDevice) {
        guard scanner === device, case .error = state, !isBusy, let id = selectedID else { return }
        Task { await select(id) }
    }
}

// MARK: - Делегаты ImageCaptureCore (вызываются на главном потоке)

extension ScannerService: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        let box = Unchecked(device)
        MainActor.assumeIsolated {
            let device = box.value
            guard device.type.rawValue & ICDeviceTypeMask.scanner.rawValue != 0,
                !devices.contains(where: { $0 === device })
            else { return }
            devices.append(device)
            if !moreComing { rebuildScanners() }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let box = Unchecked(device)
        MainActor.assumeIsolated {
            let device = box.value
            if devices.contains(where: { $0 === device }) { handleDisconnect(device) }
        }
    }
}

extension ScannerService: ICScannerDeviceDelegate {
    nonisolated func didRemove(_ device: ICDevice) {
        let box = Unchecked(device)
        MainActor.assumeIsolated { handleDisconnect(box.value) }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        let box = Unchecked(device)
        MainActor.assumeIsolated { handleOpen(box.value, error: error) }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        let box = Unchecked(device)
        MainActor.assumeIsolated { handleClose(box.value) }
    }

    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {}

    nonisolated func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) {
        let box = Unchecked(scanner)
        MainActor.assumeIsolated { handleAvailable(box.value) }
    }

    nonisolated func scannerDevice(
        _ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: (any Error)?
    ) {
        let box = Unchecked(scanner)
        MainActor.assumeIsolated {
            guard box.value === device else { return }
            finish(.select, Self.result(error))
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didScanTo data: ICScannerBandData) {
        let box = Unchecked((scanner, data))
        MainActor.assumeIsolated {
            guard box.value.0 === device else { return }
            handleBand(box.value.1)
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        let box = Unchecked(scanner)
        MainActor.assumeIsolated {
            if box.value === device {
                handleFile(url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    nonisolated func scannerDevice(
        _ scanner: ICScannerDevice, didCompleteOverviewScanWithError error: (any Error)?
    ) {
        let box = Unchecked(scanner)
        MainActor.assumeIsolated {
            guard box.value === device else { return }
            completeOperation(.overview, error: error)
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: (any Error)?) {
        let box = Unchecked(scanner)
        MainActor.assumeIsolated {
            guard box.value === device else { return }
            completeOperation(.scan, error: error)
        }
    }
}

private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
