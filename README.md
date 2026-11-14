# Saturday Futsal

An offline, single-admin Android futsal app using Flutter, Material 3, Riverpod,
GoRouter, and Drift/SQLite. The existing five-phase implementation now includes
players, attendance, sessions, saved teams, a live match engine, competitions,
standings/champions, balancing, careers, leaderboards, MVP, winner posters, CSV
import, local settings, and staged backup/restore. No account or backend is required.

**Personal-testing APKs are available.**
[Download ARM64 APK](https://github.com/Muahid1312/footsallapp/releases/download/debug-2c2cb54/app-arm64-v8a-debug.apk)
for most Android phones, or choose another architecture from the
[testing build](https://github.com/Muahid1312/footsallapp/releases/tag/debug-2c2cb54).
GitHub Actions completed clean Dart analysis, **145 passing Flutter tests**, and
the three debug APK builds. The downloaded ARM64 APK's signature/package were verified.

**Production release verdict: NO-GO.** These artifacts use development signing;
private release signing and physical Android acceptance remain outstanding. The
local cloud still blocks SDK bootstrap with HTTP 403 from `storage.googleapis.com`;
the successful checks/builds ran on GitHub's runner. Review/save the saved network
draft for local development; a draft save does not apply or publish the environment.

See [Phase 5 delivery and release notes](docs/phase5.md),
[balancing/statistics/MVP rules](docs/phase4.md),
[competition rules](docs/phase3.md), and [match engine rules](docs/phase2.md).
The [Phase 1 notes](docs/phase1-foundation.md) are historical.

GitHub Actions runs analysis/tests and builds development APKs on pushes to main.
Each run publishes a clearly labeled **personal testing prerelease** with build
reports and any successfully built architecture-specific debug APKs. Failed checks
remain a failed workflow result. These artifacts use development signing and do
not change the production release verdict; see the exact run's status report.

## Current workflows

- Create/edit/search/archive players, with photos, primary/secondary positions,
  goalkeeper eligibility, preferred foot, manual 1–10 ratings, and rating history.
  Ratings never change automatically from match results or awards.
- Create independent Saturday sessions, choose attendance and 2–32 teams, then
  use random/manual editing or the seeded balanced preview, persistent locks,
  swaps, strength estimates, warnings, and explicit roster confirmation. Every
  match record, including a scheduled one, freezes historical rosters.
- Schedule matches and choose starters/bench; run the scoreboard, persistent
  countdown, goals/assists/fouls, substitutions, timeline, undo/corrections, and
  finalized summaries. Restart recovery requires timer review when appropriate.
- Generate round-robin fixtures or FIFO winner-stays rotation; manage fixtures,
  standings, draw decisions, shared/manual/playoff championships, and audited
  result revisions without rewriting played rotation history.
- Inspect actual participation-based careers, W/D/L, rates, recent matches,
  historical sessions/teams and lightweight trends; filter tied-rank leaderboards
  and configure minimum appearances. Confirm/override calculated session MVPs
  with immutable weights/source snapshots after session completion.
- Completed competition → **Create winner poster**: three original styles,
  real champion-team portraits, initials fallback, manual ordering, multi-page
  squads, exact 1080×1350/1080×1920 PNGs, Android save picker and share sheet.
- Player form → gallery/camera and crop adjustment; Android stores optimized
  1000-pixel JPEGs privately. Players → **Import from CSV** maps Google response
  sheet columns, previews values/duplicates, and safely creates or updates IDs.
  Drive photo links require manual assignment and are never scraped/downloaded.
- Dashboard → **Settings & local data**: persisted defaults, complete SQLite/photo
  backup, checksum/schema validation, confirmed staged restore, previous-data
  recovery, app version, and privacy. Restored live matches reopen paused for review.

## Run and verify

Use Flutter **3.35.7 stable** / Dart 3.9, JDK 17/21, Android platform 36,
NDK 27.0.12077973, Gradle 8.12, AGP 8.9.1, Kotlin 2.1.0; minimum API 24.
The pinned Flutter source and Android SDK/NDK are installed, but Flutter's Dart
and engine artifacts are unavailable until the network policy is applied.

```sh
cd /workspace/footsallapp
export PATH="/workspace/toolchains/flutter/bin:/workspace/toolchains/android/platform-tools:$PATH"
export ANDROID_HOME=/workspace/toolchains/android
export ANDROID_USER_HOME=/workspace/toolchains/android-user
export PUB_CACHE=/workspace/toolchains/pub-cache
export GRADLE_USER_HOME=/workspace/toolchains/gradle-cache

bash tool/cloud_setup.sh
flutter pub get                     # generate/review the application lockfile
flutter analyze
flutter test test/player_import_test.dart test/poster_photo_test.dart test/portable_zip_test.dart test/backup_restore_test.dart test/phase5_migration_test.dart test/saturday_acceptance_test.dart test/widget_test.dart
flutter test                        # one full regression pass after targeted success
flutter build apk --debug           # personal development testing
flutter devices
flutter run -d <android-device-id>
```

Use your local SDK paths on another machine. ADB also needs a writable native
configuration directory; this instance currently fails to create
`/home/agent/.android`, so device discovery is unverified. Do not claim a device
launch from an APK build alone. No server or Drift code generation is required.
Flutter creates ignored `android/local.properties` when its tooling initializes.

After supplying a private release keystore and passing validation:

```sh
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

The release path above is expected output, **not an existing artifact**. Signing
uses ignored `android/key.properties` or the four documented `FUTSAL_*` variables;
see [signing and installation](docs/phase5.md#release-signing-build-and-installation).
Release packaging refuses missing signing configuration and never silently uses
a debug key. A local universal debug build would produce
`build/app/outputs/flutter-apk/app-debug.apk`; CI uses `--split-per-abi` and publishes
the architecture-specific APKs linked above. They are for development testing.

## Evidence and limitations

Executed: `python3 tool/check_sql_schema.py` — **27 passing SQL contract tests**.
These execute actual schema/migration/restore SQL and include retained phases,
v5 preservation/settings, committed WAL snapshots versus an uncommitted writer,
and restore timer pausing without changing events. All **79 Dart files** parse
and format with a WASM port of `dart_style`; Android XML also parses.

Verified on [GitHub Actions run 43621338876](https://github.com/Muahid1312/footsallapp/actions/runs/43621338876),
application commit `2c2cb54`: `flutter analyze` reports no issues; all **145 Flutter
tests pass**; `flutter build apk --debug --split-per-abi` produces ARM64, ARMv7,
and x86_64 APKs. The committed dependency lock matches the build. Native tools
verify the downloaded ARM64 APK's v2 Android Debug signature, package
`com.saturdayfutsal.app`, display name, and minimum API 24.

The full Saturday data simulation passes, including poster export, backup,
restore, and reopening persisted records. All 19 physical Android acceptance steps
remain unrun. Local cloud Flutter/release attempts still stop at SDK bootstrap;
private release signing is absent. Unit/widget tests and a signed debug APK do not
establish on-device camera/share/lifecycle behavior, visual quality, or production
readiness. See [build verification](docs/build-verification.md) for exact artifacts
and [Phase 5 limits](docs/phase5.md) for remaining product constraints.

## Files and data

- `lib/app/`: providers, maintenance state, lifecycle timer checkpointing.
- `lib/core/database/`: SQL-managed Drift schema and additive v1–v4 → v5 upgrades.
- `lib/core/storage/`: atomic active-store selection, Android file channel adapter.
- `lib/core/theme/`, `routing/`, `widgets/`, `utilities/`: shared UI/navigation.
- `lib/features/players/`, `sessions/`, `teams/`: foundation, photos and balancing.
- `lib/features/matches/`, `competitions/`, `statistics/`: existing engine and analytics.
- `lib/features/posters/`: confirmed champion source, Canvas renderer, Winner Studio.
- `lib/features/importing/`: bounded CSV parser, preview, transactional import.
- `lib/features/backup/`: streaming ZIP, canonical schema validation, staged restore.
- `lib/features/settings/`: persisted defaults and local-data controls.
- `android/app/src/main/kotlin/com/saturdayfutsal/app/MainActivity.kt`: retained native
  clock plus SAF save/select, private share URIs, and JPEG compression.
- `test/`: database/rules, migrations, photos/posters, import, archive/restore,
  restart, Saturday data simulation, and widget tests.
- `tool/`: repeatable cloud setup and supplementary SQL contracts.

Schema **5** adds preferred foot and `app_settings` to the retained v4 rating/lock/
MVP and analytics schema. It preserves players, photos, attendance, rosters,
match events/timers/audit records, competition histories, champions, and MVPs.
Statistics remain derived. Tables use explicit Drift-managed SQL; `allTables` is
intentionally empty. Do not use generated `createAll`, implicit table streams,
or destructive resets. Foreign-key checks run during migrations.

All ordinary app data stays on the device; clearing app storage or uninstalling
removes it. Android cloud backup is disabled. Exported backups contain player
photos/history and are not encrypted. Restore validates before switching data and
keeps the previous local generation for explicit recovery. See Phase 5 limits for
archive sizes, retained working files/generations, missing photos, strict schema
compatibility, and supported formats. Public distribution remains blocked by the
unexecuted Flutter/Android checks and missing private signing configuration.
