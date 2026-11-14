# Phase 3 — competitions, rotation, and standings

This documents the Phase 3 rules retained in the current application. Phase 4
adds balancing and analytics with database version 4; see [phase4.md](phase4.md)
for the current schema and verification status.

The existing player/team/session features and Phase 2 match engine are reused.
No backend or new package dependency is introduced. Flutter/Android validation
remains blocked by SDK artifact access; the application is not Android-verified.

## Administrator workflow

Open a Saturday session → Create competition. All saved session teams enter in
saved order (the repository also supports selecting a subset). Configure mode,
match duration, W/D/L points (default 3/1/0), cycles or winner-stays match count,
draw rotation, and championship criterion. Save a draft, edit its rules if needed,
then explicitly generate fixtures and activate. Settings lock at activation.
Only one draft/active competition may exist in a session; completed competitions
remain available independently. Sessions cannot be locked while a competition is open.

The competition dashboard shows session date, rules, team colors, current and next
match access, fixture progress, the pitch/waiting queue, a horizontally scrollable
standings table, fixture actions, administrative history, and the final champion
or explicitly shared championship. Generated fixtures open the existing Match
Center with their actual teams and configured duration. No second match is created
on start. Compatible unlinked, unplayed scheduled matches are adopted, including
reversed team order; existing pending rotation matches are reused.

## Round robin

The deterministic circle algorithm handles even and odd team counts. Every pair
plays once per cycle; supports 1–10 cycles and the session's practical 2–32 teams.
Three teams follow A–B, B–C, C–A. Four teams produce six unique pairings per cycle.
Odd schedules have a bye each round; the dashboard shows it. One-pitch ordering
prefers teams that rested in the previous fixture when a choice exists. Rest is
not promised to be equal at every point in a single-pitch schedule.

Generation is transactional and idempotent. A normalized pair/cycle key prevents
duplicate league fixtures in SQLite. Active schedules cannot be regenerated over
played matches. Postponement keeps the same match ID and blocks its start until
restored. Cancel only unplayed fixtures, with a reason. Cancelled required league
fixtures require explicit early completion rather than silently counting as draws,
losses, or a completed full cycle.

## Winner stays

The winner stays; the loser joins the FIFO waiting queue tail and its head enters.
Two teams may rematch. Every waiting team gets a turn even if another team keeps
winning. The configured number of league matches is 1–100; the final match does
not create an unnecessary next fixture.

Draw policies never award a win:

- Both rotate when two waiting teams are available. With only one waiter, fall
  back to longest current playing tenure; with none, rematch.
- Longest-playing team rotates. Current consecutive tenure is tracked by entry
  sequence. Equal tenure rotates the first team in the persisted playing order,
  a rule shown before activation.
- Administrator decides: persist a pending decision and do not schedule another
  match until the administrator selects a stayer or both-rotate option with reason.

Queue/current pairing, entry tenure, before/after rotation states, and decisions
persist in SQLite. Cancelling a pending rotation leaves it cancelled; an explicit
Restore next rotation fixture action can schedule the same selected pairing again.
A postponed pairing must instead be restored through its own fixture action.

## Standings and championship

Standings derive from finished league fixtures and the match event ledger, excluding
voided goals, unfinished/cancelled games, and championship playoffs. Columns: shared
position, team, played, won/drawn/lost, goals for/against/difference, and points.
Permanent player statistics continue to derive separately from actual match
participation and events; no mutable team totals are copied to player records.

Default ranking is points → goal difference → goals scored → head-to-head mini-table
(points/GD/GF) only when all pairs in the tied group played equally often and at
least once. Remaining ties share positions. Input order only controls display order
inside an unresolved tie and never selects its champion.

Round-robin titles follow these rankings. Winner-stays titles use the criterion
shown before activation: most match wins or most competition points; equal criterion
values remain tied regardless of the display table's other sorting columns.

The administrator explicitly completes the competition. A unique leader can be
confirmed; unresolved leaders require a shared title or a reasoned selection from
those leaders. A two-team championship playoff is also supported, including a replay
after a drawn playoff. Larger tied groups use shared/manual decisions; automatic
multi-team playoff brackets are not implemented. Playoff scores do not modify league
standings. No champion is finalized with an open live/paused match. Unfinished required
fixtures need the explicit End early checkbox and reason; remaining unplayed matches
are cancelled atomically. At least one league match must have finished.

The immutable champion decision stores eligible leaders, selected team or shared
result, method, reason, early-ending flag, final standings snapshot, and timestamp.
Completed competitions and their results are read-only.

## Atomic finalization and corrections

Phase 2 finish runs fixture finalization, result application, rotation advancement,
and next-match scheduling inside the same Drift transaction. `(match_id, revision)`
uniqueness prevents duplicate application. Replayed requests cannot create extra
fixtures or advance the queue twice. All scheduled/live/paused/finished states remain
on the original match IDs. Timer recovery and event/substitution data are preserved.

To correct a finished competition result, use Correct result / Correct competition
result and enter a reason. Only active competitions can reopen results. The audited
reopen increments the result revision, pauses result review without resuming playing
time, reverses the prior rotation application, and cancels only dependent unplayed
fixtures as superseded. These superseded fixtures no longer count as required games.

Use the existing immutable goal/foul undo and scorer/assist correction workflow.
A missing goal can be added at an explicit original playing time, with participating
scorer/assister and correction reason. Re-save the final result; standings and rotation
are recalculated once for the new revision. Original goals, void links, prior finish
records, reopening reasons, and result application records are retained.

Winner-stays permits reopening only before a later rotation match has been played.
An open other match also blocks reopening. Round-robin league results cannot be
changed after a dependent playoff has been played; later played playoffs protect
earlier playoff results. This deliberately refuses retroactive history rewrites.
A completed championship cannot be reopened in this phase.

## Database version 3

Version 3 migrates both version 1 and 2 databases transactionally, without deleting
or rebuilding their tables or changing old IDs, timers, rosters, or event relationships.
New tables: `competitions` (settings + current rotation JSON), `competition_teams`
(ordered selection), `competition_fixtures`, `competition_applications` (revision and
rotation snapshots), `competition_admin_actions`, `champion_decisions`, `match_reopens`.
Matches and match actions receive result revision columns. The finish uniqueness
index now includes result revision; reopening is restricted by explicit audit rows
and active-competition guards. Existing zero-revision matches remain read-only.

Composite foreign keys reject cross-session teams. Unique indexes enforce one open
competition per session, one fixture per match, unique round-robin pair/cycle keys,
one draw decision per result revision, and one result application per revision.
Triggers protect settings, fixture identity/state, result applications, champion
choices, and audit history. Foreign-key checks run during migration. No destructive
reset or migration-time data clearance is used.

## Checks and run commands

Executed: `python3 tool/check_sql_schema.py` — 15 passing SQL contract tests against
the actual migration/schema and prepared repository SQL. This is supplementary
SQLite validation, not a run of the Dart business logic or Flutter application.
Dart parsing/formatting also passes with a WASM port of `dart_style`.

Defined Flutter tests cover all requested rule categories: two/three/four teams,
odd byes, cycles, draw/win rotations, two-team rematches, FIFO fairness, standings,
GD/head-to-head/shared ties, champion/playoff selection, idempotent finalization,
fixture management, audited revisions, reopening actual database files, and v2→v3
preservation. The widget tests add dashboard → generated fixture → Match Center.

`flutter analyze` and targeted competition tests were attempted, but both stopped
before executing because the Dart SDK download from `storage.googleapis.com` is
blocked (HTTP 403). After applying the saved environment network draft, use the root
README's SDK exports and run:

```sh
flutter pub get
flutter analyze
flutter test test/competition_test.dart test/competition_migration_test.dart
flutter test
flutter build apk --debug
flutter run -d <android-device-id>
```

Required device smoke test: create three teams, activate each mode in separate
competitions/sessions, play with the existing timer and events, verify queue/standings,
postpone/restore/cancel a fixture, exercise a draw decision, correct and re-finalize a
result, complete a tied/untied title, restart during live play, and reopen older
session/competition history. Flutter tests, APK build, native clock checks, and Android
launch remain unverified. Ratings and leaderboards were added subsequently in
Phase 4. Collages, cloud sync, backup systems, and advanced multi-team playoff
brackets remain outside the implemented scope.
