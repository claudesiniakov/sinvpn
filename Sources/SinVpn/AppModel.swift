import SwiftUI
import AppKit
import ServiceManagement
import SinVpnCore

/// Состояние строки VPN в панели.
enum RowState: Equatable {
    case off, connecting, on, disconnecting, failed

    var title: String {
        switch self {
        case .off: return "Отключено"
        case .connecting: return "Подключение…"
        case .on: return "Подключено"
        case .disconnecting: return "Отключение…"
        case .failed: return "Не удалось подключиться"
        }
    }

    var isOn: Bool { self == .on || self == .connecting }
    var isBusy: Bool { self == .connecting || self == .disconnecting }
}

struct SessionStats: Equatable {
    var seconds: Double = 0
    var rx: UInt64 = 0
    var tx: UInt64 = 0
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: - Состояние для интерфейса

    private(set) var services: [VPNService] = []
    private(set) var loaded = false
    private(set) var session: SessionStats?
    private(set) var store = StatsStore()
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var blink = false
    var panelOpen = false {
        didSet { if panelOpen { kick() } }
    }

    let updater = Updater()

    private var attempts: [String: ConnectAttempt] = [:]
    private var stopping: [String: Date] = [:]
    private var failed: Set<String> = []

    // MARK: - Внутреннее

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: NetworkWatcher?
    @ObservationIgnored private var meter = TrafficMeter()
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var secondsSinceRefresh = 0
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastUpdatePoll = Date.distantPast

    private static let statsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SinVpn/stats.json")
    }()

    func start() {
        guard loopTask == nil else { return }
        store = StatsStore.load(from: Self.statsURL)
        store.prune(now: Date())
        updater.beforeRestart = { [weak self] in self?.flush() }
        watcher = NetworkWatcher {
            Task { @MainActor in AppModel.shared.kick() }
        }
        loopTask = Task {
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Опрос

    private var isTransitional: Bool {
        !attempts.isEmpty || !stopping.isEmpty
            || services.contains { $0.status == .connecting || $0.status == .disconnecting }
    }

    private var connectedIDs: [String] {
        services.filter { $0.status == .connected }.map(\.id)
    }

    /// Раз в секунду: решает, пора ли опрашивать систему. Панель открыта или идёт переключение —
    /// каждую секунду; VPN включён — раз в 5 с (замер трафика); иначе раз в 3 с плюс уведомления сети.
    private func tick() async {
        secondsSinceRefresh += 1
        let period = (panelOpen || isTransitional) ? 1 : (connectedIDs.isEmpty ? 3 : 5)
        if secondsSinceRefresh >= period { await refresh() }

        if isTransitional {
            blink.toggle()
        } else if blink {
            blink = false
        }

        let now = Date()
        if now.timeIntervalSince(lastUpdatePoll) >= 3600 {
            lastUpdatePoll = now
            Task { await updater.checkIfDue() }
        }
    }

    /// Немедленное обновление по событию (сеть изменилась, панель открыли, нажали переключатель).
    func kick() {
        Task { await refresh() }
    }

    private func refresh() async {
        if refreshing {
            refreshQueued = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshQueued = false
            secondsSinceRefresh = 0
            let result = await VPNControl.list()
            if result.code == 0 {
                apply(ScutilParser.parseList(result.output), now: Date())
            }
            loaded = true
        } while refreshQueued
    }

    private func apply(_ list: [VPNService], now: Date) {
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for (id, attempt) in attempts {
            guard let service = byID[id] else {
                attempts[id] = nil
                continue
            }
            switch attempt.evaluate(status: service.status, now: now) {
            case let .pending(next):
                if next != attempt { attempts[id] = next }
            case .succeeded:
                attempts[id] = nil
            case .failed:
                attempts[id] = nil
                failed.insert(id)
            }
        }
        for (id, since) in stopping {
            let status = byID[id]?.status ?? .disconnected
            if status == .disconnected || status == .invalid || now.timeIntervalSince(since) > 10 {
                stopping[id] = nil
            }
        }
        for service in list where service.status == .connected && failed.contains(service.id) {
            failed.remove(service.id)
        }

        if services != list { services = list }
        sampleTraffic(now: now)
    }

    // MARK: - Переключение

    func rowState(_ service: VPNService) -> RowState {
        if stopping[service.id] != nil, service.status != .disconnected, service.status != .invalid {
            return .disconnecting
        }
        if attempts[service.id] != nil {
            return service.status == .connected ? .on : .connecting
        }
        switch service.status {
        case .connected: return .on
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        case .disconnected, .invalid: return failed.contains(service.id) ? .failed : .off
        }
    }

    func toggle(_ service: VPNService) {
        let id = service.id
        switch rowState(service) {
        case .disconnecting:
            return
        case .on, .connecting:
            // Выключение или отмена попытки подключения.
            attempts[id] = nil
            failed.remove(id)
            stopping[id] = Date()
            Task {
                _ = await VPNControl.stop(id)
                await refresh()
            }
        case .off, .failed:
            failed.remove(id)
            attempts[id] = ConnectAttempt(startedAt: Date())
            Task {
                let result = await VPNControl.start(id)
                if result.code != 0, !result.timedOut, attempts[id] != nil {
                    attempts[id] = nil
                    failed.insert(id)
                }
                await refresh()
            }
        }
    }

    // MARK: - Значок

    private static let iconPreview = ProcessInfo.processInfo.environment["SINVPN_ICON_PREVIEW"]

    var menuBarImage: NSImage {
        // Только для скриншотов в CI: SINVPN_ICON_PREVIEW=on показывает залитый значок.
        if Self.iconPreview == "on" { return MenuBarIcon.on }
        if services.contains(where: { $0.status == .connected }) { return MenuBarIcon.on }
        if isTransitional { return blink ? MenuBarIcon.dim : MenuBarIcon.off }
        return MenuBarIcon.off
    }

    // MARK: - Статистика

    var today: DayStats { store.total(days: 1, endingAt: Date()) }
    var month: DayStats { store.total(days: 30, endingAt: Date()) }

    private func sampleTraffic(now: Date) {
        let ids = connectedIDs
        guard !ids.isEmpty else {
            if session != nil {
                session = nil
                meter.reset()
                lastSample = nil
                save()
            }
            return
        }
        if session == nil {
            session = SessionStats()
            meter.reset()
            lastSample = nil
        }

        // Интерфейсы подключённых VPN: сначала по данным системы, иначе — все активные туннели.
        var interfaces = Set(ids.compactMap { watcher?.interfaceName(serviceID: $0) })
        if interfaces.isEmpty { interfaces = InterfaceReader.activeTunnelInterfaces() }
        let counters = InterfaceReader.counters().filter { interfaces.contains($0.key) }
        let delta = meter.sample(counters)

        // Время между замерами; большой разрыв (сон Mac) не засчитывается.
        var elapsed = lastSample.map { now.timeIntervalSince($0) } ?? 0
        if elapsed < 0 || elapsed > 30 { elapsed = 0 }
        lastSample = now

        guard elapsed > 0 || delta != InterfaceCounters() else { return }
        session?.seconds += elapsed
        session?.rx += delta.rx
        session?.tx += delta.tx
        store.add(seconds: elapsed, rx: delta.rx, tx: delta.tx, at: now)
        dirty = true
        if now.timeIntervalSince(lastSave) >= 60 { save() }
    }

    func resetStats() {
        store.reset()
        if session != nil { session = SessionStats() }
        dirty = true
        save()
    }

    private func save() {
        guard dirty else { return }
        store.prune(now: Date())
        do {
            try store.save(to: Self.statsURL)
            dirty = false
            lastSave = Date()
        } catch {
            NSLog("SinVpn: не удалось сохранить статистику: \(error.localizedDescription)")
        }
    }

    /// Сохранение перед выходом и перед перезапуском для обновления.
    func flush() {
        save()
    }

    // MARK: - Прочее

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("SinVpn: автозапуск: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openVPNSettings() {
        let pane = "x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"
        if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func quit() {
        flush()
        NSApp.terminate(nil)
    }
}
