import Foundation

public enum VPNStatus: String, Sendable, Equatable {
    case disconnected, connecting, connected, disconnecting, invalid

    init(scutil raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "connected": self = .connected
        case "connecting": self = .connecting
        case "disconnecting": self = .disconnecting
        case "disconnected": self = .disconnected
        default: self = .invalid
        }
    }
}

/// VPN-подключение из «Системных настроек».
public struct VPNService: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// Тип, как его печатает система: «IPSec», «PPP --> L2TP», «VPN (com.wireguard.macos)».
    public let kind: String
    public let enabled: Bool
    public var status: VPNStatus

    public init(id: String, name: String, kind: String, enabled: Bool, status: VPNStatus) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.status = status
    }
}

/// Разбор вывода `scutil --nc list`. Строка службы выглядит так:
/// `* (Connected)   <UUID> VPN (com.wireguard.macos) "Дом"   [VPN:com.wireguard.macos]`
public enum ScutilParser {
    private static let line = try! NSRegularExpression(
        pattern: #"^(\*|\s)\s*\(([^)]*)\)\s+([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\s+(.*?)\s*"(.*)"\s*(?:\[.*\])?\s*$"#
    )

    private static let uuid = try! NSRegularExpression(
        pattern: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
    )

    /// В выводе есть идентификаторы служб. Если при этом `parseList` ничего не разобрал,
    /// значит, изменился формат вывода — это ошибка чтения, а не «VPN не настроен».
    public static func mentionsServices(_ output: String) -> Bool {
        uuid.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) != nil
    }

    public static func parseList(_ output: String) -> [VPNService] {
        var result: [VPNService] = []
        var seen = Set<String>()
        for raw in output.split(whereSeparator: \.isNewline) {
            let text = String(raw)
            let range = NSRange(text.startIndex..., in: text)
            guard let m = line.firstMatch(in: text, range: range) else { continue }
            func group(_ i: Int) -> String {
                Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
            let id = group(3).uppercased()
            guard seen.insert(id).inserted else { continue }
            result.append(VPNService(
                id: id,
                name: group(5),
                kind: group(4),
                enabled: group(1) == "*",
                status: VPNStatus(scutil: group(2))
            ))
        }
        return result
    }
}

/// Попытка подключения, начатая из приложения: по ней определяется «Не удалось подключиться».
public struct ConnectAttempt: Equatable, Sendable {
    public var startedAt: Date
    public var sawConnecting: Bool

    public init(startedAt: Date, sawConnecting: Bool = false) {
        self.startedAt = startedAt
        self.sawConnecting = sawConnecting
    }

    public enum Outcome: Equatable, Sendable {
        case pending(ConnectAttempt)
        case succeeded
        case failed
    }

    /// Сколько ждать перехода в «Подключение…», прежде чем считать попытку неудачной.
    public static let startTimeout: TimeInterval = 10

    public func evaluate(status: VPNStatus, now: Date) -> Outcome {
        switch status {
        case .connected:
            return .succeeded
        case .connecting, .disconnecting:
            var next = self
            next.sawConnecting = true
            return .pending(next)
        case .disconnected, .invalid:
            if sawConnecting || now.timeIntervalSince(startedAt) >= Self.startTimeout { return .failed }
            return .pending(self)
        }
    }
}
