import Foundation

public struct DayStats: Codable, Equatable, Sendable {
    public var seconds: Double
    public var rx: UInt64
    public var tx: UInt64

    public init(seconds: Double = 0, rx: UInt64 = 0, tx: UInt64 = 0) {
        self.seconds = seconds
        self.rx = rx
        self.tx = tx
    }
}

/// Суточные итоги времени в VPN и трафика. Хранится локально, не дольше 90 дней.
public struct StatsStore: Codable, Equatable, Sendable {
    public static let retentionDays = 90

    public private(set) var days: [String: DayStats] = [:]

    public init() {}

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func add(seconds: Double, rx: UInt64, tx: UInt64, at date: Date, calendar: Calendar = .current) {
        let key = Self.key(for: date, calendar: calendar)
        var day = days[key] ?? DayStats()
        day.seconds += max(0, seconds)
        day.rx += rx
        day.tx += tx
        days[key] = day
    }

    /// Сумма за последние `count` календарных дней, включая день `date`.
    public func total(days count: Int, endingAt date: Date, calendar: Calendar = .current) -> DayStats {
        var sum = DayStats()
        for back in 0..<max(0, count) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: date),
                  let stats = days[Self.key(for: day, calendar: calendar)] else { continue }
            sum.seconds += stats.seconds
            sum.rx += stats.rx
            sum.tx += stats.tx
        }
        return sum
    }

    public mutating func prune(now: Date, calendar: Calendar = .current) {
        guard let oldest = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: now) else { return }
        let cutoff = Self.key(for: oldest, calendar: calendar)
        days = days.filter { $0.key >= cutoff }
    }

    public mutating func reset() {
        days = [:]
    }

    // MARK: - Файл

    public static func load(from url: URL) -> StatsStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(StatsStore.self, from: data) else { return StatsStore() }
        return store
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
