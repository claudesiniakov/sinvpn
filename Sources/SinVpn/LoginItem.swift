import Foundation

/// Автозапуск при входе в систему через агент запуска пользователя.
/// Запись привязана к пути приложения, а не к его подписи, поэтому переживает обновления.
@MainActor
enum LoginItem {
    static let label = "com.claudesiniakov.sinvpn.login"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var executablePath: String {
        Updater.installURL.appendingPathComponent("Contents/MacOS/SinVpn").path
    }

    private static var registeredPath: String? {
        guard let plist = NSDictionary(contentsOf: plistURL),
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    static var isEnabled: Bool { registeredPath != nil }

    static func enable() throws {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        if let bundleID = Bundle.main.bundleIdentifier {
            // Чтобы в «Объектах входа» запись показывалась под именем приложения.
            plist["AssociatedBundleIdentifiers"] = [bundleID]
        }
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    static func disable() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    /// Приложение переместили — обновляем путь в записи автозапуска.
    static func repairIfMoved() {
        guard let registered = registeredPath, registered != executablePath else { return }
        try? enable()
    }
}
