import Foundation
import Darwin

public struct InterfaceCounters: Equatable, Sendable {
    public var rx: UInt64
    public var tx: UInt64

    public init(rx: UInt64 = 0, tx: UInt64 = 0) {
        self.rx = rx
        self.tx = tx
    }
}

/// Превращает абсолютные счётчики интерфейсов в приращения между замерами.
public struct TrafficMeter: Sendable {
    private var last: [String: InterfaceCounters] = [:]

    public init() {}

    /// - Новый интерфейс: первый замер — точка отсчёта, приращение 0.
    /// - Счётчик уменьшился (интерфейс пересоздан): считаем от нуля.
    /// - Интерфейс пропал из замера: забываем его.
    public mutating func sample(_ current: [String: InterfaceCounters]) -> InterfaceCounters {
        var delta = InterfaceCounters()
        for (name, now) in current {
            guard let before = last[name] else { continue }
            delta.rx += now.rx >= before.rx ? now.rx - before.rx : now.rx
            delta.tx += now.tx >= before.tx ? now.tx - before.tx : now.tx
        }
        last = current
        return delta
    }

    public mutating func reset() {
        last = [:]
    }
}

/// Чтение сетевых интерфейсов системы.
public enum InterfaceReader {
    /// Интерфейсы, которые создают VPN-туннели.
    public static func isTunnelName(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { prefix in
            name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy(\.isNumber)
                && name.count > prefix.count
        }
    }

    /// 64-битные счётчики байтов по всем интерфейсам (sysctl NET_RT_IFLIST2).
    public static func counters() -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: InterfaceCounters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        result[String(cString: name)] = InterfaceCounters(
                            rx: info.ifm_data.ifi_ibytes,
                            tx: info.ifm_data.ifi_obytes
                        )
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    /// Поднятые туннельные интерфейсы с IPv4-адресом. Системные utun (iCloud, Continuity)
    /// имеют только IPv6 link-local и сюда не попадают.
    public static func activeTunnelInterfaces() -> Set<String> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var names = Set<String>()
        var cursor = list
        while let entry = cursor {
            let ifa = entry.pointee
            if let address = ifa.ifa_addr,
               Int32(address.pointee.sa_family) == AF_INET,
               ifa.ifa_flags & UInt32(IFF_UP) != 0 {
                let name = String(cString: ifa.ifa_name)
                if isTunnelName(name) { names.insert(name) }
            }
            cursor = ifa.ifa_next
        }
        return names
    }
}
