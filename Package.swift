// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "CodexWeeklyReset",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "CodexWeeklyReset", targets: ["CodexWeeklyReset"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
  ],
  targets: [
    .executableTarget(
      name: "CodexWeeklyReset",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ],
      path: "Sources/CodexWeeklyReset",
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-rpath",
          "-Xlinker", "@executable_path/../Frameworks"
        ])
      ]
    ),
    .testTarget(
      name: "CodexWeeklyResetTests",
      dependencies: [
        "CodexWeeklyReset",
        .product(name: "Sparkle", package: "Sparkle")
      ],
      path: "Tests/CodexWeeklyResetTests",
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-rpath",
          "-Xlinker", "@loader_path/../../.."
        ])
      ]
    )
  ]
)
