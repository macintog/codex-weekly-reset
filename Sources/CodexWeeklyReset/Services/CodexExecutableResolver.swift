import AppKit
import Foundation

struct CodexExecutable: Equatable {
  let path: String
  let source: String
}

struct CodexExecutableResolver {
  var configuredPath: String?
  var commandPathProvider: () -> String?
  var fileIsExecutable: (String) -> Bool
  var homeDirectory: URL
  var launchServicesAppURLProvider: () -> URL?
  var includeFallbacks: Bool

  init(
    configuredPath: String? = nil,
    commandPathProvider: @escaping () -> String? = { Self.commandPath("codex") },
    fileIsExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    includeFallbacks: Bool = true,
    launchServicesAppURLProvider: @escaping () -> URL? = {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
    }
  ) {
    self.configuredPath = configuredPath
    self.commandPathProvider = commandPathProvider
    self.fileIsExecutable = fileIsExecutable
    self.homeDirectory = homeDirectory
    self.includeFallbacks = includeFallbacks
    self.launchServicesAppURLProvider = launchServicesAppURLProvider
  }

  func resolve() -> CodexExecutable? {
    if let configuredPath = configuredPath?.expandingTilde(with: homeDirectory.path),
       fileIsExecutable(configuredPath) {
      return CodexExecutable(path: configuredPath, source: "Configured")
    }

    guard includeFallbacks else {
      return nil
    }

    if let commandPath = commandPathProvider(),
       fileIsExecutable(commandPath) {
      return CodexExecutable(path: commandPath, source: "PATH")
    }

    let applicationPath = "/Applications/Codex.app/Contents/Resources/codex"
    if fileIsExecutable(applicationPath) {
      return CodexExecutable(path: applicationPath, source: "/Applications")
    }

    let userApplicationPath = homeDirectory
      .appendingPathComponent("Applications/Codex.app/Contents/Resources/codex")
      .path
    if fileIsExecutable(userApplicationPath) {
      return CodexExecutable(path: userApplicationPath, source: "~/Applications")
    }

    if let appURL = launchServicesAppURLProvider() {
      let codexPath = appURL.appendingPathComponent("Contents/Resources/codex").path
      if fileIsExecutable(codexPath) {
        return CodexExecutable(path: codexPath, source: "LaunchServices")
      }
    }

    return nil
  }

  static func commandPath(_ command: String) -> String? {
    let process = Process()
    let output = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bash", "-lc", "command -v \(command)"]
    process.standardOutput = output
    process.standardError = Pipe()

    do {
      try process.run()
    } catch {
      return nil
    }

    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      return nil
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmpty
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }

  func expandingTilde(with homePath: String) -> String {
    guard hasPrefix("~/") else {
      return self
    }
    return homePath + dropFirst(1)
  }
}
