# Codex Weekly Reset

A native macOS menu bar app for seeing how much weekly Codex capacity remains, when the regular reset happens, and whether a banked reset is about to expire.

![Codex Weekly Reset website showing the app preview and download button](website/assets/codex-weekly-reset-website.png)

It stays in the menu bar with a small status ring and your remaining weekly percentage. Open the popover for the regular reset time, available banked resets, and the next banked-reset expiry.

Notifications cover the moments worth interrupting you for: low capacity, an exhausted limit, restored capacity, and a banked reset that will expire in one day or one hour. Alert-state expiry times use “today” and “tomorrow” so the deadline is immediately clear.

The app reads the live Codex app-server response instead of inferring limits from logs or old snapshots. If that read fails, it says so instead of showing a stale number.

Signed automatic updates are built in. Scheduled checks stay quiet in the background; you can also check on demand from the popover.

This is an independent utility. It is not affiliated with, endorsed by, or supported by OpenAI.

## Download

[**Download Codex Weekly Reset 0.1.2**](https://macintog.github.io/codex-weekly-reset/downloads/CodexWeeklyReset.zip)

Requires macOS 14 or later. The release app is Developer ID signed, Apple-notarized, and stapled. See the [0.1.2 release notes](https://github.com/macintog/codex-weekly-reset/releases/tag/v0.1.2).

## What’s New in 0.1.2

- **Banked resets at a glance.** See the available count and next expiry beside the regularly scheduled weekly reset.
- **Warnings before a reset expires.** The expiry row turns amber within 24 hours and red within one hour. Every launch shows the currently eligible warning, without repeating it during that run.
- **A clearer, more accurate popover.** Quota and reset information lead the hierarchy, the progress ring reflects the exact percentage, and the popover stays aligned beneath its menu bar item.
- **Reliable reporting with current Codex releases.** Weekly capacity and reset timing load from the current live response format.
- **Automatic updates.** Future signed releases can install through the app, with a manual check available in the popover.

## Run

```bash
./script/build_and_run.sh
```

Useful modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --developer-id
```

`--developer-id` stages the app without launching it and signs it with the MacTC-style Developer ID defaults. Override with `CODEX_WEEKLY_RESET_APPLE_TEAM_ID` or `CODEX_WEEKLY_RESET_DEVELOPER_ID_APPLICATION_IDENTITY` when needed.

## Test

```bash
swift test
```

Fixture mode is available for deterministic UI checks:

```bash
CODEX_WEEKLY_RESET_FIXTURE=/path/to/rate-limits.json ./script/build_and_run.sh --verify
```

## Source Of Truth

- `PROJECT_CONTINUITY.md`: durable product intent
- `CHECKPOINT.md`: current handoff
- `AGENTS.md`: repo-local working rules
- `.codex/indexes.toml`: code and docs indexing contract
