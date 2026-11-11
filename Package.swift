// swift-tools-version:5.10
import PackageDescription

// Минимальная версия системы для запуска (macOS 27) задаётся в Info.plist (scripts/build-app.sh).
// Здесь — минимальная версия SDK, с которой пакет компилируется.
let package = Package(
    name: "SinVpn",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SinVpn", targets: ["SinVpn"]),
        .library(name: "SinVpnCore", targets: ["SinVpnCore"]),
    ],
    targets: [
        .target(name: "SinVpnCore"),
        .executableTarget(name: "SinVpn", dependencies: ["SinVpnCore"]),
        .testTarget(name: "SinVpnCoreTests", dependencies: ["SinVpnCore"]),
    ]
)
