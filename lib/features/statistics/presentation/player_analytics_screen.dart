import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/providers.dart';
import '../../../core/utilities/dates.dart';
import '../../../core/widgets/common.dart';
import '../domain/statistics.dart';
import 'statistics_widgets.dart';

class PlayerAnalyticsScreen extends ConsumerWidget {
  const PlayerAnalyticsScreen({super.key, required this.playerId});
  final String playerId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Career & history')),
    body: Content(
      child: AsyncContent(
        value: ref.watch(statisticsProvider(const StatisticsScope())),
        retry: () => retryData(ref),
        builder: (b) {
          final p = b.players.where((p) => p.id == playerId).firstOrNull;
          if (p == null) {
            return const Center(child: Text('Player not found.'));
          }
          final stats = b.career(playerId);
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: [
                  PlayerAvatar(p, radius: 30),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      p.name,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '${stats.appearances} eligible appearances · ${p.skillRating}/10 manual skill rating',
              ),
              if (stats.appearances < 5) ...[
                const SizedBox(height: 12),
                const Text(
                  'Small sample: fewer than five eligible matches. These are descriptive counts, not a reliable ranking of overall ability.',
                ),
              ],
              const SizedBox(height: 24),
              PlayerTrends(stats: stats),
              const SizedBox(height: 28),
              const SectionTitle('Recent finalized matches'),
              const SizedBox(height: 12),
              if (stats.matches.isEmpty)
                const Text('No eligible match participation yet.'),
              for (final m in stats.matches.take(10))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  onTap: () => context.push('/matches/${m.matchId}/summary'),
                  leading: CircleAvatar(child: Text(m.result)),
                  title: Text('${sessionDate(m.date)} · ${m.teamName}'),
                  subtitle: Text(
                    '${m.goals} goals · ${m.assists} assists · ${m.fouls} fouls · ${m.playingMillis == 0 ? 'participation evidenced by event' : '${m.playingMillis ~/ 1000}s on pitch'}',
                  ),
                ),
              const SizedBox(height: 24),
              const SectionTitle('Saturday attendance & historical teams'),
              const SizedBox(height: 8),
              const Text(
                'Attendance is shown for history; it is not counted as a match appearance.',
              ),
              AsyncContent(
                value: ref.watch(playerSessionHistoryProvider(playerId)),
                retry: () => retryData(ref),
                builder: (history) => Column(
                  children: [
                    if (history.isEmpty) const Text('No saved attendance yet.'),
                    for (final row in history)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        onTap: () =>
                            context.push('/sessions/${row['session_id']}'),
                        leading: Icon(
                          Icons.shield_outlined,
                          color: row['color_value'] == null
                              ? null
                              : Color(row['color_value'] as int),
                        ),
                        title: Text(
                          sessionDate(
                            DateTime.fromMillisecondsSinceEpoch(
                              row['date'] as int,
                              isUtc: true,
                            ),
                          ),
                        ),
                        subtitle: Text(
                          '${row['team_name'] ?? 'No saved team'} · ${row['location_name']} · ${row['status']}',
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const SectionTitle('Manual rating history'),
              const SizedBox(height: 8),
              const Text(
                'Match statistics and MVP awards never change skill ratings.',
              ),
              AsyncContent(
                value: ref.watch(ratingHistoryProvider(playerId)),
                retry: () => retryData(ref),
                builder: (rows) => Column(
                  children: rows
                      .map(
                        (r) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${r['old_rating'] ?? 'Initial'} → ${r['new_rating']} / 10',
                          ),
                          subtitle: Text(
                            '${r['description']} · ${DateFormat('d MMM yyyy · HH:mm').format(DateTime.fromMillisecondsSinceEpoch(r['changed_at'] as int))}',
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    ),
  );
}
