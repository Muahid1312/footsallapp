> Archived Phase 1 delivery notes. See [the current README](../README.md) and
> [Phase 3 competition documentation](phase3.md) for the current implementation.

# Saturday Futsal

An offline Android application for one administrator, one permanent squad, and
independent weekly teams. Phase 1 implements player and session management. There
is no login, backend, network API, scoring simulation, or invented match data.

## Current verification status

The application source, Android project, and focused Flutter tests are implemented.
**Android launch and Flutter test success are not yet verified.** The cloud
environment blocks `storage.googleapis.com`, which Flutter needs to download its
Dart SDK and engine. The domain addition has been saved in the environment draft;
review/save the network change in environment settings and publish the environment
before completing the commands below.

Independent checks completed during implementation:

- All 23 Dart files parsed and formatted with a WASM port of `dart_style`.
- Direct SQLite schema smoke checks exercised real inserts, foreign keys,
  constraints, captain rules, cross-session rejection, event validation, history
  locks, database reopening, and `PRAGMA integrity_check` / `foreign_key_check`.
- Gradle 8.12 wrapper JAR verified against the official SHA-256; distribution
  checksum is pinned in the wrapper configuration.
- Android platform 36, platform tools, and build tools 35.0.0 installed in the
  current cloud machine. These do not establish an APK build or device launch.

These checks supplement rather than replace Flutter analysis, tests, and a device
smoke test. `pubspec.lock` must be generated and committed after the first successful
dependency resolution. No successful dependency resolution is claimed yet.

## Run

Use Flutter **3.35.7 stable** (Dart 3.9), JDK 17 or 21, and an Android SDK. The
Android build uses Gradle 8.12, AGP 8.9.1, Kotlin 2.1.0, platform 36, NDK
27.0.12077973, and minimum Android API 24 (Android 7.0).

```sh
cd /workspace/footsallapp
# In this cloud machine, after the network prerequisite has been applied:
export PATH="/workspace/toolchains/flutter/bin:/workspace/toolchains/android/platform-tools:$PATH"
export ANDROID_HOME=/workspace/toolchains/android
export ANDROID_USER_HOME=/workspace/toolchains/android-user
export PUB_CACHE=/workspace/toolchains/pub-cache
export GRADLE_USER_HOME=/workspace/toolchains/gradle-cache

flutter --version
flutter doctor -v
flutter pub get
flutter analyze
flutter test test/database_test.dart
flutter test test/widget_test.dart
flutter build apk --debug
flutter devices
flutter run -d <android-device-id>
```

`flutter pub get`/the first Android build prepares ignored `android/local.properties`.
If invoking Gradle directly, set `flutter.sdk` and `sdk.dir` there first. No Drift
code generation step is needed. A connected Android device/emulator is required
for `flutter run`; none was available during implementation.

`bash tool/cloud_setup.sh` bootstraps or refreshes these toolchains in the cloud
workspace. It preserves existing application checkouts and verifies the Flutter
source pin. Its Flutter download steps remain blocked pending the network change.

The debug APK will be `build/app/outputs/flutter-apk/app-debug.apk`. Production
release signing is deliberately unconfigured; keep release signing credentials
outside version control. Release has no Internet permission. Debug enables it
only for Flutter's development service.

## Working features

- Charcoal and emerald Material 3 design, constrained responsive layouts, sports
  cards, subtle entrance animation, semantic action labels, and persistent bottom
  navigation.
- Dashboard: next Saturday, new session action, registered player count, saved session
  count, recent sessions, squad shortcut, and an honest unavailable-results state.
- Players: search name/position, add/edit, optional jersey number, position, skill
  rating, permanent photo copy, avatar fallback, profile details, archive/restore,
  and explicitly unavailable career statistics.
- Sessions: Saturday-only date selection, optional pitch, duration (1–180 minutes),
  round robin / winner stays configuration, selectable attendance, and 2–32 teams
  with at least one attendee per team. Rotation is configuration only in Phase 1.
- Teams: random even-as-possible initial distribution, regeneration with
  confirmation, manual moves and swaps, custom name, eight color choices, captain,
  persistent rosters, and clear uneven-squad warnings. All changes autosave.
- History: independent saved sessions, attendance and rosters, and an explicit
  completion confirmation that permanently locks a session's team history.

Suggested device smoke test: register five players (including a photo), create a
two-team Saturday session, check 3/2 distribution, move/swap players, rename a team,
select its captain/color, then force-stop and reopen the app. Confirm the same
rosters. Create a second session and confirm the first remains unchanged. Archive
a player and confirm historical rosters retain them. Complete a session and verify
it is read-only. This device check remains pending.

## Architecture and files

| Location | Responsibility |
| --- | --- |
| `lib/main.dart`, `lib/app/` | App entry, Riverpod dependencies, refresh boundaries |
| `lib/core/database/` | Drift connection, explicit SQL schema, migrations, transactions |
| `lib/core/theme/` | Material 3 sports colors, typography, controls |
| `lib/core/routing/` | GoRouter shell and detail/form routes |
| `lib/core/widgets/`, `lib/core/utilities/` | Shared cards, avatars, async/error states, dates |
| `lib/features/players/` | Player domain model, permanent photo store, directory/forms/profile |
| `lib/features/sessions/` | Session model, creation, saved history/details |
| `lib/features/teams/` | Team model, builder, roster and identity editor |
| `lib/features/matches/`, `statistics/` | Documented Phase 2 boundaries |
| `test/database_test.dart` | CRUD, persistence, session/roster integrity tests |
| `test/widget_test.dart` | Calendar helper and player registration/navigation smoke test |
| `android/` | Native activity, manifest, theme, launcher vector, Gradle build/wrapper |

The initially empty repository had no source files to preserve. All application
and build files are newly created. Dependencies are declared in `pubspec.yaml`;
there are no backend dependencies or external font downloads. The UI uses the
device's native sans-serif typography with explicit weights, spacing, and scale.

The database uses Drift's `GeneratedDatabase` connection API with explicit,
versioned SQLite DDL and parameterized queries. This avoids generated source and
keeps composite foreign keys and triggers together for review. `allTables` is
empty because the schema is SQL-managed: **do not use Drift's generated table
queries, automatic `createAll`, or generated table streams with this database**.
The UI observes Riverpod invalidation after successful writes. Domain objects
keep raw rows out of presentation code. Add repositories/services only when a
feature needs them rather than introducing an abstract layer for each query.

Schema version is 1. Creation executes every table, index, and trigger. Opening
always enables foreign keys. Future versions must add an explicit non-destructive
`onUpgrade` migration, schema tests, and reopen tests; unsupported upgrades fail
instead of resetting data.

## Database relationships and guarantees

| Table | Key relationships / checks |
| --- | --- |
| `players` | UUID; nonempty name; optional permanent photo path and jersey 0–99; skill 1–10; timestamps; archive flag |
| `sessions` | UUID; date, pitch, positive bounded duration, validated rotation/status, creation timestamp |
| `session_attendance` | Player + session foreign keys; unique `(session_id, player_id)`; available/absent |
| `session_teams` | Session foreign key; name/color; nullable captain; creation timestamp; composite `(id, session_id)` key |
| `team_memberships` | Player and composite team/session + attendance foreign keys; unique `(session_id, player_id)` and `(team_id, player_id)` |
| `matches` | Session + two distinct teams from that session; duration/status; ordered start/end timestamps |
| `match_events` | Match, participating team, optional scorer/offender and related teammate; event type/time; validated roster relationships |
| `injuries` | Player; optional session; description; occurred/recovered timestamps |

`team_memberships.session_id` is intentionally redundant: its composite foreign
key prevents attaching a membership to a team from another session. The unique
session/player constraint prevents duplicate team assignments. Memberships require
available attendance. Captains must be members of their own team. Repository
operations additionally require complete attendance coverage and nonempty teams.

Session creation, randomization, roster replacement, swaps, moves, and team edits
are transactional. Replacement validates the complete assignment before touching
data, clears captains, replaces memberships, then restores captains who stayed on
their team. No player is silently discarded or duplicated. New sessions create
new team IDs and never reuse old rosters. Multiple sessions may share a date and
remain independent.

Session dates are calendar-only values encoded as UTC midnight and decoded in
UTC, so a device time-zone change cannot move a saved Saturday to Friday.

Completed session teams, memberships, and attendance are locked with database
triggers. Teams referenced by a match cannot change membership. Match participants
cannot be rewritten. Foreign keys restrict destructive deletion of referenced
records. There is no destructive history-delete or player-delete UI.

For future scoring, a `goal` event's `player_id` is the scorer and
`related_player_id` is the optional assist. They must be different members of the
same participating team. A team-only event can omit the scorer. For `own_goal`,
`team_id` identifies the offending player's team; a future scorer must credit the
opponent. Fouls/cards use the offender's team/player and no assist. Event times
must be within match duration, and events cannot be updated in place. Phase 2
must design an explicit correction/deletion workflow, derive totals from actual
events and completed matches, and test scoring semantics before exposing results.

## Tests and remaining limits

The Flutter suite contains 16 database tests and 4 calendar/widget tests. It covers
player creation/update/archive, real file reopening, session creation/rollback,
seeded random generation, uneven distribution, larger team counts, no duplicate
assignment, moves/swaps, captain validation, invalid roster rollback, independent
history, completed-session locks, direct SQL constraints, and future event
relationships, session/team editing through the UI, and missing-photo fallback.
**These Flutter tests and `flutter analyze` have not run** because
the SDK bootstrap is blocked. The app must not be represented as Android-verified
until those commands and a device smoke test pass.

Local-only persistence survives normal process restarts and application updates;
uninstalling the app or clearing its storage removes its database and photos.
Android cloud backup is disabled to honor local-only storage. Export/restore,
injury management UI, match scheduling/scoring/timers, leaderboards, posters, and
cloud sync are outside Phase 1. Removed/replaced photo files are retained locally
to avoid deleting a potentially referenced file; photo garbage collection can be
added with explicit reference checks later. Team generation is random rather than
skill-balanced. Historical rosters retain player identity; profile name/photo
edits are shown across history rather than creating weekly profile snapshots.

Phase 2 has validated relationship definitions and clear feature boundaries, but
its implementation should start only after the pending Flutter/Android checks
have passed. It can add match scheduling and a tested event-based scoring service
without changing how independent weekly rosters are stored.
