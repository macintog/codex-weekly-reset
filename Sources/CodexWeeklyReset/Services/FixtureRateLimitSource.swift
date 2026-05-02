import Foundation

enum FixtureRateLimitSource {
  static func snapshot(
    from path: String,
    checkedAt: Date = Date()
  ) throws -> RateLimitSnapshot {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()

    let envelope: RateLimitsEnvelope
    if let response = try? decoder.decode(AppServerResponse<RateLimitsEnvelope>.self, from: data),
       response.id > 0 || response.result != nil || response.error != nil {
      if let error = response.error {
        throw CodexAppServerError.rpc(error.message)
      }

      guard let result = response.result else {
        throw CodexAppServerError.missingResult
      }
      envelope = result
    } else {
      envelope = try decoder.decode(RateLimitsEnvelope.self, from: data)
    }

    return try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      checkedAt: checkedAt,
      sourcePath: "Fixture: \(path)"
    )
  }
}
