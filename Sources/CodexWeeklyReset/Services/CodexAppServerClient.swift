import Foundation
import os

actor CodexAppServerClient {
  private let executablePath: String
  private let requestTimeout: TimeInterval
  private let logger = Logger(subsystem: "com.macintog.codexweeklyreset", category: "CodexAppServerClient")
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  private var process: Process?
  private var inputHandle: FileHandle?
  private var stdoutHandle: FileHandle?
  private var stderrHandle: FileHandle?
  private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
  private var nextId = 1
  private var updateHandler: ((RateLimitsEnvelope) -> Void)?
  private var stdoutBuffer = Data()
  private var stderrTail = Data()
  private let maxStderrTailBytes = 8 * 1024

  init(executablePath: String, requestTimeout: TimeInterval = 8) {
    self.executablePath = executablePath
    self.requestTimeout = requestTimeout
  }

  func setRateLimitUpdateHandler(_ handler: ((RateLimitsEnvelope) -> Void)?) {
    updateHandler = handler
  }

  func start() async throws {
    if let process, process.isRunning {
      return
    }

    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()

    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = ["app-server"]
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    process.environment = Self.sanitizedEnvironment()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    process.terminationHandler = { [weak self] process in
      Task { await self?.processDidExit(status: process.terminationStatus) }
    }

    logger.info("Starting codex app-server at \(self.executablePath, privacy: .public)")
    try process.run()
    logger.info("Started codex app-server pid \(process.processIdentifier, privacy: .public)")

    self.process = process
    self.inputHandle = stdin.fileHandleForWriting
    self.stdoutHandle = stdout.fileHandleForReading
    self.stderrHandle = stderr.fileHandleForReading
    self.stdoutBuffer.removeAll(keepingCapacity: true)
    self.stderrTail.removeAll(keepingCapacity: true)
    installReadabilityHandlers(
      stdout: stdout.fileHandleForReading,
      stderr: stderr.fileHandleForReading
    )

    let initialize = InitializeRequest(
      id: nextRequestId(),
      params: InitializeParams(
        clientInfo: ClientInfo(
          name: "codex_weekly_reset",
          title: "Codex Weekly Reset",
          version: BuildIdentity.current.displayText
        )
      )
    )
    _ = try await sendRequest(initialize, resultType: EmptyDecodable.self)
    try sendNotification(InitializedNotification())
  }

  func readRateLimits() async throws -> RateLimitsEnvelope {
    try await start()
    let request = EmptyParamsRequest(method: "account/rateLimits/read", id: nextRequestId())
    return try await sendRequest(request, resultType: RateLimitsEnvelope.self)
  }

  func stop() {
    stdoutHandle?.readabilityHandler = nil
    stderrHandle?.readabilityHandler = nil
    inputHandle?.closeFile()
    stdoutHandle?.closeFile()
    stderrHandle?.closeFile()
    inputHandle = nil
    stdoutHandle = nil
    stderrHandle = nil

    if let process, process.isRunning {
      process.terminate()
    }
    process = nil

    failPending(CodexAppServerError.stopped)
  }

  private func nextRequestId() -> Int {
    defer { nextId += 1 }
    return nextId
  }

  private func sendRequest<Message: Encodable, Result: Decodable>(
    _ message: Message,
    resultType: Result.Type
  ) async throws -> Result {
    let id = try extractId(from: message)
    let payload = try encoder.encode(message) + Data([0x0A])
    guard let inputHandle else {
      throw CodexAppServerError.stopped
    }

    let requestTimeout = requestTimeout
    let timeoutTask = Task { [weak self] in
      let nanoseconds = UInt64(max(0.1, requestTimeout) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      await self?.failRequest(id, CodexAppServerError.requestTimedOut)
    }
    defer {
      timeoutTask.cancel()
    }

    let line = try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do {
        logger.info("Writing app-server request id \(id, privacy: .public)")
        try inputHandle.write(contentsOf: payload)
        logger.info("Wrote app-server request id \(id, privacy: .public)")
      } catch {
        pending[id] = nil
        logger.error("Failed writing app-server request id \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        continuation.resume(throwing: error)
      }
    }

    let response = try decoder.decode(AppServerResponse<Result>.self, from: line)

    if let error = response.error {
      throw CodexAppServerError.rpc(error.message)
    }

    guard let result = response.result else {
      throw CodexAppServerError.missingResult
    }

    return result
  }

  private func sendNotification<Message: Encodable>(_ message: Message) throws {
    let payload = try encoder.encode(message) + Data([0x0A])
    try inputHandle?.write(contentsOf: payload)
  }

  private func extractId<Message: Encodable>(from message: Message) throws -> Int {
    let data = try encoder.encode(message)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let id = object?["id"] as? Int else {
      throw CodexAppServerError.missingRequestId
    }
    return id
  }

  private func installReadabilityHandlers(stdout: FileHandle, stderr: FileHandle) {
    stdout.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task {
        await self?.consumeStdout(data)
      }
    }

    stderr.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task {
        await self?.consumeStderr(data)
      }
    }
  }

  private func consumeStdout(_ data: Data) {
    guard !data.isEmpty else {
      logger.error("Codex app-server stdout closed")
      failPending(CodexAppServerError.outputClosed)
      return
    }

    for byte in data {
      if byte == 0x0A {
        let line = stdoutBuffer
        stdoutBuffer.removeAll(keepingCapacity: true)
        handleLine(line)
      } else {
        stdoutBuffer.append(byte)
      }
    }
  }

  private func consumeStderr(_ data: Data) {
    guard !data.isEmpty else {
      return
    }

    for byte in data {
      appendStderr(byte)
    }
  }

  private func appendStderr(_ byte: UInt8) {
    stderrTail.append(byte)
    if stderrTail.count > maxStderrTailBytes {
      stderrTail.removeFirst(stderrTail.count - maxStderrTailBytes)
    }
  }

  private func processDidExit(status: Int32) {
    let stderr = String(data: stderrTail, encoding: .utf8)
    logger.error("Codex app-server exited with status \(status, privacy: .public)")
    failPending(CodexAppServerError.processExited(status, stderr: stderr))
  }

  private func handleLine(_ line: Data) {
    guard !line.isEmpty else {
      return
    }

    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
      if let id = object["id"] as? Int,
         let continuation = pending.removeValue(forKey: id) {
        logger.info("Received app-server response id \(id, privacy: .public)")
        continuation.resume(returning: line)
        return
      }

      if let id = object["id"] as? Int {
        logger.info("Ignored app-server response id \(id, privacy: .public) without pending request")
        return
      }

      if let method = object["method"] as? String {
        if method == "account/rateLimits/updated",
           let notification = try? decoder.decode(RateLimitUpdateNotification.self, from: line) {
          logger.info("Received app-server rate limit update")
          updateHandler?(notification.params)
        } else {
          logger.info("Ignored app-server notification \(method, privacy: .public)")
        }
        return
      }
    }

    logger.info("Ignored app-server message without id or method")
  }

  private func failPending(_ error: Error) {
    let continuations = pending.values
    pending.removeAll()

    for continuation in continuations {
      continuation.resume(throwing: error)
    }
  }

  private func failRequest(_ id: Int, _ error: Error) {
    guard let continuation = pending.removeValue(forKey: id) else {
      return
    }
    logger.error("Failing app-server request id \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
    continuation.resume(throwing: error)
  }

  static func sanitizedEnvironment(
    from environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
  ) -> [String: String] {
    let allowedKeys = [
      "CODEX_HOME",
      "HOME",
      "LANG",
      "LC_ALL",
      "LC_CTYPE",
      "LOGNAME",
      "NO_COLOR",
      "PATH",
      "SHELL",
      "SSH_AUTH_SOCK",
      "TERM",
      "TMPDIR",
      "USER"
    ]
    var sanitized: [String: String] = [:]

    for key in allowedKeys {
      if let value = environment[key], !value.isEmpty {
        sanitized[key] = value
      }
    }

    if sanitized["HOME"] == nil {
      sanitized["HOME"] = homeDirectory
    }
    if sanitized["PATH"] == nil {
      sanitized["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    if sanitized["TERM"] == nil {
      sanitized["TERM"] = "dumb"
    }

    return sanitized
  }
}

enum CodexAppServerError: LocalizedError {
  case stopped
  case requestTimedOut
  case outputClosed
  case processExited(Int32, stderr: String?)
  case missingRequestId
  case missingResult
  case rpc(String)

  var errorDescription: String? {
    switch self {
    case .stopped:
      return "Codex app-server stopped."
    case .requestTimedOut:
      return "Codex app-server did not respond."
    case .outputClosed:
      return "Codex app-server output closed."
    case let .processExited(status, stderr):
      let stderr = stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let stderr, !stderr.isEmpty {
        return "Codex app-server exited with status \(status): \(stderr)"
      }
      return "Codex app-server exited with status \(status)."
    case .missingRequestId:
      return "Could not prepare the app-server request."
    case .missingResult:
      return "Codex app-server returned no result."
    case let .rpc(message):
      return message
    }
  }
}

private func + (left: Data, right: Data) -> Data {
  var data = left
  data.append(right)
  return data
}
