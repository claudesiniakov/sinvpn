import Foundation

/// Объём трафика: КБ / МБ / ГБ, одна цифра после запятой («1,4 ГБ»).
public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b >= 1e9 { return number(b / 1e9) + " ГБ" }
        if b >= 1e6 { return number(b / 1e6) + " МБ" }
        return number(b / 1e3) + " КБ"
    }

    static func number(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}

public enum DurationFormat {
    /// «чч:мм:сс» — для текущей сессии.
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    /// «1 ч 25 мин» / «25 мин» — для итогов за день и за 30 дней.
    public static func short(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = s % 3600 / 60
        return h > 0 ? "\(h) ч \(m) мин" : "\(m) мин"
    }
}
