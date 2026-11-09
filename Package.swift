// swift-tools-version:5.9
import PackageDescription
import Foundation

// Info.plist is embedded into the binary so macOS can show the Calendar permission prompt.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "Nordpult",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nordpult",
            path: "Sources/Nordpult",
            resources: [.copy("web")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("SystemConfiguration"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
    ]
)
