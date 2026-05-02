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
  targets: [
    .executableTarget(
      name: "CodexWeeklyReset",
      path: "Sources/CodexWeeklyReset"
    ),
    .testTarget(
      name: "CodexWeeklyResetTests",
      dependencies: ["CodexWeeklyReset"],
      path: "Tests/CodexWeeklyResetTests"
    )
  ]
)
