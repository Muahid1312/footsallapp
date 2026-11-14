StatisticsRepository derives career counts, W/D/L, rates, leaderboards, trends,
and session MVP candidates from the v4 analytics views. MatchRepository.career
delegates here to preserve its original four-counter API. No duplicate mutable
career totals are stored.

Eligibility requires a finalized, valid match and positive closed playing time
or a valid recorded event within that player's stint. Attendance, unused bench
membership, live games, cancelled/invalidated fixtures, and voided events do not
fabricate statistics. Historical players remain included when archived.

MVP settings/immutable decision revisions store weights and source snapshots;
final confirmation requires a completed session. Injuries never affect this score,
and calculated awards never update administrator skill ratings.

See [Phase 4 rules and validation](../../../docs/phase4.md).
