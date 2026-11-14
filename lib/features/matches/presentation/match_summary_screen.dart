import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../domain/match.dart';
import 'match_center_screen.dart';

class MatchSummaryScreen extends ConsumerWidget {
  const MatchSummaryScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Match summary')),
    body: Content(
      child: AsyncContent(
        value: ref.watch(matchProvider(id)),
        retry: () => retryData(ref),
        builder: (b) {
          if (b == null) {
            return const Center(child: Text('Match not found.'));
          }
          if (!b.match.isFinal) {
            return Center(
              child: FilledButton(
                onPressed: () => context.go('/matches/$id'),
                child: const Text('Match is not finished · Open Match Center'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Eyebrow(
                b.match.phase == 'cancelled'
                    ? 'Cancelled · no final result'
                    : 'Final whistle · saved on device',
              ),
              const SizedBox(height: 12),
              Text(
                b.match.phase == 'cancelled'
                    ? 'Cancelled · no final result'
                    : b.result,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 20),
              MatchScoreboard(bundle: b),
              const SizedBox(height: 16),
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Playing time · ${matchTime(b.timer.accumulatedMillis)} of ${matchTime(b.match.durationSeconds * 1000)}',
                    ),
                    if (b.match.startedAt != null)
                      Text(
                        'Started · ${DateTime.fromMillisecondsSinceEpoch(b.match.startedAt!).toLocal()}',
                      ),
                    if (b.match.endedAt != null)
                      Text(
                        'Finished · ${DateTime.fromMillisecondsSinceEpoch(b.match.endedAt!).toLocal()}',
                      ),
                    const SizedBox(height: 8),
                    const Text(
                      'The score and statistics below are derived from non-voided events. The audit timeline retains every correction.',
                    ),
                    if (b.actions.any((a) => a.id.startsWith('legacy-')))
                      const Text(
                        'Imported Phase 1 match: elapsed time is the latest recorded event time. Full playing time and historical on-field intervals were not recorded.',
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              for (final team in [b.teamA, b.teamB]) ...[
                Text(
                  team.name,
                  style: TextStyle(
                    color: Color(team.colorValue),
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final player in b.players.where(
                        (p) => b.stints.any(
                          (s) => s.playerId == p.id && s.teamId == team.id,
                        ),
                      ))
                        ListTile(
                          leading: PlayerAvatar(player, radius: 20),
                          title: Text(player.name),
                          subtitle: Text(
                            '${b.activeEvents.where((e) => e.type == 'goal' && e.playerId == player.id).length} goals · '
                            '${b.activeEvents.where((e) => e.type == 'goal' && e.assistId == player.id).length} assists · '
                            '${b.activeEvents.where((e) => e.type == 'foul' && e.playerId == player.id).length} fouls',
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
              FilledButton.icon(
                onPressed: () => context.go('/matches/$id'),
                icon: const Icon(Icons.timeline),
                label: const Text('View saved event timeline'),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    ),
  );
}
