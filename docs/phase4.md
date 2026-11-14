# Phase 4 — balancing, career statistics, leaderboards, and session MVP

This records the retained Phase 4 contract. The current app additionally includes
Phase 5 and database version 5; see [phase5.md](phase5.md) for current capabilities,
test counts, release status, and outstanding validation.

This extends the existing player/session/team foundation, match engine, and
competitions. It reuses Riverpod, GoRouter, Drift/SQLite, the design system, and
local photo storage. No package dependencies, backend, backup/restore system,
collages, or release packaging are added.

**Flutter/Android verification remains incomplete.** Both the Phase 4
`flutter analyze` and targeted test attempts stopped at Dart SDK bootstrap with
HTTP 403 from `storage.googleapis.com`. No Dart type analysis, Flutter tests,
APK build, or Android launch is claimed to have succeeded.

## Administrator workflow and screens

1. Edit a player to set overall skill (1–10), primary position, optional different
   secondary position, and goalkeeper eligibility. Ratings are manual; goals,
   wins, injuries, and MVP awards never update them automatically.
2. Create a Saturday session with the selected attendees and 2–32 teams, the
   existing application limit. The pure solver supports any team count >=2 with
   at least that many selected players. Each team must contain at least one player.
3. Team builder → **Balanced preview & player locks**. Select balanced/random
   mode, a seed, and a swap-attempt limit. The preview shows photos, names, roles,
   skill, size, average skill, estimated strength, goalkeeper counts, quality,
   and warnings. Regenerate increments the seed; **Generate with exact seed**
   reproduces the configured input. Tap an unlocked player to swap across teams.
4. Lock/unlock an assignment to persist it for later generation. A lock is a
   generator instruction; it does not itself save the preview's roster. Choose
   **Confirm teams** to save validated assignments transactionally. Leaving the
   preview without confirmation leaves the saved roster intact, while explicit
   lock edits persist. The original random/manual team builder remains available.
5. Profile → **Career, trends & history** shows career totals/rates, recent
   finalized matches, all recorded Saturday attendance and historical teams,
   and immutable rating changes. Charts show goals/session, assists/session,
   recent match G+A, and cumulative appearances with labeled zero-based bars.
6. Open leaderboards from the dashboard or a session. Choose all time, a Saturday
   session, or the last four played sessions, then goals, assists, appearances,
   wins, goals/match, or assists/match. Session goals supply session top scorers.
7. Session → **Session MVP** shows configurable weights, every eligible
   candidate's contribution breakdown, calculated leader(s), and saved decisions.
   Complete the session and its competitions before confirming a final award.
   Confirm the calculated leader, share tied leaders, or choose another eligible
   participant with an optional reason. Later changes append immutable revisions.

The new routes are `/sessions/:id/balance`, `/players/:id/analytics`,
`/statistics?session=<id>`, and `/sessions/:id/mvp`. Player forms/profiles,
team builder, dashboard, and session details are extended using existing components.

## Deterministic bounded balancing

The pure `generateBalance(BalanceRequest)` function is reproducible for the same
ordered inputs, locks, options, and random seed. Balanced generation runs through
Flutter `compute` outside the UI isolate; the repository reads inputs in a
transaction, then verifies their fingerprint again on confirmation.

Hard constraints: exact selected-attendee membership, no duplicates/absentees,
all teams nonempty, all locks honored, and a size difference <=1. Infeasible locks
produce an actionable error. The administrator must explicitly enable the uneven
override to relax size balance; membership, locks, and nonempty teams still apply.
Direct roster writes and manual moves enforce the same default size limit.
Swaps preserve an already accepted size distribution.

Capacities start at floor/ceiling(N/teams), accommodating locks and allocating
the extra slots with the seeded order. With the explicit uneven override,
capacity is transferred only as necessary for locks while keeping teams nonempty.
Balanced mode greedily places eligible keepers first, then descending skill with
seeded tie ordering. For <=10 players and <=4 teams it also explores assignments
with capacity and equivalent-empty-team pruning, capped at 20,000 visited nodes
by default (API range 1–100,000). It then attempts improving pairwise swaps of
unlocked players. Larger groups use the greedy start and bounded swaps. Swap
attempts default to 2,000 and can be set from 0–20,000 in the preview. Random mode
uses seeded shuffling with valid capacities and locks, without optimization.

For each team:

`strength = average player skill + 0.5 × (team size − mean team size)`

The objective minimizes the sum of:

- Squared deviation of estimated strength from the mean strength.
- 0.25 × squared size deviation from the mean size.
- 1,000 per team without an eligible keeper when any keeper is available, plus
  100 per keeper beyond one on a team.
- 0.8 per missing available role (Defender/Winger/Pivot), recognizing either
  primary or secondary position.

Size/membership validation is separate from these soft objective terms. Missing
or invalid solver ratings use a disclosed estimate of 5; the database and profile
form require a real administrator rating in 1–10. Locks can prevent goalkeeper
or position coverage. Warnings disclose missing ratings, insufficient keepers,
uncovered role availability, and explicit uneven sizes. Strength spread labels
are **Close estimated strengths** (<=0.75), **Moderate strength spread** (<=1.5),
or **Wide strength spread**. They never claim perfect balance or predict results.

The solver is bounded rather than globally optimal. Fixed capacities, soft roles,
search limits, and local minima can affect the result. The size-advantage factor
is a planning assumption, not a calibrated sporting model. There is no promise of
complete role/GK coverage under conflicting locks or a finite search budget.

Any match record, including a scheduled match, freezes rosters and locks for that
session. A stale preview cannot replace them. Use a new session for rebalancing
after scheduling/play; no historical assignment or played competition is rewritten.

## Authoritative statistics and participation

Three SQL views share one definition across profiles, charts, leaderboards, and
MVP. Only finished matches count. A linked competition fixture must also be
finished; cancelled, postponed, superseded, or reopened/unfinalized results are
excluded. Scores and player contributions derive from the event ledger and its
void/correction actions rather than copied aggregate counters.

An eligible appearance requires a recorded stint on one of the match's actual
teams and either positive finalized playing time or valid event evidence within
that stint. Thus session attendance, squad membership, unused bench players,
and zero-time starters without event evidence receive no appearances. Older
migrated event evidence can establish participation even when timing was not
recorded. Missing historical participation is never reconstructed from attendance.

Goals/assists/fouls require valid attribution and event-time participation;
voided/superseded events are excluded. Own goals affect the opponent's result,
not a player's scored-goal/assist count. W/D/L follows the eligible participant's
actual match team and the authoritative final score. A player receives at most
one appearance per match despite substitutions. Rates divide by eligible
appearances and are unavailable for zero appearances.

Archived players retain historical statistics. Attendance/team history is labeled
separately from playing appearances. Recent matches and trends use recorded
counts, show the sample size, and avoid projecting skill or future results. Bar
charts use existing Flutter widgets and add no charting dependency.

Recent-session filters select the latest played sessions by session date, creation
time, and ID; empty upcoming sessions do not displace played history. Rate boards
default to a minimum of three eligible appearances, editable from 1–1,000. Equal
unrounded values share competition ranks (1, 1, 3); names/IDs only stabilize display
order. Players with no eligible participation are omitted. Statistics rows are
queried per scope and grouped once by player for reuse in leaderboard/MVP rendering.
Existing event, stint, and timeline indexes are reused; v4 adds scorer/assist indexes.

## Transparent calculated MVP

Default score: `4 × goals + 3 × assists + 2 × match wins − 1 × fouls`.
All weights are integer settings per session, configurable from -100 to 100 before
the first confirmation. The UI requires saving/recalculating edited weights before
confirming. Injuries are never queried or scored. The screen explicitly labels the
award as calculated and distinct from overall player ability.

Only eligible participants can receive an award. Tied top scores allow a shared
calculated award; choosing one tied leader or a different participant records an
administrator override. A reason is optional (maximum 300 characters). Confirmation
requires a completed session so final results cannot subsequently change beneath
the award. All scores remain provisional beforehand.

Each decision persists selected IDs, method (`calculated`, `shared`, `override`),
weights, every candidate's statistics/points breakdown, calculated leaders, optional
reason, timestamp, and sequential revision. UUID request keys make retries idempotent.
Later recipient changes append decisions; the initial method/calculation is retained.
Weights lock after the first decision. No participation means no fabricated MVP.

## Additive database version 4

Upgrades from v1, v2, or v3 run the necessary stages transactionally. Existing
tables, IDs, photos, rosters, timers, events, finalized results, competitions,
standings, and champion decisions are preserved. No table reset or rebuild is used.

- `players`: nullable `secondary_position`; boolean `goalkeeper_eligible`,
  backfilled for existing primary Goalkeeper profiles. Existing ratings are retained.
- `player_rating_history`: immutable initial/imported and changed rating entries.
  SQL triggers write entries atomically with player insert/rating updates; changing
  another profile field does not create a fake rating revision. The migration
  records the current rating at migration time and explicitly says earlier history
  is unavailable.
- `team_assignment_locks`: session/player key and composite references to the
  session's attendance/team, with available-attendee and frozen-history guards.
- `session_mvp_settings` and `session_mvp_decisions`: bounded weights, immutable
  sequential award history, eligible participant/completed-session checks.
- `analytics_valid_events`, `analytics_match_scores`, `analytics_player_matches`:
  derived views, not duplicate stored career totals.
- Event scorer/assist and rating-history indexes.

Drift manages explicit SQL and connection/transaction lifecycle; `allTables` is
deliberately empty. No Drift code generation, `createAll`, or automatic table
streams should be introduced. Riverpod invalidation refreshes data after writes.
Foreign keys stay enabled during normal operation, with checks during migration.

## Validation and commands

Executed: `python3 tool/check_sql_schema.py` — **22 passing SQL contract tests**
against actual migration/schema SQL, including the retained Phase 2/3 checks and
new analytics, voids, eligibility, lock, rating-history, MVP, and v3 preservation
contracts. All **56 Dart files** parse and format with a WASM port of `dart_style`.
These supplementary checks do not run the Dart repositories or Flutter UI.

Defined Phase 4 tests: 16 solver, six balance repository, 12 statistics/MVP,
one file-backed v3→v4 migration/reopen, and one new navigation/MVP widget test.
They cover all requested categories, stale previews, persistent locks, explicit
size overrides, archived players, rates/ties/scopes, actual participation versus
bench membership, manual rating history, immutable overrides, and historical
profiles/events/teams/champion preservation. The total suite now defines 106
tests. **Flutter execution and type analysis remain blocked by SDK bootstrap**;
both commands were attempted and exited 1 before running their checks.

Use the SDK exports in the root README. After reviewing/saving the environment's
`storage.googleapis.com` network addition, verify artifact access and run:

```sh
cd /workspace/footsallapp
bash tool/cloud_setup.sh
flutter pub get
flutter analyze
flutter test test/team_balancer_test.dart test/balance_repository_test.dart test/statistics_test.dart test/phase4_migration_test.dart test/widget_test.dart
flutter test
flutter build apk --debug
flutter devices
flutter run -d <android-device-id>
```

Fix any analysis/test/build failures before claiming readiness. Generate/review
the application lockfile once dependency resolution succeeds. No release package
is produced in this phase. A debug build is only a verification target.

Required device smoke test: edit both new/old profiles and rating history; preview
two/three teams with uneven attendance; reproduce a seed; regenerate with locks;
swap/confirm/restart; verify scheduled-roster protection; play/undo/correct matches
with substitutions and unused bench players; inspect career/WDL/rates/history and
leaderboard filters/ties; configure provisional MVP, complete the session, confirm
or override it, restart and inspect saved revisions. Also retain the Phase 3
competition/timer smoke tests. No Android behavior is yet verified.

The setup script and Phase 4 startup instructions are saved through the requested
cloud onboarding skill. Saving configuration does not apply runtime changes or
publish an environment snapshot. Review/save the draft in environment settings,
then publish after the outstanding Flutter/Android checks are completed.
