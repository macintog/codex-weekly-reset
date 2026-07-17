import SwiftUI

struct StatusPopoverView: View {
  @ObservedObject var monitor: LimitMonitor
  private let projectURL = URL(string: "https://github.com/macintog/codex-weekly-reset")!

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 14) {
        header

        statusItems

        if let lastError = monitor.lastError {
          Text(lastError)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("lastErrorValue")
        }

        controls
      }
      .padding(18)

      Button {
        NSWorkspace.shared.open(projectURL)
      } label: {
        Image(systemName: "info.circle")
          .font(.system(size: 15, weight: .regular))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("projectInfoButton")
      .accessibilityLabel("Open GitHub project page")
      .help("Open GitHub project page")
      .padding(.top, 16)
      .padding(.trailing, 18)
    }
    .frame(width: 386)
  }

  @ViewBuilder
  private var header: some View {
    Group {
      switch monitor.state {
      case .idle, .loading:
        HStack(spacing: 18) {
          LimitRingView(percent: nil)
          VStack(alignment: .leading, spacing: 4) {
            Text("Checking")
              .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("Codex weekly limit")
              .font(.title3.weight(.semibold))
              .foregroundStyle(.secondary)
          }
        }
      case let .ready(snapshot):
        HStack(spacing: 18) {
          LimitRingView(percent: snapshot.remainingPercent)
          VStack(alignment: .leading, spacing: 2) {
            Text(DisplayFormatters.percentage(snapshot.remainingPercent))
              .font(.system(size: 38, weight: .bold, design: .rounded))
              .monospacedDigit()
              .fixedSize(horizontal: true, vertical: false)
              .accessibilityIdentifier("weeklyRemainingValue")
            Text("weekly remaining")
              .font(.system(size: 20, weight: .medium, design: .rounded))
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 20)
        }
      case .failed:
        HStack(spacing: 18) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 42))
            .foregroundStyle(.orange)
            .frame(width: 72, height: 72)
          VStack(alignment: .leading, spacing: 4) {
            Text("Unavailable")
              .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("Codex limit check failed")
              .font(.title3.weight(.semibold))
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(.bottom, 8)
  }

  private var statusItems: some View {
    VStack(alignment: .leading, spacing: 0) {
      quotaStatusItems

      Divider()
        .padding(.leading, 37)
        .padding(.vertical, 10)

      appStatusItems
    }
  }

  private var quotaStatusItems: some View {
    VStack(alignment: .leading, spacing: 11) {
      statusItem(
        symbol: "calendar",
        tint: .green,
        title: resetText,
        id: "resetTimeValue",
        fontSize: 17,
        fontWeight: .medium
      )

      if let snapshot = monitor.state.snapshot,
         let resetCredits = snapshot.resetCredits {
        let presentation = ResetCreditPresentation(
          resetCredits: resetCredits,
          now: snapshot.checkedAt
        )
        statusItem(
          symbol: "ticket",
          tint: .purple,
          title: presentation.countText,
          id: "resetCreditCountValue",
          fontSize: 17,
          fontWeight: .medium
        )
        if let expiryText = presentation.expiryText {
          let alertLevel = presentation.expiryAlert?.level
          let tint = resetExpiryTint(for: alertLevel)
          statusItem(
            symbol: resetExpirySymbol(for: alertLevel),
            tint: tint,
            title: expiryText,
            id: "resetCreditExpiryValue",
            minimumScaleFactor: 0.9,
            textColor: alertLevel == nil ? .primary : tint,
            fontSize: 17,
            fontWeight: alertLevel == nil ? .medium : .semibold
          )
        }
      }
    }
  }

  private var appStatusItems: some View {
    VStack(alignment: .leading, spacing: 9) {
      statusItem(
        symbol: "terminal",
        tint: .secondary,
        title: sourceText,
        id: "sourcePathValue",
        accessibilityValue: monitor.sourcePath,
        textColor: .secondary,
        fontSize: 15
      )
      statusItem(
        symbol: "bell",
        tint: notificationTint,
        title: "Notifications \(monitor.notificationState.displayName)",
        id: "notificationStateValue",
        textColor: .secondary,
        fontSize: 15
      )
      statusItem(
        symbol: "hammer",
        tint: .secondary,
        title: monitor.buildIdentity.displayText,
        id: "buildIdentityValue",
        textColor: .secondary,
        fontSize: 15
      )

      if monitor.shouldShowLastCheck() {
        statusItem(
          symbol: "clock.badge.exclamationmark",
          tint: .orange,
          title: "Last checked \(lastCheckText)",
          id: "lastCheckValue",
          textColor: .secondary,
          fontSize: 15
        )
      }
    }
  }

  private var controls: some View {
    HStack(spacing: 10) {
      Button {
        monitor.refreshNow()
      } label: {
        Label(
          monitor.isRefreshing ? "Refreshing…" : "Refresh",
          systemImage: "arrow.clockwise"
        )
        .font(.system(size: 13, weight: .medium))
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .disabled(monitor.isRefreshing)
      .accessibilityIdentifier("refreshButton")
      .accessibilityLabel("Refresh")

      Spacer()

      Button {
        monitor.quit()
      } label: {
        Text("Quit")
          .font(.system(size: 13, weight: .medium))
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .accessibilityIdentifier("quitButton")
      .accessibilityLabel("Quit")
    }
    .padding(.top, 2)
  }

  private func statusItem(
    symbol: String,
    tint: Color,
    title: String,
    id: String,
    accessibilityValue: String? = nil,
    minimumScaleFactor: CGFloat = 1,
    textColor: Color = .primary,
    fontSize: CGFloat = 18,
    fontWeight: Font.Weight = .regular
  ) -> some View {
    HStack(spacing: 13) {
      Image(systemName: symbol)
        .font(.system(size: 19, weight: .regular))
        .foregroundStyle(tint)
        .frame(width: 24, height: 24)

      Text(title)
        .font(.system(size: fontSize, weight: fontWeight, design: .rounded))
        .foregroundStyle(textColor)
        .lineLimit(1)
        .allowsTightening(minimumScaleFactor < 1)
        .minimumScaleFactor(minimumScaleFactor)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(id)
        .accessibilityValue(accessibilityValue ?? title)
    }
  }

  private var notificationTint: Color {
    switch monitor.notificationState {
    case .authorized, .provisional:
      return .green
    case .notDetermined:
      return .orange
    case .denied:
      return .red
    case .unknown:
      return .secondary
    }
  }

  private func resetExpiryTint(for level: ResetCreditExpiryAlert.Level?) -> Color {
    switch level {
    case .warning:
      return .orange
    case .critical:
      return .red
    case nil:
      return .purple
    }
  }

  private func resetExpirySymbol(for level: ResetCreditExpiryAlert.Level?) -> String {
    switch level {
    case .warning:
      return "exclamationmark.triangle.fill"
    case .critical:
      return "exclamationmark.octagon.fill"
    case nil:
      return "calendar.badge.clock"
    }
  }

  private var resetText: String {
    guard let snapshot = monitor.state.snapshot else {
      return "--"
    }
    return "Resets \(DisplayFormatters.resetDayAndTime.string(from: snapshot.resetsAt))"
  }

  private var lastCheckText: String {
    guard let snapshot = monitor.state.snapshot else {
      return "--"
    }
    return DisplayFormatters.time.string(from: snapshot.checkedAt)
  }

  private var sourceText: String {
    if monitor.sourcePath.hasSuffix(".app") || monitor.sourcePath.contains(".app/") {
      return "Codex.app"
    }

    return DisplayFormatters.sourceLabel(monitor.sourcePath)
  }
}

struct ResetCreditPresentation: Equatable {
  let countText: String
  let expiryText: String?
  let expiryAlert: ResetCreditExpiryAlert?

  init(resetCredits: RateLimitResetCredits, now: Date = Date()) {
    let count = resetCredits.availableCount
    let noun = count == 1 ? "reset" : "resets"
    countText = String(count) + " banked " + noun + " available"
    expiryAlert = ResetCreditExpiryPolicy.alert(
      resetCredits: resetCredits,
      now: now
    )

    if let expiry = resetCredits.earliestAvailableExpiry {
      expiryText = "Next reset expires " + DisplayFormatters.resetDayAndTime.string(from: expiry)
    } else {
      expiryText = nil
    }
  }
}
