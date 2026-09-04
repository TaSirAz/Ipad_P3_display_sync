// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "iPadDisplay V7.1",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "iPadDisplay V7.1",
            targets: ["AppModule"],
            bundleIdentifier: "local.iPadDisplayV7.Native",
            displayVersion: "7.2",
            bundleVersion: "2",
            appIcon: .placeholder(icon: .pencil),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad
            ],
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft
            ],
            additionalInfoPlistContentFilePath: "AppInfo.plist"
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            exclude: [
                "Package.swift",
                "AppInfo.plist",
                "Info.plist",
                "HOW_TO_INSTALL.txt"
            ]
        )
    ]
)
