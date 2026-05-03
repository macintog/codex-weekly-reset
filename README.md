# Codex Weekly Reset

A tiny macOS menu bar app for answering two important questions: how much weekly Codex rate-limit capacity do you have left, and when did Tibo reset it?

It sits up top with a little ring and a percentage, so you can glance at your remaining weekly Codex capacity without opening the app, running a command, or doing the sad mental math yourself. It’s not trying to be a control center. It’s more like a kitchen timer for your AI budget.

The reset notifications are the real magic trick: leave it running, and it can nudge you when capacity comes back instead of making you check manually like a person living in a spreadsheet. It also warns you when you’re getting low, when you’re nearly out, and when the tank hits empty.

Under the hood it asks Codex for the live weekly limit instead of guessing from logs or old snapshots. If that read fails, it says so. No pretend numbers, no spooky cache confidence.

This is an independent utility. It is not affiliated with, endorsed by, or supported by OpenAI.

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

`--developer-id` stages the app without launching it and signs it with the Developer ID identity provided in `CODEX_WEEKLY_RESET_DEVELOPER_ID_APPLICATION_IDENTITY`.

## Test

```bash
swift test
```

Fixture mode is available for deterministic UI checks:

```bash
CODEX_WEEKLY_RESET_FIXTURE=/path/to/rate-limits.json ./script/build_and_run.sh --verify
```

## Public Surface

- `Sources/CodexWeeklyReset`: app implementation
- `Tests/CodexWeeklyResetTests`: behavior tests
- `Resources/AppIcon.iconset`: icon source
- `script/build_and_run.sh`: local build, bundle, sign, and launch helper
