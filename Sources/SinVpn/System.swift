import Foundation
import SystemConfiguration

/// Запуск системных утилит вне главного потока.
enum Shell {
    struct Result: Sendable {
        let code: Int32
        let output: String
        let timedOut: Bool
    }

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(code: -1, output: "", timedOut: false))
                    return
                }
                let timedOut = Flag()
                let killer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                    // Если процесс игнорирует мягкое завершение — через 2 с завершаем принудительно.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: Result(
                    code: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self),
                    timedOut: timedOut.value
                ))
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func set() { lock.lock(); raised = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }
}

/// Управление системными VPN через `scutil --nc` — тот же механизм, что у «Системных настроек».
enum VPNControl {
    private static let scutil = "/usr/sbin/scutil"

    static func list() async -> Shell.Result {
        await Shell.run(scutil, ["--nc", "list"], timeout: 5)
    }

    static func start(_ id: String) async -> Shell.Result {
        await Shell.run(scutil, ["--nc", "start", id], timeout: 30)
    }

    static func stop(_ id: String) async -> Shell.Result {
        await Shell.run(scutil, ["--nc", "stop", id], timeout: 15)
    }
}

/// Подписка на изменения сети в SCDynamicStore: срабатывает, когда VPN включили или выключили
/// где угодно в системе.
final class NetworkWatcher {
    private var store: SCDynamicStore?
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        store = SCDynamicStoreCreate(nil, "SinVpn" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }, &context)
        guard let store else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Interface"]
        let patterns = ["State:/Network/Service/.*/(IPv4|IPv6|PPP|IPSec|VPN)"]
        SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray)
        SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main)
    }

    /// Имя сетевого интерфейса службы (utun4, ipsec0, ppp0), если система его публикует.
    func interfaceName(serviceID: String) -> String? {
        guard let store else { return nil }
        for entity in ["IPv4", "IPv6"] {
            for id in [serviceID, serviceID.lowercased()] {
                let key = "State:/Network/Service/\(id)/\(entity)" as CFString
                if let value = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                   let name = value["InterfaceName"] as? String, !name.isEmpty {
                    return name
                }
            }
        }
        return nil
    }
}
