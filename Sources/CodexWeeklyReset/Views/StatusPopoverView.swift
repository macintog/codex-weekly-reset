import SwiftUI

struct StatusPopoverView: View {
  @ObservedObject var monitor: LimitMonitor

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      Divider()

      details

      if let lastError = monitor.lastError {
        Text(lastError)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("lastErrorValue")
      }

      controls
    }
    .padding(16)
    .frame(width: 306)
  }

  @ViewBuilder
  private var header: some View {
    switch monitor.state {
    case .idle, .loading:
      HStack(spacing: 14) {
        LimitRingView(percent: nil)
        VStack(alignment: .leading, spacing: 4) {
          Text("Checking")
            .font(.system(size: 28, weight: .semibold, design: .rounded))
          Text("Codex weekly limit")
            .foregroundStyle(.secondary)
        }
      }
    case let .ready(snapshot):
      HStack(spacing: 14) {
        LimitRingView(percent: snapshot.remainingPercent)
        VStack(alignment: .leading, spacing: 2) {
          Text(DisplayFormatters.percentage(snapshot.remainingPercent))
            .font(.system(size: 38, weight: .bold, design: .rounded))
            .monospacedDigit()
            .accessibilityIdentifier("weeklyRemainingValue")
          Text("weekly remaining")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    case .failed:
      HStack(spacing: 14) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 34))
          .foregroundStyle(.orange)
          .frame(width: 72, height: 72)
        VStack(alignment: .leading, spacing: 4) {
          Text("Unavailable")
            .font(.system(size: 28, weight: .semibold, design: .rounded))
          Text("Codex limit check failed")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var details: some View {
    VStack(spacing: 9) {
      detailRow("Reset", value: resetText, id: "resetTimeValue")
      detailRow("Last check", value: lastCheckText, id: "lastCheckValue")
      detailRow("Source", value: sourceText, id: "sourcePathValue")
      detailRow("Notifications", value: monitor.notificationState.displayName, id: "notificationStateValue")
      detailRow("Build", value: monitor.buildIdentity.displayText, id: "buildIdentityValue")
    }
  }

  private var controls: some View {
    HStack(spacing: 8) {
      NativeActionButton(
        title: "Refresh",
        systemImage: "arrow.clockwise",
        accessibilityIdentifier: "refreshButton",
        isEnabled: !monitor.isRefreshing
      ) {
        monitor.refreshNow()
      }
      .frame(width: 112, height: 28)

      Spacer()

      NativeActionButton(
        title: "Quit",
        systemImage: "power",
        accessibilityIdentifier: "quitButton",
        isEnabled: true
      ) {
        monitor.quit()
      }
      .frame(width: 86, height: 28)
    }
  }

  private func detailRow(_ title: String, value: String, id: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 78, alignment: .leading)
      Text(value)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(title)
        .accessibilityValue(rawDetailValue(for: id, displayValue: value))
        .accessibilityIdentifier(id)
        .help(rawDetailValue(for: id, displayValue: value))
    }
  }

  private var resetText: String {
    guard let snapshot = monitor.state.snapshot else {
      return "--"
    }
    return DisplayFormatters.reset.string(from: snapshot.resetsAt)
  }

  private var lastCheckText: String {
    guard let snapshot = monitor.state.snapshot else {
      return "--"
    }
    return DisplayFormatters.time.string(from: snapshot.checkedAt)
  }

  private var sourceText: String {
    DisplayFormatters.sourceLabel(monitor.sourcePath)
  }

  private func rawDetailValue(for id: String, displayValue: String) -> String {
    if id == "sourcePathValue" {
      return monitor.sourcePath
    }

    return displayValue
  }
}
