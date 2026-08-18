// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bc768-probe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "bc768-probe", targets: ["BC768Probe"])
    ],
    targets: [
        // CoreBluetooth に依存しない BC-768 独自プロトコル層。
        .target(name: "BC768Protocol", path: "Sources/BC768Protocol"),
        .executableTarget(
            name: "BC768Probe",
            dependencies: ["BC768Protocol"],
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
        .testTarget(
            name: "BC768ProtocolTests",
            dependencies: ["BC768Protocol"],
            path: "Tests/BC768ProtocolTests"
        )
    ]
)
