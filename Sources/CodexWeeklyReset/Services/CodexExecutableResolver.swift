import AppKit
import Foundation
import Darwin

struct CodexExecutable: Equatable {
  let path: String
  let source: String
}

struct CodexExecutableResolver {
  var configuredPath: String?
  var commandPathProvider: () async -> String?
  var fileIsExecutable: (String) -> Bool
  var homeDirectory: URL
  var launchServicesAppURLProvider: () -> URL?
  var includeFallbacks: Bool

  init(
    configuredPath: String? = nil,
    commandPathProvider: @escaping () async -> String? = { await Self.commandPath("codex") },
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

  func resolve() async -> CodexExecutable? {
    if let configuredPath = configuredPath?.expandingTilde(with: homeDirectory.path),
       fileIsExecutable(configuredPath) {
      return CodexExecutable(path: configuredPath, source: "Configured")
    }

    guard includeFallbacks else {
      return nil
    }

    if let commandPath = await commandPathProvider(),
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

  static func commandPath(_ command: String) async -> String? {
    await commandOutput(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["bash", "-lc", "command -v \(command)"],
      timeout: 2
    )
  }

  // Login profiles can block or write to either pipe. Keep discovery off the
  // main actor and drain both streams while enforcing one wall-clock deadline.
  static func commandOutput(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval
  ) async -> String? {
    await Task.detached(priority: .utility) {
      let process = Process()
      let output = Pipe()
      let errors = Pipe()
      process.executableURL = executableURL
      process.arguments = arguments
      process.standardOutput = output
      process.standardError = errors
      process.standardInput = FileHandle.nullDevice

      let handles = [output.fileHandleForReading, errors.fileHandleForReading]
      defer { handles.forEach { $0.closeFile() } }
      for handle in handles {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
          return nil
        }
      }
      do {
        try process.run()
      } catch {
        return nil
      }

      let boundedTimeout = timeout.isFinite ? min(30, max(0.05, timeout)) : 2
      let deadline = ProcessInfo.processInfo.systemUptime + boundedTimeout
      var data = Data()
      var outputTooLarge = false
      var openStreams = [true, true]
      var buffer = [UInt8](repeating: 0, count: 16_384)

      func drain() {
        // Bound each pass so a continuously noisy child cannot starve timeout
        // checks or the other stream. Discard stderr and cap captured stdout.
        for (index, handle) in handles.enumerated() where openStreams[index] {
          for _ in 0..<4 {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else {
              if count == 0 || (errno != EAGAIN && errno != EINTR) {
                openStreams[index] = false
              }
              break
            }
            if index == 0 {
              if data.count + count <= 65_536 {
                data.append(contentsOf: buffer.prefix(count))
              } else {
                outputTooLarge = true
              }
            }
          }
        }
      }

      while true {
        drain()
        if !process.isRunning {
          drain()
          guard process.terminationStatus == 0, !outputTooLarge else { return nil }
          return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        }
        if ProcessInfo.processInfo.systemUptime >= deadline {
          // Only this discovery process belongs to us; never signal a shell's
          // process group, which may contain independently launched work.
          kill(process.processIdentifier, SIGKILL)
          process.waitUntilExit()
          return nil
        }
        var descriptors = handles.enumerated().compactMap { index, handle in
          openStreams[index]
            ? pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            : nil
        }
        _ = poll(&descriptors, nfds_t(descriptors.count), 25)
      }
    }.value
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
