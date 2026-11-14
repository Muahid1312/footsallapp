# Phase 5 — posters, photos, import, backup, settings, and Android release

**Release verdict: NO-GO.** Source implementation is present, but Flutter type
analysis, Flutter tests, Android packaging, and device acceptance are unverified.
The Dart SDK download from `storage.googleapis.com` still returns HTTP 403.
Release signing credentials are absent. No APK has been generated.

## Delivered source and entry points

- Completed competition → **Create winner poster** → `/competitions/:id/poster`.
  Only the immutable confirmed champion decision supplies eligible teams. Shared
  titles allow each confirmed co-champion, always labeled **Shared Champions**.
- Player form: gallery, camera when supported, square crop/zoom/position adjustment,
  replacement/removal, preferred foot, and existing rating/position controls.
- Players → **Import from CSV** → `/players/import`: select, map columns, inspect
  normalized records and duplicates, then confirm selected creates/updates.
- Dashboard settings icon → `/settings`: persisted defaults, backup/restore,
  previous-data recovery, app version, dark theme information, and local privacy.
- Existing sessions, balancing, live matches, event corrections, competitions,
  standings, champions, careers, leaderboards, and MVP workflows are retained.

Only one Flutter package is added: `crypto` for SHA-256 file checksums. Android
declares its direct AndroidX Core dependency for FileProvider. Image picking,
Flutter Canvas, SQLite, state management, navigation, and design tokens are reused.
There is no backend, Google authentication, tracking, or online poster dependency.

## Original poster designs and exports

`PosterRenderer` draws original vector trophy artwork and typography onto a
full-resolution Flutter Canvas. The three designs are:

1. **Champions Night**: navy/black gradient, gold accents, stadium-inspired beams,
   subtle light particles, large championship lettering, and portrait rings.
2. **Matchday Victory**: team colors, diagonal graphics, bold championship type,
   and a centered portrait arrangement.
3. **Minimal Elite**: warm editorial background, restrained dark type, fine rules,
   balanced portraits, and whitespace.

Each includes the editable competition title, saved Saturday date, actual champion
team name, roster photos/names, original trophy, optional color accents, and an
optional summary derived from competition standings. A league summary is not
presented as a fictional final score. Shared champions are never promoted to a
sole winner by display order.

Exports are exact **1080×1350** portrait or **1080×1920** story PNGs. Larger squads
use pages of up to nine or fifteen players respectively; export every page to
include the whole squad. Manual ordering must contain every roster player exactly
once. Portraits use proportion-preserving square source crops and circular masks;
missing/damaged photos fall back to initials. Very long names may be ellipsized,
so the studio explicitly asks the administrator to inspect the preview.

One page is rendered at a time, with portraits decoded at a bounded target size;
native image/picture resources are disposed. Previews use reduced-resolution image
loading while exported files retain full dimensions. Changing options/order/page
requires rendering again before export. Save uses Android's system document picker;
share uses the Android share sheet and a private, narrowly scoped FileProvider URI.
Export does not itself send a message or upload anything.

## Persistent photo handling

`image_picker` supplies gallery/camera selection and Android lost-picker recovery.
Images are validated before storage, decoded at a bounded size, and adjusted in
`PhotoCropScreen` using zoom/horizontal/vertical controls. Faces are cropped rather
than stretched. Android stores 1000×1000 JPEGs at quality 85, copied into the active
application-managed `player_photos` directory with random names. Development tests
on non-Android platforms use PNG output. SQLite holds file references, not binaries.

Input is limited to 20 MB, 16 megapixels, and 16,000 pixels on either axis. Invalid
codecs, dimensions, and missing historical files fail safely or show avatar fallback.
No temporary picker path becomes a persistent profile reference. Existing photos
are retained privately when replaced/removed so an older retained data generation
is not broken. Current backups include only currently referenced available assets.
No automatic permanent photo garbage collection is introduced.

The release manifest has no Internet, broad storage, Google account, or camera
runtime permission. Gallery/camera apps and Android's system document provider
handle their own access. Camera behavior remains device-dependent and unverified.
Shared URI access is granted for the chosen export only; the provider exposes only
the share-cache directory, with old temporary share copies expired after seven days.

## CSV import rules

Export the linked Google response sheet as UTF-8 CSV. The parser handles BOM,
CRLF/LF, quoted commas, escaped quotes, and multiline quoted cells. Limits are
2 MB, 5,000 records, 100 columns, and 5,000 characters per cell. Malformed quoting,
unequal columns, empty input, invalid names, unsupported role/foot values, and
out-of-range jersey numbers produce visible errors rather than partial imports.

Map either full name or first/last name, preferred foot, position, jersey, and
optional photo-link columns. Common foot/position aliases normalize to the profile
options, including GK/Fixo/Ala/striker. Names match case-insensitively with normalized
spacing/common punctuation. Matching archived players and repeated CSV names are
also flagged. This is likely-duplicate detection, not proof of identity.

New valid records default to Create; duplicates default to Skip. Choose Update
and the existing identity explicitly. Only one selected row per normalized name
and one update per player can commit. All selected writes use one transaction;
stale existing profiles or newly detected duplicates roll it back. Updates preserve
IDs, archived state, ratings, photos, manual GK eligibility, and match/history data.
Unmapped/empty position, foot, and jersey values preserve existing values on update.
New profiles start with the disclosed administrator-review rating of 5.

Drive URLs are not fetched, scraped, or treated as public downloads. After import,
assign the photo manually from the player profile. Private Google integration and
automatic identity merging are outside scope. Unknown sheet values should be
corrected in the CSV or unmapped before importing.

## Backup format and consistent snapshot

`saturday_futsal_backup_YYYY-MM-DD.zip` is an app-specific, version-1 portable ZIP
using standard STORE entries. JPEG assets are already compressed. ZIP operations
stream files in an isolate rather than constructing the entire archive in memory.
It contains:

- `database.sqlite`: SQLite's consistent `VACUUM INTO` snapshot, including committed
  WAL data. The app checkpoints running clocks first; a live database is never
  copied directly while writes occur.
- `photos/<random-id>.<extension>`: available referenced photos, deduplicated by
  source path; snapshot references are rewritten to portable relative paths.
- `manifest.json`: format/app/schema versions, creation time, snapshot method,
  source-data counts, unavailable photo IDs, and every asset's size/SHA-256 checksum.

The physical snapshot includes all profiles/ratings, attendance, teams, timers,
events/corrections, competitions/standings source records, champions, MVP decisions,
injuries, and application settings. Derived views are preserved with their schema.
Missing source photos cannot be reconstructed; they are reported and restored as
fallback avatars without losing the corresponding player.

Bounds: 512 MB archive, 256 MB total stored content, 64 MB per file/database,
20 MB per photo, 1 MB manifest, and at most 4,096 entries. Backup creation/restore
rejects data exceeding these limits. These limits keep file handling bounded;
very large histories may require a future format revision.

Checksums detect accidental changes; they are not signatures or encryption.
The settings screen explicitly asks the administrator to save backups privately.

## Validated staged restore and recovery

Select an app backup through Android's document picker. Before current data changes:

1. Parse ZIP metadata and reject traversal/absolute/unknown names, duplicates,
   symbolic links, overlapping entries, excessive sizes, encryption, compression,
   ZIP64, and unsupported directory/comment forms. Verify ZIP CRCs while streaming.
2. Require the app's manifest/format and verify all declared SHA-256 hashes/sizes.
3. Accept supported source schemas 1–5 only. Compare all tables/views/indexes/triggers
   to the corresponding canonical app schema before querying views or migrating.
   Run SQLite integrity/reference checks. Arbitrary/custom SQLite schemas are rejected.
4. Migrate a private, isolated generation to v5, validate/decode its photos, remap
   references to that generation, and verify settings and database integrity.
5. Pause any restored live matches at their saved checkpoint, clear running anchors,
   require explicit timer review, and append an audited recovery action. Finished
   matches/events/results remain unchanged. This also applies within the same process.
6. Show counts, backup date, missing photos, running-match recovery information,
   and the replace-data warning. Require explicit confirmation.

On confirmation, recheck the staged file hashes, close the current database, and
atomically replace one flushed active-store selection file. Old database/photo
files are retained. Reopen Riverpod's database/repositories and return to the
dashboard. UI input and background checkpoints are paused during maintenance.

A failed validation leaves the current selection/database/photos intact. A failed
activation reopens whichever complete generation the atomic pointer selects.
Settings → **Recover previous local data** switches between retained generations
after another explicit confirmation, also pausing running matches for timer review.
Legacy installations remain in their original
documents directory until a restore; existing profiles are not relocated on upgrade.
Kept generations and working archives consume local storage and are not automatically
pruned. This is staged filesystem replacement, not a claim of immunity to hardware
failure or loss of app storage. Keep exported backups outside the app.

## Schema v5 and UI polish

Upgrades from v1–v4 run the necessary additive migrations transactionally. Version 5
adds `players.preferred_foot` (`unknown/left/right/both`, old records default unknown)
and one `app_settings` row. It does not delete/rebuild old tables, change IDs, clear
history, or generate duplicate career totals. Drift continues to manage explicit
SQL; no code generation or generated `createAll` is appropriate.

Settings persist match minutes, the initial generator-preview mode, competition
mode, W/D/L points, cycles, draw policy, and rotation match limit. New session forms
load duration/mode defaults; new competition forms load point/rotation defaults.
Existing sessions/results keep their saved rules. The established creation flow
still opens Team Builder with an initial random roster; the selected generator mode
is used when opening the explicit preview, which must be confirmed to replace it.
Only the existing dark theme is supported.

Polish includes lazy player-list rows, bounded avatar decode sizes, clear file/import
errors, scrollable confirmation dialogs, safe bottom/side insets, disabled controls
and back navigation during operations, and explicit empty/loading states. Existing
Match Center scoring controls, timer recovery, event timeline, standings scrolling,
and leaderboard thresholds are retained. Actual Android layout/gesture/font-scale
verification has not run.

## Executed checks and remaining acceptance

**Executed successfully:** 27 SQL contract tests, including all retained contracts,
v5 preservation/settings/foot validation, prepared repository/restore SQL, committed
WAL snapshots versus an uncommitted writer, and staged live-timer recovery SQL.
All 79 Dart files parse/format with a WASM port of `dart_style`; Android XML parses.
These are supplementary checks, not Dart type analysis or execution of Dart services.

**Attempted, exited 1 before execution:** `flutter analyze`, the combined Phase 5
and existing regression test command, and `flutter build apk --release`. All fail
at the unchanged SDK artifact HTTP 403. No Flutter test count is claimed as passed.
The full suite now defines **144 tests**, adding 38 in this phase: 11 CSV/import,
eight poster/photo, six ZIP, nine backup/restore, two migration/settings, one full
Saturday data simulation, and one settings/new-session widget test.

The Saturday simulation covers import, managed photo assignment, three balanced
teams, fixtures, timed events, standings/champion, MVP, PNG file export, backup,
restore, file reopening, and preserved source records. It is **defined but unrun**.
It does not verify Android gallery/camera, save picker, share recipients, or physical
process termination. Device discovery also failed because this instance's ADB could
not create `/home/agent/.android` on a read-only filesystem. Device availability
has therefore not been established.

All 19 requested Android acceptance steps remain **UNRUN**. After SDK access and
signing are resolved, execute the root README commands and test the full workflow
on a mid-range Android device in airplane mode, including background/process death,
timer review, cancelled export/picker flows, all three poster styles and both sizes,
missing photos, shared champions, multi-page squads, failed/corrupt restore, successful
restore, previous-data recovery, and restart preservation. Run one full regression
pass after targeted checks succeed; do not repeatedly retry the unchanged SDK block.

## Release signing, build, and installation

The display name remains **Saturday Futsal**, package `com.saturdayfutsal.app`,
version `1.0.0+1`, minimum API 24, with the existing original emerald football icon.
Flutter is pinned to 3.35.7; Android platform 36, JDK 17/21, NDK 27.0.12077973,
AGP 8.9.1, Kotlin 2.1.0, and Gradle 8.12 remain the prepared toolchain targets.

Release builds are non-debuggable and never fall back to debug signing. Configure
your private keystore locally using ignored `android/key.properties` keys
`storeFile`, `storePassword`, `keyAlias`, `keyPassword`, or the corresponding
`FUTSAL_KEYSTORE_PATH`, `FUTSAL_KEYSTORE_PASSWORD`, `FUTSAL_KEY_ALIAS`, and
`FUTSAL_KEY_PASSWORD` environment variables. No values are committed or printed.
All four environment values and the local signing file are currently absent.
Do not send signing passwords in chat.

After completing analysis/tests, build with `flutter build apk --release`.
Expected output **only after a successful signed build**:
`build/app/outputs/flutter-apk/app-release.apk`. It does not exist in this delivery.
Install with `adb install -r <path-to-generated-apk>`, or copy the signed APK to the
phone and explicitly allow installation from that source. Updates require the same
signing key as the installed app; preserve/export data before changing signing.
Do not uninstall merely to bypass a signing mismatch.

Personal development testing can use `flutter build apk --debug` and
`adb install -r build/app/outputs/flutter-apk/app-debug.apk` after dependencies work.
That is development signing and is not a public-distribution release. No debug APK
has been produced here either. A successful build would still require actual
launch/acceptance verification before changing the release verdict to GO.
