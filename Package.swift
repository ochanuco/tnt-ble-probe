// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bc768-probe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "bc768-probe", targets: ["BC768Probe"]),
        .executable(name: "bc768-app", targets: ["BC768App"]),
    ],
    targets: [
        // CoreBluetooth に依存しない BC-768 独自プロトコル層。
        .target(name: "BC768Protocol", path: "Sources/BC768Protocol"),
        // CoreBluetooth を使うセッション層。CLI と GUI の両方から使う。
        .target(
            name: "BC768BLE",
            dependencies: ["BC768Protocol"],
            path: "Sources/BC768BLE",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BC768Probe",
            dependencies: ["BC768Protocol", "BC768BLE"],
            path: "Sources/BC768Probe",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // CoreBluetooth を CLI から使うには TCC 用の usage description が必要なので、
                // Info.plist を __TEXT,__info_plist セクションへ埋め込む。
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/BC768Probe/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "BC768App",
            dependencies: ["BC768Protocol", "BC768BLE"],
            path: "Sources/BC768App",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // GUI からも CoreBluetooth を使うため、TCC 用の usage description を埋め込む。
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/BC768App/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "BC768ProtocolTests",
            dependencies: ["BC768Protocol"],
            path: "Tests/BC768ProtocolTests"
        )
    ]
)
