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
    VStack(alignment: .leading, spacing: 13) {
      statusItem(
        symbol: "calendar",
        tint: .green,
        title: resetText,
        id: "resetTimeValue"
      )
      statusItem(
        symbol: "folder",
        tint: .blue,
        title: sourceText,
        id: "sourcePathValue",
        accessibilityValue: monitor.sourcePath
      )
      statusItem(
        symbol: "bell",
        tint: .green,
        title: "Notifications \(monitor.notificationState.displayName)",
        id: "notificationStateValue"
      )
      statusItem(
        symbol: "hammer",
        tint: .secondary,
        title: monitor.buildIdentity.displayText,
        id: "buildIdentityValue"
      )

      if monitor.shouldShowLastCheck() {
        statusItem(
          symbol: "clock.badge.exclamationmark",
          tint: .orange,
          title: "Last checked \(lastCheckText)",
          id: "lastCheckValue"
        )
      }
    }
  }

  private var controls: some View {
    HStack {
      Button {
        monitor.refreshNow()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 23, weight: .medium))
          .frame(width: 32, height: 28)
      }
      .buttonStyle(.plain)
      .disabled(monitor.isRefreshing)
      .accessibilityIdentifier("refreshButton")
      .accessibilityLabel("Refresh")
      .help("Refresh")

      Spacer()

      Button {
        monitor.quit()
      } label: {
        Text("Quit")
          .font(.system(size: 18, weight: .semibold, design: .rounded))
          .foregroundStyle(.red)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("quitButton")
      .accessibilityLabel("Quit")
    }
  }

  private func statusItem(
    symbol: String,
    tint: Color,
    title: String,
    id: String,
    accessibilityValue: String? = nil
  ) -> some View {
    HStack(spacing: 13) {
      Image(systemName: symbol)
        .font(.system(size: 19, weight: .regular))
        .foregroundStyle(tint)
        .frame(width: 24, height: 24)

      Text(title)
        .font(.system(size: 18, weight: .regular, design: .rounded))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(id)
        .accessibilityValue(accessibilityValue ?? title)
        .help(accessibilityValue ?? title)
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
