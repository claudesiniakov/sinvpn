import XCTest
@testable import SinVpnCore

final class ScutilParserTests: XCTestCase {
    func testParsesServiceList() {
        let output = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   1A2B3C4D-0000-1111-2222-333344445555 IPSec              "Рабочий (IKEv2)"                [IPSec]
        * (Connected)      aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee VPN (com.wireguard.macos) "WireGuard — Амстердам"   [VPN:com.wireguard.macos]
          (Connecting)     99999999-0000-1111-2222-333344445555 PPP --> L2TP       "Архив \\"старый\\""             [PPP:L2TP]
        """
        let list = ScutilParser.parseList(output)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].name, "Рабочий (IKEv2)")
        XCTAssertEqual(list[0].status, .disconnected)
        XCTAssertEqual(list[0].kind, "IPSec")
        XCTAssertTrue(list[0].enabled)
        XCTAssertEqual(list[1].id, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(list[1].status, .connected)
        XCTAssertEqual(list[1].kind, "VPN (com.wireguard.macos)")
        XCTAssertEqual(list[2].status, .connecting)
        XCTAssertFalse(list[2].enabled)
        XCTAssertEqual(list[2].kind, "PPP --> L2TP")
    }

    func testIgnoresGarbageAndDuplicates() {
        XCTAssertTrue(ScutilParser.parseList("").isEmpty)
        XCTAssertTrue(ScutilParser.parseList("No services\n\n").isEmpty)
        let twice = """
        * (Disconnected)   1A2B3C4D-0000-1111-2222-333344445555 IPSec "A" [IPSec]
        * (Disconnected)   1a2b3c4d-0000-1111-2222-333344445555 IPSec "A" [IPSec]
        * (Weird)          2A2B3C4D-0000-1111-2222-333344445555 IPSec "B"
        """
        let list = ScutilParser.parseList(twice)
        XCTAssertEqual(list.map(\.name), ["A", "B"])
        XCTAssertEqual(list[1].status, .invalid)
    }
}

final class ConnectAttemptTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testSuccess() {
        let a = ConnectAttempt(startedAt: t0)
        XCTAssertEqual(a.evaluate(status: .connected, now: t0.addingTimeInterval(2)), .succeeded)
    }

    func testStaysPendingUntilTimeout() {
        let a = ConnectAttempt(startedAt: t0)
        XCTAssertEqual(a.evaluate(status: .disconnected, now: t0.addingTimeInterval(3)), .pending(a))
        XCTAssertEqual(a.evaluate(status: .disconnected, now: t0.addingTimeInterval(10)), .failed)
    }

    func testFailsWhenDropsBackAfterConnecting() {
        let a = ConnectAttempt(startedAt: t0)
        guard case let .pending(b) = a.evaluate(status: .connecting, now: t0.addingTimeInterval(1)) else {
            return XCTFail("ожидалось pending")
        }
        XCTAssertTrue(b.sawConnecting)
        XCTAssertEqual(b.evaluate(status: .disconnected, now: t0.addingTimeInterval(2)), .failed)
    }
}

final class TrafficMeterTests: XCTestCase {
    func testDeltasBaselineAndReset() {
        var meter = TrafficMeter()
        // Первый замер — точка отсчёта.
        XCTAssertEqual(meter.sample(["utun4": .init(rx: 1000, tx: 100)]), .init())
        XCTAssertEqual(meter.sample(["utun4": .init(rx: 1500, tx: 130)]), .init(rx: 500, tx: 30))
        // Счётчик обнулился: интерфейс пересоздан.
        XCTAssertEqual(meter.sample(["utun4": .init(rx: 40, tx: 5)]), .init(rx: 40, tx: 5))
        // Появился второй интерфейс — его первый замер не учитывается.
        XCTAssertEqual(
            meter.sample(["utun4": .init(rx: 50, tx: 5), "ipsec0": .init(rx: 9_000, tx: 9_000)]),
            .init(rx: 10, tx: 0)
        )
        // Пропавший интерфейс забыт: после возврата снова точка отсчёта.
        _ = meter.sample(["ipsec0": .init(rx: 9_100, tx: 9_000)])
        XCTAssertEqual(meter.sample(["utun4": .init(rx: 70, tx: 5), "ipsec0": .init(rx: 9_200, tx: 9_001)]),
                       .init(rx: 100, tx: 1))
        meter.reset()
        XCTAssertEqual(meter.sample(["ipsec0": .init(rx: 10_000, tx: 10_000)]), .init())
    }

    func testCountersAboveFourGigabytes() {
        var meter = TrafficMeter()
        _ = meter.sample(["utun4": .init(rx: 4_294_967_000, tx: 0)])
        XCTAssertEqual(meter.sample(["utun4": .init(rx: 4_294_968_000, tx: 0)]).rx, 1000)
    }

    func testTunnelNames() {
        XCTAssertTrue(InterfaceReader.isTunnelName("utun4"))
        XCTAssertTrue(InterfaceReader.isTunnelName("ipsec0"))
        XCTAssertTrue(InterfaceReader.isTunnelName("ppp0"))
        XCTAssertFalse(InterfaceReader.isTunnelName("en0"))
        XCTAssertFalse(InterfaceReader.isTunnelName("utun"))
        XCTAssertFalse(InterfaceReader.isTunnelName("lo0"))
    }

    func testReadsSystemCounters() {
        // На любой машине есть хотя бы lo0.
        XCTAssertNotNil(InterfaceReader.counters()["lo0"])
    }
}

final class StatsStoreTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func testTotalsByPeriod() {
        var store = StatsStore()
        store.add(seconds: 60, rx: 1000, tx: 100, at: date(11), calendar: calendar)
        store.add(seconds: 30, rx: 500, tx: 50, at: date(11, hour: 23), calendar: calendar)
        store.add(seconds: 600, rx: 9000, tx: 900, at: date(10), calendar: calendar)
        store.add(seconds: 5, rx: 1, tx: 1, at: calendar.date(byAdding: .day, value: -30, to: date(11))!, calendar: calendar)

        XCTAssertEqual(StatsStore.key(for: date(11), calendar: calendar), "2026-11-11")
        XCTAssertEqual(store.total(days: 1, endingAt: date(11), calendar: calendar), DayStats(seconds: 90, rx: 1500, tx: 150))
        // 30 дней включают сегодняшний и не включают 31-й день назад.
        XCTAssertEqual(store.total(days: 30, endingAt: date(11), calendar: calendar), DayStats(seconds: 690, rx: 10500, tx: 1050))
    }

    func testPruneResetAndFile() throws {
        var store = StatsStore()
        store.add(seconds: 1, rx: 1, tx: 1, at: date(11), calendar: calendar)
        let old = calendar.date(byAdding: .day, value: -90, to: date(11))!
        let edge = calendar.date(byAdding: .day, value: -89, to: date(11))!
        store.add(seconds: 1, rx: 1, tx: 1, at: old, calendar: calendar)
        store.add(seconds: 1, rx: 1, tx: 1, at: edge, calendar: calendar)
        store.prune(now: date(11), calendar: calendar)
        XCTAssertEqual(store.days.count, 2)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sinvpn-tests-\(UUID().uuidString)/stats.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try store.save(to: url)
        XCTAssertEqual(StatsStore.load(from: url), store)
        XCTAssertEqual(StatsStore.load(from: url.appendingPathExtension("missing")), StatsStore())

        store.reset()
        XCTAssertTrue(store.days.isEmpty)
    }
}

final class FormattingTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(ByteFormat.string(0), "0 КБ")
        XCTAssertEqual(ByteFormat.string(512_000), "512 КБ")
        XCTAssertEqual(ByteFormat.string(27_900_000), "27,9 МБ")
        XCTAssertEqual(ByteFormat.string(1_400_000_000), "1,4 ГБ")
    }

    func testDurations() {
        XCTAssertEqual(DurationFormat.clock(754), "00:12:34")
        XCTAssertEqual(DurationFormat.clock(36_000 + 61), "10:01:01")
        XCTAssertEqual(DurationFormat.short(5100), "1 ч 25 мин")
        XCTAssertEqual(DurationFormat.short(59), "0 мин")
        XCTAssertEqual(DurationFormat.short(1500), "25 мин")
    }
}

final class UpdateTests: XCTestCase {
    func testVersionComparison() throws {
        let v = { (s: String) in try XCTUnwrap(AppVersion(s)) }
        XCTAssertLessThan(try v("0.9.1"), try v("0.10.0"))
        XCTAssertEqual(try v("v1.0"), try v("1.0.0"))
        XCTAssertEqual(try v("1.2.0-beta").description, "1.2.0")
        XCTAssertNil(AppVersion("f1700b2"))
    }

    func testParseGitHubRelease() throws {
        let json = """
        {
          "tag_name": "v1.1.0",
          "name": "SinVpn 1.1.0",
          "body": "* Исправления",
          "html_url": "https://github.com/claudesiniakov/sinvpn/releases/tag/v1.1.0",
          "published_at": "2026-11-11T08:00:00Z",
          "assets": [
            {"name": "SinVpn.zip", "size": 720000,
             "browser_download_url": "https://github.com/claudesiniakov/sinvpn/releases/download/v1.1.0/SinVpn.zip"},
            {"name": "SinVpn.zip.sha256", "size": 78,
             "browser_download_url": "https://github.com/claudesiniakov/sinvpn/releases/download/v1.1.0/SinVpn.zip.sha256"}
          ]
        }
        """
        let r = try ReleaseFeed.parse(Data(json.utf8))
        XCTAssertEqual(r.version, AppVersion("1.1.0"))
        XCTAssertEqual(r.archiveSize, 720_000)
        XCTAssertNotNil(r.checksumURL)
    }

    func testRejectsForeignDownloads() {
        let foreign = """
        {"tag_name": "v9.9.9", "html_url": "https://github.com/x/y", "assets": [
          {"name": "SinVpn.zip", "browser_download_url": "https://evil.example.com/SinVpn.zip"}]}
        """
        XCTAssertThrowsError(try ReleaseFeed.parse(Data(foreign.utf8))) {
            XCTAssertEqual($0 as? ReleaseFeedError, .noArchive)
        }
        XCTAssertThrowsError(try ReleaseFeed.parse(Data("not json".utf8)))
    }

    func testChecksum() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sinvpn-sum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let sum = try UpdateVerifier.sha256(of: url)
        XCTAssertEqual(sum, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(UpdateVerifier.parseChecksum("\(sum)  SinVpn.zip\n"), sum)
        XCTAssertNil(UpdateVerifier.parseChecksum("xyz  SinVpn.zip"))
    }
}
