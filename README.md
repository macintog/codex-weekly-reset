# Codex Weekly Reset

A compact macOS menu bar utility for watching the main Codex weekly limit.

This is an independent utility. It is not affiliated with, endorsed by, or supported by OpenAI.

It reads Codex rate limits through the local `codex app-server` JSON-RPC protocol and tracks the main `codex` bucket's weekly window. The menu bar shows weekly remaining as `100 - usedPercent`, using nine slots. macOS notifications fire after the first baseline read when quota crosses 20%, drops below 10%, reaches 0%, or increases by an indicator slot.

The app does not read usage data from Codex session files, private disk caches, or its own persisted snapshots. Notification deltas use an in-memory baseline from the current app run. If the live app-server read fails, the popover reports the failure instead of falling back to a cached estimate.

The standalone shell CLI is not required. The resolver uses an explicit launch argument or environment override first, then `PATH`, then the executable bundled inside an installed `Codex.app`.

## Run

```bash
./script/build_and_run.sh
```

The same script builds a SwiftPM executable, stages `dist/Codex Weekly Reset.app`, injects the project-global build number, and launches the app bundle.
It also packs `Resources/AppIcon.iconset` directly into `Contents/Resources/AppIcon.icns` without recompressing the optimized PNG entries.

Useful modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --developer-id
```

`--developer-id` stages the app without launching it and signs it with the Developer ID identity provided in `CODEX_WEEKLY_RESET_DEVELOPER_ID_APPLICATION_IDENTITY`.

## App Icon

`Resources/AppIcon.iconset` is the icon source of truth. Use `script/pack_icns.py` when an ICNS artifact is needed:

```bash
python3 script/pack_icns.py Resources/AppIcon.iconset /tmp/AppIcon.icns
```

Do not regenerate this icon with `iconutil` unless the larger recompressed output is intentional.

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
