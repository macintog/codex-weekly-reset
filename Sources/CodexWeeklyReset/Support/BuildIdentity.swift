import Foundation

struct BuildIdentity {
  let version: String
  let build: String

  var displayText: String {
    "v\(version) (\(build))"
  }

  static var current: BuildIdentity {
    let info = Bundle.main.infoDictionary ?? [:]
    return BuildIdentity(
      version: info["CFBundleShortVersionString"] as? String ?? "0.1.0",
      build: info["CFBundleVersion"] as? String ?? "dev"
    )
  }
}
