import SwiftUI
import AppKit
import SinVpnCore

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Проверка, загрузка и установка обновлений из GitHub Releases.
/// Ничего не скачивается и не устанавливается без нажатия «Обновить».
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Int)
        case installing(ReleaseInfo)
        case failed(String, ReleaseInfo?)
    }

    private(set) var state: State = .idle
    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Keys.autoCheck) }
    }

    /// Вызывается перед перезапуском приложения (сохранение статистики).
    @ObservationIgnored var beforeRestart: () -> Void = {}
    @ObservationIgnored private var lastCheck = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date
    @ObservationIgnored private var installTask: Task<Void, Never>?

    private enum Keys {
        static let autoCheck = "autoCheckUpdates"
        static let lastCheck = "lastUpdateCheck"
    }

    let currentVersion: AppVersion?
    let currentVersionString: String

    init() {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        currentVersion = short.flatMap(AppVersion.init)
        currentVersionString = short ?? "dev"
        autoCheck = UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true
    }

    // MARK: - Строка в панели

    var statusLine: String {
        let version = "Версия \(currentVersionString)"
        switch state {
        case .idle: return version
        case .checking: return version + " · проверка…"
        case .upToDate: return version + " · обновлений нет"
        case let .available(release): return version + " · доступна \(release.version)"
        case let .downloading(release, percent): return "Загрузка \(release.version)… \(percent) %"
        case .installing: return "Перезапуск…"
        case let .failed(message, _):
            return "Не удалось обновить: " + (message.split(separator: "\n").first.map(String.init) ?? "")
        }
    }

    var actionTitle: String? {
        switch state {
        case .idle, .upToDate: return "Проверить"
        case .available: return "Обновить"
        case .failed: return "Повторить"
        case .checking, .downloading, .installing: return nil
        }
    }

    /// Есть новая версия или идёт установка — строку обновления нужно показать вне настроек.
    var needsAttention: Bool {
        switch state {
        case .available, .downloading, .installing, .failed(_, .some(_)): return true
        case .idle, .checking, .upToDate, .failed(_, .none): return false
        }
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var failureDetails: String? {
        if case let .failed(message, _) = state { return message }
        return nil
    }

    func primaryAction() {
        switch state {
        case let .available(release), let .failed(_, .some(release)):
            startInstall(release)
        case .idle, .upToDate, .failed:
            Task { await check(userInitiated: true) }
        case .checking, .downloading, .installing:
            break
        }
    }

    // MARK: - Проверка

    /// Автоматическая проверка: при запуске и затем не чаще раза в 24 часа.
    func checkIfDue() async {
        guard autoCheck else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        let previous = state
        state = .checking
        do {
            var request = URLRequest(url: ReleaseFeed.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("SinVpn-Updater", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await UpdateNetwork.session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Keys.lastCheck)
            // 404 — в репозитории ещё нет ни одного релиза.
            if code == 404 {
                state = .upToDate
                return
            }
            guard code == 200 else { throw ReleaseFeedError.invalidResponse }
            let release = try ReleaseFeed.parse(data)
            let newer = currentVersion.map { release.version > $0 } ?? true
            state = newer ? .available(release) : .upToDate
        } catch {
            // Фоновая проверка не должна показывать ошибку — только ручная.
            if userInitiated {
                state = .failed(error.localizedDescription, nil)
            } else if case .available = previous {
                state = previous
            } else {
                state = .idle
            }
        }
    }

    // MARK: - Установка

    /// Настоящее расположение бандла. Приложение, запущенное из карантина (например, прямо из
    /// «Загрузок»), система выполняет из временной копии только для чтения (App Translocation) —
    /// обновлять нужно исходный бандл, а не её.
    static let installURL: URL = {
        let running = Bundle.main.bundleURL
        guard running.path.contains("/AppTranslocation/") else { return running }
        typealias Resolver = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return running }
        let resolve = unsafeBitCast(symbol, to: Resolver.self)
        guard let original = resolve(running as CFURL, nil)?.takeRetainedValue() else { return running }
        return original as URL
    }()

    /// Почему установка на месте невозможна; nil — можно устанавливать.
    var installBlocker: String? {
        let bundle = Self.installURL
        if bundle.pathExtension != "app" || currentVersion == nil {
            return "Приложение запущено не из собранного SinVpn.app"
        }
        if bundle.path.contains("/AppTranslocation/") {
            return "Перенесите SinVpn в «Программы» через Finder и запустите оттуда"
        }
        let folder = bundle.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: folder) {
            return "Нет права записи в папку \(folder)"
        }
        return nil
    }

    private func startInstall(_ release: ReleaseInfo) {
        guard installTask == nil else { return }
        if let blocker = installBlocker {
            // Не уводим молча на сайт: показываем причину, страница релиза — по «Повторить».
            UpdateLog.write("Установка невозможна: \(blocker); бандл \(Self.installURL.path)")
            if case .failed(_, .some) = state {
                NSWorkspace.shared.open(release.pageURL)
            }
            state = .failed(blocker + ". Кнопка «Повторить» откроет страницу релиза.", release)
            return
        }
        installTask = Task {
            await install(release)
            installTask = nil
        }
    }

    private func install(_ release: ReleaseInfo) async {
        UpdateLog.write("— Обновление \(currentVersionString) → \(release.version), бандл \(Self.installURL.path)")
        state = .downloading(release, 0)
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("SinVpn-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let archive = work.appendingPathComponent(ReleaseFeed.archiveName)

            UpdateLog.write("Загрузка \(release.archiveURL.lastPathComponent)")
            let code = try await Self.download(release.archiveURL, to: archive) { [weak self] fraction in
                Task { @MainActor in self?.report(fraction, for: release) }
            }
            guard code == 200 else { throw UpdateError("Не удалось скачать обновление (HTTP \(code))") }
            state = .downloading(release, 100)

            guard let sumURL = release.checksumURL else {
                throw UpdateError("В релизе нет контрольной суммы — установка отменена")
            }
            let (sumData, _) = try await UpdateNetwork.session.data(from: sumURL)
            guard let expected = UpdateVerifier.parseChecksum(String(decoding: sumData, as: UTF8.self)) else {
                throw UpdateError("Некорректная контрольная сумма в релизе")
            }
            let actual = try await Self.background { try UpdateVerifier.sha256(of: archive) }
            guard actual == expected else {
                throw UpdateError("Контрольная сумма архива не совпала — установка отменена")
            }

            UpdateLog.write("Распаковка и проверка подписи")
            let bundleID = Bundle.main.bundleIdentifier
            let newApp = try await Self.background { try Self.unpack(archive: archive, in: work) }
            try await Self.background { try Self.verify(newApp: newApp, expected: release.version, bundleID: bundleID) }

            state = .installing(release)
            beforeRestart()
            try launchReplacement(newApp: newApp, log: UpdateLog.url)
            try? await Task.sleep(for: .milliseconds(300))
            UpdateLog.write("Завершение приложения для замены")
            NSApp.terminate(nil)
            // Если штатный выход не сработал — завершаемся сами: скрипт замены ждёт нашего PID.
            try? await Task.sleep(for: .seconds(3))
            exit(0)
        } catch {
            UpdateLog.write("Ошибка: \(error.localizedDescription)")
            state = .failed(error.localizedDescription + "\nЖурнал: ~/Library/Logs/SinVpn/update.log", release)
        }
    }

    private func report(_ fraction: Double, for release: ReleaseInfo) {
        guard case .downloading = state else { return }
        state = .downloading(release, min(99, max(0, Int(fraction * 100))))
    }

    /// Загрузка файла с отчётом о ходе; возвращает код HTTP.
    nonisolated private static func download(
        _ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        final class Box: @unchecked Sendable { var observation: NSKeyValueObservation? }
        let box = Box()
        return try await withCheckedThrowingContinuation { continuation in
            let task = UpdateNetwork.session.downloadTask(with: url) { location, response, error in
                box.observation = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location else {
                    continuation.resume(throwing: UpdateError("Загрузка не вернула файл"))
                    return
                }
                do {
                    // Временный файл нужно забрать до выхода из обработчика.
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: (response as? HTTPURLResponse)?.statusCode ?? 0)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            box.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            task.resume()
        }
    }

    /// Блокирующая работа — на обычной очереди GCD, не в пуле Swift Concurrency.
    nonisolated private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    nonisolated private static func unpack(archive: URL, in work: URL) throws -> URL {
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let newApp = unpacked.appendingPathComponent("SinVpn.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw UpdateError("В архиве не найдено приложение SinVpn")
        }
        return newApp
    }

    nonisolated private static func verify(newApp: URL, expected: AppVersion, bundleID: String?) throws {
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError("Архив содержит другое приложение")
        }
        let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard version == expected else {
            throw UpdateError("Версия в архиве (\(version?.description ?? "?")) не совпадает с релизом \(expected)")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
    }

    /// Запуск внешней утилиты с тайм-аутом.
    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        let name = (tool as NSString).lastPathComponent
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw UpdateError("\(name) не ответил за \(Int(timeout)) с")
        }
        UpdateLog.write("\(name) → код \(p.terminationStatus)")
        guard p.terminationStatus == 0 else {
            throw UpdateError("\(name) завершился с кодом \(p.terminationStatus)")
        }
        return p.terminationStatus
    }

    /// Скрипт ждёт выхода приложения (не дольше 30 с), меняет бандл с откатом при ошибке
    /// и запускает новую версию. Весь вывод — в журнал обновлений.
    private func launchReplacement(newApp: URL, log: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; OLD="$2"; NEW="$3"; LOG="$4"
        exec >>"$LOG" 2>&1
        trap '' HUP
        echo "$(date '+%F %T') скрипт: жду выхода PID $PID"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          i=$((i+1))
          if [ $i -gt 150 ]; then echo "приложение не вышло за 30 с — завершаю"; kill -9 "$PID"; sleep 1; fi
          sleep 0.2
        done
        BACKUP="$OLD.sinvpn-previous"
        rm -rf "$BACKUP"
        if mv "$OLD" "$BACKUP"; then
          if mv "$NEW" "$OLD" || ditto "$NEW" "$OLD"; then
            rm -rf "$BACKUP"
            xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
            echo "$(date '+%F %T') скрипт: новая версия установлена"
          else
            echo "$(date '+%F %T') скрипт: замена не удалась, возвращаю прежнюю версию"
            rm -rf "$OLD"; mv "$BACKUP" "$OLD"
          fi
        else
          echo "$(date '+%F %T') скрипт: не удалось убрать старую версию"
        fi
        open "$OLD"
        """
        let scriptURL = newApp.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                       Self.installURL.path, newApp.path, log.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        UpdateLog.write("Скрипт замены запущен, PID \(p.processIdentifier)")
    }
}

/// Сетевая сессия обновлений — вне главного актора, чтобы ею могла пользоваться фоновая загрузка.
enum UpdateNetwork {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": "SinVpn-Updater"]
        return URLSession(configuration: config)
    }()
}

/// Журнал обновлений: ~/Library/Logs/SinVpn/update.log
enum UpdateLog {
    static var url: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/SinVpn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("update.log")
    }

    static func write(_ line: String) {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let data = Data("\(stamp) \(line)\n".utf8)
        let url = url
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
