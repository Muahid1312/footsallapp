> Phase 2 match-engine reference. Version 3 adds audited competition result reopening and fixture cancellation; see [Phase 3](phase3.md) for the current rules and validation status.

# Phase 2 — match engine

## State and timing

`matches.phase` is the canonical v2 state: scheduled, live, paused, finished (plus
legacy cancelled records). The v1 `status` column stays synchronized as
scheduled/live/completed/cancelled because its original CHECK constraint remains
intact. Only one match can be live on the device at a time. Multiple scheduled or
paused matches are retained. Finish is explicit and confirmed; timer expiration
clamps playing time, disables new play events, and never awards a result itself.

`match_timer_state` stores accumulated milliseconds, a UTC timestamp, a monotonic
anchor, a process UUID, and a recovery-review flag. Android's native
`SystemClock.elapsedRealtime()` includes device sleep. A small MethodChannel
adapter samples it during repository reads and lifecycle operations, then
extrapolates with a Stopwatch between samples. Within a process, device wall-clock
changes do not alter elapsed playing time. Periodic UI ticks only repaint and
checkpoint; they are never the clock source. Events, substitutions, five-second
Match Center checkpoints, and app lifecycle transitions persist timer progress.

After a cold restart, a live match recovers a duration-bounded UTC estimate and
**pauses with an audit entry**. The administrator must review the elapsed time
before resume or finish. Backward-clock recovery retains the last checkpoint;
forward-clock estimates are capped at match duration. Review cannot put the clock
before already recorded play/substitutions. An already-paused match stays paused
without accruing background time. There is no automatic foreground service or
background alarm. Optional haptic feedback occurs while the Match Center is open.
The native Android clock path remains unverified until an Android build/device test.

## Lineups and scoring

Starting lineups contain 1–5 selected roster members per side. Other members stay
on the bench. `match_lineup_stints` records exact playing-time intervals; a
substitution closes an outgoing stint and opens the incoming teammate's stint in
one transaction. Opposing-team swaps, benched scorers, and invalid substitutes
are rejected. Finished appearances count only players with participation records.

A goal has one scorer and an optional different assisting teammate. Both must be
on field at the event time. The assist is a field on the goal, never a separate
scoring event. A foul has an on-field offender and optional notes. Team foul counts
are derived from non-voided player fouls. No automatic penalties or disciplinary
rules are inferred.

Goal/foul entry captures playing time when the dialog opens, not after typing.
A valid observation before expiry can be confirmed after the countdown reaches
zero while the match remains live. Future or out-of-duration timestamps and any
new play on a finished match are rejected.

The scoreboard and summaries derive from valid non-voided `match_events`.
Corrections validate participation at the **original goal time**, not today's
on-field lineup. Archived players retain their historical identity and statistics.
Career totals only include finished matches and verified participation. Own-goal
semantics from v1 remain readable: the recorded team is the offending team and the
opponent receives the goal; there is no new own-goal/card entry UI in this phase.

## Immutable corrections and idempotency

`match_actions` is an immutable audit timeline. It records start, pause, resume,
finish, play events, substitutions, recovery, review, undo, and corrections. Timeline
order follows append order, so changing a device clock cannot reorder actions.
Each row displays elapsed match time and relevant player/team; corrections link
back to the original event time and leave the old record visibly voided.

Undo appends a unique target reference. Correcting a goal inserts its replacement
and an action linking the original in a transaction; neither record is overwritten.
Unique targets prevent double-undo, unique action/event IDs prevent duplicate
processing, and a unique finish action prevents duplicate results. Idempotency keys
also store canonical payloads: reusing a key for another action is rejected.
Dialogs block repeated confirmation, and Match Center controls lock during saves.

Finished/cancelled matches are read-only. Direct SQL guards reject subsequent event,
audit, roster, timer, and result changes. New matches freeze team identities and
memberships. A session can be completed after all of its matches are finished or
legacy cancelled; scheduling on completed sessions is rejected.

## Migration 1 → 2

The migration is additive and transactional. It adds `matches.phase`, precise event
milliseconds, four new tables, indexes, and integrity triggers. Existing players,
attendance, memberships, teams, matches, event IDs, and foreign keys remain intact.
An integrity check rejects invalid historical references instead of resetting data.

Legacy live matches become paused and require timer review. V1 did not model
lineups or trustworthy timer anchors, so imported participation is limited to the
actual instants evidenced by existing scorer/assist events. It is not expanded into
invented full-match appearances or playing minutes. Legacy elapsed time is the
latest recorded event time, explicitly identified in the summary. A legacy match
with no recoverable on-field lineup can be reviewed and finished, but cannot resume
as though a starting lineup had been saved. New matches have full interval tracking.

## Verification and remaining scope

Executed: `python3 tool/check_sql_schema.py` — nine passing SQLite contract tests.
Dart files parse/format through `dart_style` WASM. Attempted `flutter analyze` and
`flutter test test/match_engine_test.dart` both fail during SDK download with HTTP
403 for `storage.googleapis.com`; neither analysis nor Flutter tests actually ran.
An APK build, native clock test, and Android launch are still pending.

After applying the saved network draft, follow the root README's commands and:

1. Register at least six players and create a session with two teams.
2. Schedule a match; leave a player on each bench when selecting starters.
3. Start, record a goal with assist, record a foul with notes, and substitute.
4. Correct a scorer, undo an event, and confirm score/foul totals and audit entries.
5. Pause/resume; background and lock the device, then check time after returning.
6. Kill and reopen the app. Verify recovered pause/review and restored lineups/events.
7. Finish explicitly; reopen the summary and verify scoring and player totals.
8. Confirm a second session preserves the first session's historical rosters.

No rotation scheduling, penalties/tie-break rules, ratings, leaderboards, collages,
cloud services, post-finalization editing, match deletion/cancellation UI, or timer
extensions were added. A mistakenly scheduled match must currently be resolved
before the session can be completed. Release signing and backup/export are also
outside this phase. The app cannot be called Android-ready until Flutter analysis,
tests, APK build, and the device smoke test pass.
