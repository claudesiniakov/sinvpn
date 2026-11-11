import Foundation
import CryptoKit

/// Номер версии вида `1.2.3` (префикс `v` и суффиксы вроде `-beta` игнорируются при сравнении).
public struct AppVersion: Comparable, CustomStringConvertible, Sendable, Hashable {
    public let components: [Int]

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let dash = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<dash]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var nums: [Int] = []
        for p in parts {
            guard let n = Int(p), n >= 0 else { return nil }
            nums.append(n)
        }
        guard !nums.isEmpty else { return nil }
        while nums.count > 1, nums.last == 0 { nums.removeLast() }
        components = nums
    }

    public var description: String {
        var c = components
        while c.count < 3 { c.append(0) }
        return c.map(String.init).joined(separator: ".")
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

public struct ReleaseInfo: Sendable, Equatable {
    public let version: AppVersion
    public let tag: String
    public let title: String
    public let notes: String
    public let publishedAt: Date?
    public let pageURL: URL
    public let archiveURL: URL
    public let archiveSize: Int64
    public let checksumURL: URL?
}

public enum ReleaseFeedError: LocalizedError, Equatable {
    case invalidResponse
    case noArchive
    case badVersion(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Сервер обновлений вернул неожиданный ответ"
        case .noArchive: return "В релизе нет архива SinVpn.zip"
        case let .badVersion(tag): return "Не удалось разобрать номер версии «\(tag)»"
        }
    }
}

/// Лента обновлений — последний релиз репозитория на GitHub.
public enum ReleaseFeed {
    public static let owner = "claudesiniakov"
    public static let repo = "sinvpn"
    public static let archiveName = "SinVpn.zip"

    public static var latestURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    public static var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    }

    private struct Release: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let published_at: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64?
    }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let r = try? JSONDecoder().decode(Release.self, from: data),
              let page = URL(string: r.html_url) else { throw ReleaseFeedError.invalidResponse }
        guard let version = AppVersion(r.tag_name) else { throw ReleaseFeedError.badVersion(r.tag_name) }
        guard let zip = r.assets.first(where: { $0.name == archiveName }),
              let zipURL = URL(string: zip.browser_download_url), isTrustedDownload(zipURL)
        else { throw ReleaseFeedError.noArchive }
        let sum = r.assets.first { $0.name == archiveName + ".sha256" }
            .flatMap { URL(string: $0.browser_download_url) }
            .flatMap { isTrustedDownload($0) ? $0 : nil }
        return ReleaseInfo(
            version: version,
            tag: r.tag_name,
            title: (r.name?.isEmpty == false ? r.name! : "SinVpn \(version)"),
            notes: r.body ?? "",
            publishedAt: r.published_at.flatMap { ISO8601DateFormatter().date(from: $0) },
            pageURL: page,
            archiveURL: zipURL,
            archiveSize: zip.size ?? 0,
            checksumURL: sum
        )
    }

    /// Скачиваем только по HTTPS с github.com.
    public static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(owner)/\(repo)/releases/download/")
    }
}

public enum UpdateVerifier {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Извлекает хэш из строки формата `shasum`: `<64 hex>  SinVpn.zip`.
    public static func parseChecksum(_ text: String) -> String? {
        guard let token = text.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let hex = token.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}
