import XCTest
@testable import CodexWeeklyReset

final class RateLimitTests: XCTestCase {
  func testParsesMainCodexWeeklyBucket() throws {
    let envelope = try decodeEnvelope("""
    {"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1777744100},"secondary":{"usedPercent":52,"windowDurationMins":10080,"resetsAt":1777986630},"planType":"pro","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"RateLimitResetCredit_1","resetType":"codexRateLimits","status":"available","grantedAt":1781654400,"expiresAt":1784246400},{"id":"RateLimitResetCredit_2","resetType":"codexRateLimits","status":"redeemed","grantedAt":1781654401,"expiresAt":1781654402}]}}
    """)

    let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      checkedAt: checkedAt,
      sourcePath: "/Applications/Codex.app/Contents/Resources/codex"
    )

    XCTAssertEqual(snapshot.limitId, "codex")
    XCTAssertEqual(snapshot.remainingPercent, 48, accuracy: 0.001)
    XCTAssertEqual(snapshot.usedPercent, 52, accuracy: 0.001)
    XCTAssertEqual(snapshot.windowDurationMins, 10080)
    XCTAssertEqual(snapshot.planType, "pro")
    XCTAssertEqual(snapshot.checkedAt, checkedAt)
    XCTAssertEqual(snapshot.resetCredits?.availableCount, 2)
    XCTAssertEqual(snapshot.resetCredits?.earliestAvailableExpiry, Date(timeIntervalSince1970: 1784246400))
  }

  func testParsesCurrentLiveShapeWithWeeklyWindowInPrimary() throws {
    let envelope = try decodeEnvelope("""
    {"rateLimits":{"limitId":"codex","primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1784811085},"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1784811085},"secondary":null}},"rateLimitResetCredits":{"availableCount":5,"credits":[{"status":"available","grantedAt":1781743116,"expiresAt":1784335116},{"status":"available","grantedAt":1782518078,"expiresAt":1785110078}]}}
    """)

    let snapshot = try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      sourcePath: "/Users/test/.local/bin/codex"
    )

    XCTAssertEqual(snapshot.remainingPercent, 64, accuracy: 0.001)
    XCTAssertEqual(snapshot.windowDurationMins, 10080)
    XCTAssertEqual(snapshot.resetsAt, Date(timeIntervalSince1970: 1784811085))
    XCTAssertEqual(snapshot.resetCredits?.availableCount, 5)
    XCTAssertEqual(snapshot.resetCredits?.earliestAvailableExpiry, Date(timeIntervalSince1970: 1784335116))
  }

  func testResetCreditsUseAuthoritativeCountAndEarliestAvailableExpiry() throws {
    let credits = try JSONDecoder().decode(
      RateLimitResetCredits.self,
      from: Data("""
      {"availableCount":4,"credits":[{"status":"available","grantedAt":100,"expiresAt":400},{"status":"redeemed","grantedAt":50,"expiresAt":200},{"status":"available","grantedAt":150,"expiresAt":300}]}
      """.utf8)
    )

    XCTAssertEqual(credits.availableCount, 4)
    XCTAssertEqual(credits.earliestAvailableExpiry, Date(timeIntervalSince1970: 300))
  }

  func testResetCreditsWithoutDetailRowsHaveNoExpiry() throws {
    let credits = try JSONDecoder().decode(
      RateLimitResetCredits.self,
      from: Data("{\"availableCount\":2,\"credits\":null}".utf8)
    )

    XCTAssertEqual(credits.availableCount, 2)
    XCTAssertNil(credits.earliestAvailableExpiry)
  }

  func testResetCreditPresentationUsesPluralizationAndEarliestExpiry() {
    let one = ResetCreditPresentation(resetCredits: RateLimitResetCredits(
      availableCount: 1,
      credits: [RateLimitResetCredit(
        id: nil,
        resetType: nil,
        status: "available",
        grantedAt: 100,
        expiresAt: 400,
        title: nil,
        description: nil
      )]
    ))
    let many = ResetCreditPresentation(resetCredits: RateLimitResetCredits(availableCount: 2))

    XCTAssertEqual(one.countText, "1 banked reset available")
    XCTAssertTrue(one.expiryText?.contains("Next reset expires") == true)
    XCTAssertEqual(many.countText, "2 banked resets available")
    XCTAssertNil(many.expiryText)
  }

  func testBankedResetExpiryPresentationDistinguishesFirstSecondAndLaterWeeks() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let locale = Locale(identifier: "en_US")
    let now = calendar.date(from: DateComponents(
      year: 2024,
      month: 7,
      day: 21,
      hour: 15,
      minute: 10
    ))!
    func normalized(_ value: String) -> String {
      value.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    XCTAssertEqual(
      normalized(DisplayFormatters.bankedResetExpiryDayAndTime(
        calendar.date(byAdding: .day, value: 7, to: now)!,
        now: now,
        calendar: calendar,
        locale: locale
      )),
      "Sunday at 3:10 PM"
    )
    XCTAssertEqual(
      normalized(DisplayFormatters.bankedResetExpiryDayAndTime(
        calendar.date(byAdding: .day, value: 8, to: now)!,
        now: now,
        calendar: calendar,
        locale: locale
      )),
      "next Monday at 3:10 PM"
    )
    XCTAssertEqual(
      normalized(DisplayFormatters.bankedResetExpiryDayAndTime(
        calendar.date(byAdding: .day, value: 14, to: now)!,
        now: now,
        calendar: calendar,
        locale: locale
      )),
      "next Sunday at 3:10 PM"
    )
    XCTAssertEqual(
      normalized(DisplayFormatters.bankedResetExpiryDayAndTime(
        calendar.date(byAdding: .day, value: 15, to: now)!,
        now: now,
        calendar: calendar,
        locale: locale
      )),
      "on 8/5 at 3:10 PM"
    )
  }

  func testBankedResetExpiryPresentationLocalizesMonthDayOrder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2024, month: 7, day: 21))!
    let expiry = calendar.date(byAdding: .day, value: 15, to: now)!

    XCTAssertTrue(DisplayFormatters.bankedResetExpiryDayAndTime(
      expiry,
      now: now,
      calendar: calendar,
      locale: Locale(identifier: "en_GB")
    ).hasPrefix("on 05/08"))
  }

  func testResetExpiryPolicyUsesOneDayWarningAndOneHourCriticalAlert() {
    let now = Date(timeIntervalSince1970: 10_000)

    XCTAssertNil(ResetCreditExpiryPolicy.alert(
      resetCredits: resetCredits(expiry: now.addingTimeInterval(86_401)),
      now: now
    ))
    XCTAssertEqual(
      ResetCreditExpiryPolicy.alert(
        resetCredits: resetCredits(expiry: now.addingTimeInterval(86_400)),
        now: now
      )?.level,
      .warning
    )
    XCTAssertEqual(
      ResetCreditExpiryPolicy.alert(
        resetCredits: resetCredits(expiry: now.addingTimeInterval(3_601)),
        now: now
      )?.level,
      .warning
    )
    XCTAssertEqual(
      ResetCreditExpiryPolicy.alert(
        resetCredits: resetCredits(expiry: now.addingTimeInterval(3_600)),
        now: now
      )?.level,
      .critical
    )
    XCTAssertNil(ResetCreditExpiryPolicy.alert(
      resetCredits: resetCredits(expiry: now),
      now: now
    ))
  }

  func testResetExpiryAlertsAreDeduplicatedPerExpiryAndThreshold() {
    let expiry = Date(timeIntervalSince1970: 20_000)
    let warning = ResetCreditExpiryAlert(level: .warning, expiry: expiry)
    let critical = ResetCreditExpiryAlert(level: .critical, expiry: expiry)
    var handled: Set<ResetCreditExpiryAlert> = []

    XCTAssertTrue(handled.insert(warning).inserted)
    XCTAssertFalse(handled.insert(warning).inserted)
    XCTAssertTrue(handled.insert(critical).inserted)
    XCTAssertNotEqual(warning.notificationIdentifier, critical.notificationIdentifier)

    let firstLaunchIdentifier = SystemNotificationService.resetExpiryRequestIdentifier(
      for: warning,
      launchIdentifier: "launch-one"
    )
    let secondLaunchIdentifier = SystemNotificationService.resetExpiryRequestIdentifier(
      for: warning,
      launchIdentifier: "launch-two"
    )
    XCTAssertNotEqual(firstLaunchIdentifier, secondLaunchIdentifier)
    XCTAssertEqual(
      firstLaunchIdentifier,
      SystemNotificationService.resetExpiryRequestIdentifier(
        for: warning,
        launchIdentifier: "launch-one"
      )
    )
  }

  func testNotificationPermissionStatesAllowOnlyDeliverableStatuses() {
    XCTAssertFalse(NotificationPermissionState.notDetermined.allowsDelivery)
    XCTAssertFalse(NotificationPermissionState.denied.allowsDelivery)
    XCTAssertTrue(NotificationPermissionState.authorized.allowsDelivery)
    XCTAssertTrue(NotificationPermissionState.provisional.allowsDelivery)
    XCTAssertFalse(NotificationPermissionState.unknown.allowsDelivery)
  }

  @MainActor
  func testStartupWaitsForNotificationAuthorizationBeforeExpiryAlert() async throws {
    let notifier = DelayedNotificationService()
    let fixture = try temporaryRateLimitFixture(
      expiresAt: Date().addingTimeInterval(30 * 60)
    )
    let monitor = LimitMonitor(
      configuration: AppConfiguration(
        configuredCodexPath: nil,
        fixturePath: fixture.path,
        notificationOverride: nil,
        pollInterval: 3_600,
        disableCodexFallbacks: true
      ),
      resolver: CodexExecutableResolver(includeFallbacks: false),
      notifier: notifier
    )

    monitor.start()
    try await waitForNotificationEvent(.authorizationStarted, in: notifier)
    try await Task.sleep(nanoseconds: 150_000_000)
    let alertedBeforeAuthorization = await notifier.hasEvent(.resetExpiryAlert)
    XCTAssertFalse(alertedBeforeAuthorization)

    await notifier.releaseAuthorization()
    try await waitForNotificationEvent(.resetExpiryAlert, in: notifier)

    let events = await notifier.recordedEvents()
    let authorizedIndex = try XCTUnwrap(events.firstIndex(of: .authorizationCompleted))
    let alertIndex = try XCTUnwrap(events.firstIndex(of: .resetExpiryAlert))
    XCTAssertLessThan(authorizedIndex, alertIndex)
  }

  @MainActor
  func testEligibleExpiryAlertRepeatsOnEachLaunchButNotWithinOneRun() async throws {
    let notifier = DelayedNotificationService(authorizationReleased: true)
    let fixture = try temporaryRateLimitFixture(
      expiresAt: Date().addingTimeInterval(30 * 60)
    )
    let configuration = AppConfiguration(
      configuredCodexPath: nil,
      fixturePath: fixture.path,
      notificationOverride: nil,
      pollInterval: 3_600,
      disableCodexFallbacks: true
    )

    let firstLaunch = LimitMonitor(
      configuration: configuration,
      resolver: CodexExecutableResolver(includeFallbacks: false),
      notifier: notifier
    )
    firstLaunch.start()
    try await waitForNotificationEventCount(1, in: notifier)

    firstLaunch.refreshNow()
    try await Task.sleep(nanoseconds: 150_000_000)
    let firstRunAlertCount = await notifier.eventCount(.resetExpiryAlert)
    XCTAssertEqual(firstRunAlertCount, 1)

    let secondLaunch = LimitMonitor(
      configuration: configuration,
      resolver: CodexExecutableResolver(includeFallbacks: false),
      notifier: notifier
    )
    secondLaunch.start()
    try await waitForNotificationEventCount(2, in: notifier)
  }

  func testResetExpiryNotificationBodyIsActionable() {
    let expiry = Date(timeIntervalSince1970: 20_000)
    let warning = ResetCreditExpiryAlert(level: .warning, expiry: expiry)
    let critical = ResetCreditExpiryAlert(level: .critical, expiry: expiry)

    XCTAssertTrue(warning.body(availableCount: 5).contains("5 banked resets"))
    XCTAssertTrue(critical.body(availableCount: 5).contains("avoid losing it"))
  }

  func testResetCreditPresentationExposesVisualAlertLevel() {
    let calendar = Calendar.current
    let startOfDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 10_000))
    let now = calendar.date(byAdding: .hour, value: 20, to: startOfDay)!
    let tomorrow = calendar.date(byAdding: .hour, value: 32, to: startOfDay)!

    let warning = ResetCreditPresentation(
      resetCredits: resetCredits(expiry: tomorrow),
      now: now
    )
    let critical = ResetCreditPresentation(
      resetCredits: resetCredits(expiry: now.addingTimeInterval(1_800)),
      now: now
    )

    XCTAssertEqual(warning.expiryAlert?.level, .warning)
    XCTAssertTrue(warning.expiryText?.contains("tomorrow at") == true)
    XCTAssertEqual(critical.expiryAlert?.level, .critical)
    XCTAssertTrue(critical.expiryText?.contains("today at") == true)
  }

  func testNonAlertResetExpiryKeepsWeekday() {
    let now = Date(timeIntervalSince1970: 10_000)
    let presentation = ResetCreditPresentation(
      resetCredits: resetCredits(expiry: now.addingTimeInterval(48 * 60 * 60)),
      now: now
    )

    XCTAssertNil(presentation.expiryAlert)
    XCTAssertFalse(presentation.expiryText?.contains("today at") == true)
    XCTAssertFalse(presentation.expiryText?.contains("tomorrow at") == true)
  }

  func testPrefersMainCodexOverModelSpecificBucket() throws {
    let envelope = try decodeEnvelope("""
    {"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":10},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":20}},"codex_model":{"limitId":"codex_model","limitName":"Model","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":10},"secondary":{"usedPercent":90,"windowDurationMins":10080,"resetsAt":20}}}}
    """)

    let snapshot = try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      sourcePath: "/opt/homebrew/bin/codex"
    )

    XCTAssertEqual(snapshot.limitId, "codex")
    XCTAssertEqual(snapshot.remainingPercent, 80, accuracy: 0.001)
  }

  func testMissingWeeklyWindowThrows() throws {
    let envelope = try decodeEnvelope("""
    {"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":3,"windowDurationMins":300,"resetsAt":1777744100}}}}
    """)

    XCTAssertThrowsError(try RateLimitSnapshot.mainCodexWeekly(from: envelope, sourcePath: "/x")) { error in
      XCTAssertEqual(error as? RateLimitSelectionError, .missingWeeklyWindow)
    }
  }

  func testNotificationPolicySuppressesFirstReadAndSmallMoves() {
    let previous = snapshot(remaining: 48)

    XCTAssertFalse(LimitNotificationPolicy.shouldNotifyIncrease(previous: nil, current: previous))
    XCTAssertFalse(LimitNotificationPolicy.shouldNotifyIncrease(previous: previous, current: snapshot(remaining: 48.9)))
    XCTAssertFalse(LimitNotificationPolicy.shouldNotifyIncrease(previous: previous, current: snapshot(remaining: 49)))
    XCTAssertTrue(LimitNotificationPolicy.shouldNotifyIncrease(previous: previous, current: snapshot(remaining: 56)))
    XCTAssertTrue(LimitNotificationPolicy.shouldNotifyIncrease(previous: previous, current: snapshot(remaining: 100)))
  }

  func testNotificationPolicyEmitsLowQuotaWhenCrossingTwentyPercent() {
    XCTAssertNil(LimitNotificationPolicy.event(previous: nil, current: snapshot(remaining: 20)))
    XCTAssertNil(LimitNotificationPolicy.event(previous: snapshot(remaining: 20), current: snapshot(remaining: 12)))
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 21), current: snapshot(remaining: 20)),
      .lowQuota
    )
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 45), current: snapshot(remaining: 18)),
      .lowQuota
    )
  }

  func testNotificationPolicyEmitsRedQuotaWhenCrossingBelowTenPercent() {
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 10), current: snapshot(remaining: 9)),
      .redQuota
    )
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 20), current: snapshot(remaining: 5)),
      .redQuota
    )
    XCTAssertNil(LimitNotificationPolicy.event(previous: snapshot(remaining: 9), current: snapshot(remaining: 4)))
  }

  func testNotificationPolicyEmitsQuotaExhaustedWhenCrossingToZero() {
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 9), current: snapshot(remaining: 0)),
      .quotaExhausted
    )
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 50), current: snapshot(remaining: 0)),
      .quotaExhausted
    )
    XCTAssertNil(LimitNotificationPolicy.event(previous: snapshot(remaining: 0), current: snapshot(remaining: 0)))
  }

  func testNotificationPolicyEmitsQuotaIncreasedForResetJump() {
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 0), current: snapshot(remaining: 100)),
      .quotaIncreased
    )
    XCTAssertEqual(
      LimitNotificationPolicy.event(previous: snapshot(remaining: 18), current: snapshot(remaining: 99)),
      .quotaIncreased
    )
  }

  func testNotificationEventCopyMatchesOSNotificationCases() {
    let previous = snapshot(remaining: 4)
    let current = snapshot(
      remaining: 0,
      checkedAt: Date(timeIntervalSince1970: 1_000),
      resetsAt: Date(timeIntervalSince1970: 184_600)
    )

    XCTAssertEqual(LimitNotificationEvent.lowQuota.title, "Codex weekly quota is low")
    XCTAssertEqual(LimitNotificationEvent.redQuota.title, "Codex weekly quota is low")
    XCTAssertEqual(LimitNotificationEvent.quotaExhausted.title, "Codex weekly limit exhausted")
    XCTAssertEqual(LimitNotificationEvent.quotaIncreased.title, "Codex weekly quota increased")
    XCTAssertEqual(LimitNotificationEvent.lowQuota.body(previous: previous, current: snapshot(remaining: 18)), "Less than 20% remaining.")
    XCTAssertEqual(LimitNotificationEvent.redQuota.body(previous: previous, current: snapshot(remaining: 9)), "Less than 10% remaining.")
    XCTAssertEqual(LimitNotificationEvent.quotaExhausted.body(previous: previous, current: current), "Reset is in 2 days 3 hours.")
  }

  func testMenuBarPresentationBandsRemainingCapacity() {
    XCTAssertEqual(QuotaIndicatorBand(filledSlots: 5), .healthy)
    XCTAssertEqual(QuotaIndicatorBand(filledSlots: 2), .caution)
    XCTAssertEqual(QuotaIndicatorBand(filledSlots: 1), .alarm)
    XCTAssertEqual(QuotaIndicatorBand(filledSlots: 0), .alarm)
  }

  func testNotificationPolicyUsesSameNineSlotThresholdsAsMenuBar() {
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 100), 9)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 89), 9)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 88.8), 8)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 78), 8)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 77.7), 7)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 22.2), 2)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 11.1), 1)
    XCTAssertEqual(QuotaIndicatorSlots.filledSlots(forRemainingPercent: 0), 0)
  }

  func testQuotaIndicatorBandUsesSharedNineSlotThresholds() {
    XCTAssertEqual(QuotaIndicatorSlots.band(forRemainingPercent: 43), .healthy)
    XCTAssertEqual(QuotaIndicatorSlots.band(forRemainingPercent: 22.2), .caution)
    XCTAssertEqual(QuotaIndicatorSlots.band(forRemainingPercent: 11.1), .alarm)
    XCTAssertEqual(QuotaIndicatorSlots.band(forRemainingPercent: 0), .alarm)
  }

  func testMenuBarPresentationUsesApproximateGlyphStateWithoutDisplayText() {
    let presentation = MenuBarLimitPresentation(state: .ready(snapshot(remaining: 47)))

    XCTAssertEqual(presentation.fraction, 0.47, accuracy: 0.001)
    XCTAssertEqual(presentation.band, .healthy)
    XCTAssertEqual(presentation.filledCells, 5)
    XCTAssertEqual(presentation.accessibilityValue, "47% weekly remaining")
  }

  func testLimitRingCompensatesForRoundedCapLength() {
    let geometry = LimitRingGeometry(percent: 49, size: 72, lineWidth: 8)
    let radius = (72.0 - 8.0) / 2
    let roundCapsFraction = 8.0 / (2 * Double.pi * radius)

    XCTAssertTrue(geometry.usesRoundCaps)
    XCTAssertEqual(geometry.trimmedFraction + roundCapsFraction, 0.49, accuracy: 0.000_001)
  }

  func testLimitRingPreservesExactProgressAcrossRange() {
    let empty = LimitRingGeometry(percent: 0, size: 72, lineWidth: 8)
    let small = LimitRingGeometry(percent: 2, size: 72, lineWidth: 8)
    let half = LimitRingGeometry(percent: 50, size: 72, lineWidth: 8)
    let full = LimitRingGeometry(percent: 100, size: 72, lineWidth: 8)

    XCTAssertEqual(empty.trimmedFraction, 0)
    XCTAssertFalse(empty.usesRoundCaps)
    XCTAssertEqual(small.trimmedFraction, 0.02, accuracy: 0.000_001)
    XCTAssertFalse(small.usesRoundCaps)
    XCTAssertLessThan(half.trimmedFraction, 0.5)
    XCTAssertTrue(half.usesRoundCaps)
    XCTAssertEqual(full.trimmedFraction, 1)
    XCTAssertTrue(full.usesRoundCaps)
  }

  func testPopoverLeftEdgeTracksStatusItemAndClampsToScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1_494, height: 934)

    XCTAssertEqual(
      PopoverAnchorGeometry.alignedOriginX(
        statusItemLeft: 25,
        popoverWidth: 386,
        screenFrame: screen
      ),
      25
    )
    XCTAssertEqual(
      PopoverAnchorGeometry.alignedOriginX(
        statusItemLeft: 1_400,
        popoverWidth: 386,
        screenFrame: screen
      ),
      1_108
    )
  }

  @MainActor
  func testScheduledSparkleChecksNeverOwnWindowOrdering() {
    XCTAssertFalse(
      AppUpdaterControllerDelegate.shouldAllowScheduledUpdateWindow(
        immediateFocus: true
      )
    )
    XCTAssertFalse(
      AppUpdaterControllerDelegate.shouldAllowScheduledUpdateWindow(
        immediateFocus: false
      )
    )
    XCTAssertTrue(
      AppUpdaterControllerDelegate.shouldRefocusUserInitiatedUpdateWindow(
        handleShowingUpdate: true,
        userInitiated: true
      )
    )
    XCTAssertFalse(
      AppUpdaterControllerDelegate.shouldRefocusUserInitiatedUpdateWindow(
        handleShowingUpdate: false,
        userInitiated: true
      )
    )
    XCTAssertFalse(
      AppUpdaterControllerDelegate.shouldRefocusUserInitiatedUpdateWindow(
        handleShowingUpdate: true,
        userInitiated: false
      )
    )

    let delegate = AppUpdaterControllerDelegate()
    XCTAssertTrue(delegate.supportsGentleScheduledUpdateReminders)
    XCTAssertTrue(
      delegate.responds(
        to: NSSelectorFromString(
          "standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:"
        )
      )
    )
    XCTAssertTrue(
      delegate.responds(
        to: NSSelectorFromString("standardUserDriverRequestsVersionDisplayer")
      )
    )
  }

  func testMenuBarGlyphDrainsFromTopLeftTowardBottomRight() {
    XCTAssertFalse(MenuBarLimitGlyphImage.isFilledCell(0, filledCells: 2))
    XCTAssertFalse(MenuBarLimitGlyphImage.isFilledCell(6, filledCells: 2))
    XCTAssertTrue(MenuBarLimitGlyphImage.isFilledCell(7, filledCells: 2))
    XCTAssertTrue(MenuBarLimitGlyphImage.isFilledCell(8, filledCells: 2))
  }

  func testAppServerExitErrorIncludesStderrTail() {
    let error = CodexAppServerError.processExited(64, stderr: "invalid auth token\n")

    XCTAssertEqual(error.localizedDescription, "Codex app-server exited with status 64: invalid auth token")
  }

  func testAppServerClientReadsRateLimitsFromInteractiveServer() async throws {
    let executable = try temporaryExecutable("""
    #!/usr/bin/env python3
    import json
    import sys

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            print(json.dumps({"id": message["id"], "result": {}}), flush=True)
            print(json.dumps({"method": "remoteControl/status/changed", "params": {"status": "disabled", "environmentId": None}}), flush=True)
        elif method == "account/rateLimits/read":
            print(json.dumps({
                "id": message["id"],
                "result": {
                    "rateLimitsByLimitId": {
                        "codex": {
                            "limitId": "codex",
                            "limitName": None,
                            "primary": {"usedPercent": 8, "windowDurationMins": 300, "resetsAt": 1777762101},
                            "secondary": {"usedPercent": 60, "windowDurationMins": 10080, "resetsAt": 1777986630},
                            "credits": {"hasCredits": False, "unlimited": False, "balance": "0"},
                            "planType": "pro",
                            "rateLimitReachedType": None
                        }
                    },
                    "rateLimitResetCredits": {
                        "availableCount": 3,
                        "credits": [{"status": "available", "grantedAt": 1781654400, "expiresAt": 1784246400}]
                    }
                }
            }), flush=True)
    """)

    let client = CodexAppServerClient(executablePath: executable.path, requestTimeout: 2)
    let envelope = try await client.readRateLimits()
    let snapshot = try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      sourcePath: executable.path
    )
    await client.stop()

    XCTAssertEqual(snapshot.remainingPercent, 40, accuracy: 0.001)
    XCTAssertEqual(snapshot.sourcePath, executable.path)
    XCTAssertEqual(envelope.rateLimitResetCredits?.availableCount, 3)
    XCTAssertEqual(envelope.rateLimitResetCredits?.credits?.first?.expiryDate, Date(timeIntervalSince1970: 1784246400))
  }

  func testAppServerClientTimesOutWhenServerDoesNotAnswer() async throws {
    let executable = try temporaryExecutable("""
    #!/usr/bin/env python3
    import time

    time.sleep(30)
    """)

    let client = CodexAppServerClient(executablePath: executable.path, requestTimeout: 0.2)
    defer {
      Task {
        await client.stop()
      }
    }

    do {
      _ = try await client.readRateLimits()
      XCTFail("Expected app-server timeout")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Codex app-server did not respond.")
    }
  }

  func testRealCodexAppServerClientReadsRateLimitsWhenEnabled() async throws {
    guard ProcessInfo.processInfo.environment["CODEX_WEEKLY_RESET_REAL_APP_SERVER_TEST"] == "1" else {
      throw XCTSkip("Set CODEX_WEEKLY_RESET_REAL_APP_SERVER_TEST=1 to probe the real Codex app-server.")
    }

    let executablePath = ProcessInfo.processInfo.environment["CODEX_WEEKLY_RESET_REAL_CODEX_PATH"]
      ?? "/opt/homebrew/bin/codex"
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw XCTSkip("Codex executable is not available at \(executablePath).")
    }

    let client = CodexAppServerClient(executablePath: executablePath, requestTimeout: 5)
    let envelope = try await client.readRateLimits()
    _ = try RateLimitSnapshot.mainCodexWeekly(
      from: envelope,
      sourcePath: executablePath
    )
    await client.stop()
  }

  func testSourceLabelsCollapseFixturePaths() {
    XCTAssertEqual(
      DisplayFormatters.sourceLabel("Fixture: /tmp/rate-limits.json"),
      "Fixture"
    )
    XCTAssertEqual(
      DisplayFormatters.sourceLabel("/opt/homebrew/bin/codex"),
      "/opt/homebrew/bin/codex"
    )
  }

  func testAppServerEnvironmentStripsAppBundleAndXPCState() {
    let sanitized = CodexAppServerClient.sanitizedEnvironment(
      from: [
        "__CFBundleIdentifier": "com.macintog.codexweeklyreset",
        "XPC_SERVICE_NAME": "application.com.macintog.codexweeklyreset",
        "XPC_FLAGS": "1",
        "HOME": "/Users/tester",
        "PATH": "/opt/homebrew/bin:/usr/bin",
        "SHELL": "/bin/zsh",
        "CODEX_HOME": "/Users/tester/.codex"
      ],
      homeDirectory: "/Users/tester"
    )

    XCTAssertNil(sanitized["__CFBundleIdentifier"])
    XCTAssertNil(sanitized["XPC_SERVICE_NAME"])
    XCTAssertNil(sanitized["XPC_FLAGS"])
    XCTAssertEqual(sanitized["HOME"], "/Users/tester")
    XCTAssertEqual(sanitized["PATH"], "/opt/homebrew/bin:/usr/bin")
    XCTAssertEqual(sanitized["CODEX_HOME"], "/Users/tester/.codex")
  }

  private func decodeEnvelope(_ json: String) throws -> RateLimitsEnvelope {
    try JSONDecoder().decode(RateLimitsEnvelope.self, from: Data(json.utf8))
  }

  private func temporaryExecutable(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    let executable = directory.appendingPathComponent("fake-app-server")
    try contents.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    return executable
  }

  private func temporaryRateLimitFixture(expiresAt: Date) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    let fixture = directory.appendingPathComponent("rate-limits.json")
    let resetsAt = Int(Date().addingTimeInterval(4 * 24 * 60 * 60).timeIntervalSince1970)
    let expiry = Int(expiresAt.timeIntervalSince1970)
    let json = """
    {"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":39,"windowDurationMins":10080,"resetsAt":\(resetsAt)},"secondary":null}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"status":"available","grantedAt":\(expiry - 86_400),"expiresAt":\(expiry)}]}}
    """
    try json.write(to: fixture, atomically: true, encoding: .utf8)
    return fixture
  }

  private func waitForNotificationEvent(
    _ event: DelayedNotificationService.Event,
    in notifier: DelayedNotificationService
  ) async throws {
    for _ in 0..<100 {
      if await notifier.hasEvent(event) {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(event)")
  }

  private func waitForNotificationEventCount(
    _ count: Int,
    in notifier: DelayedNotificationService
  ) async throws {
    for _ in 0..<100 {
      if await notifier.eventCount(.resetExpiryAlert) >= count {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(count) reset-expiry alerts")
  }

  private func snapshot(
    remaining: Double,
    checkedAt: Date = Date(timeIntervalSince1970: 1_000),
    resetsAt: Date = Date(timeIntervalSince1970: 2_000)
  ) -> RateLimitSnapshot {
    RateLimitSnapshot(
      limitId: "codex",
      limitName: nil,
      usedPercent: 100 - remaining,
      remainingPercent: remaining,
      windowDurationMins: 10080,
      resetsAt: resetsAt,
      checkedAt: checkedAt,
      planType: "pro",
      sourcePath: "/codex",
      resetCredits: nil
    )
  }

  private func resetCredits(
    availableCount: Int = 5,
    expiry: Date
  ) -> RateLimitResetCredits {
    RateLimitResetCredits(
      availableCount: availableCount,
      credits: [RateLimitResetCredit(
        id: "RateLimitResetCredit_test",
        resetType: "codexRateLimits",
        status: "available",
        grantedAt: expiry.addingTimeInterval(-86_400).timeIntervalSince1970,
        expiresAt: expiry.timeIntervalSince1970,
        title: nil,
        description: nil
      )]
    )
  }
}

private actor DelayedNotificationService: UserNotificationManaging {
  enum Event: Equatable {
    case authorizationStarted
    case authorizationCompleted
    case resetExpiryAlert
  }

  private var events: [Event] = []
  private var authorizationReleased: Bool
  private var authorizationContinuation: CheckedContinuation<Void, Never>?

  init(authorizationReleased: Bool = false) {
    self.authorizationReleased = authorizationReleased
  }

  func authorizationStatus() async -> NotificationPermissionState {
    events.append(.authorizationStarted)
    if !authorizationReleased {
      await withCheckedContinuation { continuation in
        authorizationContinuation = continuation
      }
    }
    events.append(.authorizationCompleted)
    return .authorized
  }

  func requestAuthorization() async -> NotificationPermissionState {
    .authorized
  }

  func notify(
    _ event: LimitNotificationEvent,
    previous: RateLimitSnapshot,
    current: RateLimitSnapshot
  ) async throws {}

  func notify(_ alert: ResetCreditExpiryAlert, availableCount: Int) async throws {
    events.append(.resetExpiryAlert)
  }

  func releaseAuthorization() {
    authorizationReleased = true
    authorizationContinuation?.resume()
    authorizationContinuation = nil
  }

  func hasEvent(_ event: Event) -> Bool {
    events.contains(event)
  }

  func recordedEvents() -> [Event] {
    events
  }

  func eventCount(_ event: Event) -> Int {
    events.filter { $0 == event }.count
  }
}
