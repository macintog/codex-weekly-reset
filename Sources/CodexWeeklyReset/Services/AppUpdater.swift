import Combine
import Sparkle

private final class BuildAwareVersionDisplayer: NSObject, SUVersionDisplay {
  private func formatted(displayVersion: String, buildVersion: String) -> String {
    "\(displayVersion) build \(buildVersion)"
  }

  @objc(formatUpdateDisplayVersionFromUpdate:andBundleDisplayVersion:withBundleVersion:)
  func formatUpdateVersion(
    fromUpdate update: SUAppcastItem,
    andBundleDisplayVersion bundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
    withBundleVersion buildVersion: String
  ) -> String {
    bundleDisplayVersion.pointee = formatted(
      displayVersion: bundleDisplayVersion.pointee as String,
      buildVersion: buildVersion
    ) as NSString

    return formatted(
      displayVersion: update.displayVersionString,
      buildVersion: update.versionString
    )
  }

  @objc(formatBundleDisplayVersion:withBundleVersion:matchingUpdate:)
  func formatBundleDisplayVersion(
    _ displayVersion: String,
    withBundleVersion buildVersion: String,
    matchingUpdate: SUAppcastItem?
  ) -> String {
    formatted(displayVersion: displayVersion, buildVersion: buildVersion)
  }
}

@MainActor
final class AppUpdater: ObservableObject {
  @Published private(set) var canCheckForUpdates: Bool
  @Published private(set) var availableUpdate: String?

  private let updaterController: SPUStandardUpdaterController
  private let updaterDelegate: AppUpdaterControllerDelegate
  private var canCheckObservation: AnyCancellable?

  init(startingUpdater: Bool = true) {
    let updaterDelegate = AppUpdaterControllerDelegate()
    let updaterController = SPUStandardUpdaterController(
      startingUpdater: startingUpdater,
      updaterDelegate: updaterDelegate,
      userDriverDelegate: updaterDelegate
    )

    self.updaterDelegate = updaterDelegate
    self.updaterController = updaterController
    canCheckForUpdates = updaterController.updater.canCheckForUpdates

    updaterDelegate.scheduledUpdateHandler = { [weak self] version, build in
      Task { @MainActor in
        self?.availableUpdate = "Update \(version) (\(build)) available"
      }
    }
    updaterDelegate.clearScheduledUpdateHandler = { [weak self] in
      Task { @MainActor in
        self?.availableUpdate = nil
      }
    }

    canCheckObservation = updaterController.updater
      .publisher(for: \SPUUpdater.canCheckForUpdates)
      .receive(on: RunLoop.main)
      .sink { [weak self] canCheck in
        self?.canCheckForUpdates = canCheck
      }
  }

  func checkForUpdates() {
    availableUpdate = nil
    updaterController.checkForUpdates(nil)
  }
}

@preconcurrency
final class AppUpdaterControllerDelegate: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
  nonisolated(unsafe) var scheduledUpdateHandler: ((String, String) -> Void)?
  nonisolated(unsafe) var clearScheduledUpdateHandler: (() -> Void)?
  nonisolated(unsafe) private let versionDisplayer = BuildAwareVersionDisplayer()

  nonisolated static func shouldAllowScheduledUpdateWindow(
    immediateFocus: Bool
  ) -> Bool {
    false
  }

  nonisolated var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  @objc(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:)
  nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    Self.shouldAllowScheduledUpdateWindow(immediateFocus: immediateFocus)
  }

  @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    guard !handleShowingUpdate, !state.userInitiated else {
      return
    }
    scheduledUpdateHandler?(
      update.displayVersionString,
      update.versionString
    )
  }

  @objc(standardUserDriverDidReceiveUserAttentionForUpdate:)
  nonisolated func standardUserDriverDidReceiveUserAttention(
    forUpdate update: SUAppcastItem
  ) {
    clearScheduledUpdateHandler?()
  }

  @objc(standardUserDriverWillFinishUpdateSession)
  nonisolated func standardUserDriverWillFinishUpdateSession() {
    clearScheduledUpdateHandler?()
  }

  @objc(standardUserDriverRequestsVersionDisplayer)
  nonisolated func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
    versionDisplayer
  }

  @objc(versionDisplayerForUpdater:)
  func versionDisplayer(for updater: SPUUpdater) -> (any SUVersionDisplay)? {
    versionDisplayer
  }
}
