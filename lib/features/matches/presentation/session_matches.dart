import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';

class SessionMatches extends ConsumerWidget {
  const SessionMatches({
    super.key,
    required this.sessionId,
    required this.canSchedule,
  });
  final String sessionId;
  final bool canSchedule;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionTitle(
        'Matches',
        action: canSchedule
            ? TextButton.icon(
                onPressed: () =>
                    context.push('/sessions/$sessionId/matches/new'),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New match'),
              )
            : null,
      ),
      const SizedBox(height: 12),
      AsyncContent(
        value: ref.watch(sessionMatchesProvider(sessionId)),
        retry: () => retryData(ref),
        builder: (matches) {
          if (matches.isEmpty) {
            return const EmptyState(
              icon: Icons.sports_soccer,
              title: 'The pitch is ready',
              message: 'Schedule two session teams to start a timed match.',
            );
          }
          return Column(
            children: matches
                .map(
                  (m) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _MatchTile(id: m.id),
                  ),
                )
                .toList(),
          );
        },
      ),
    ],
  );
}

class _MatchTile extends ConsumerWidget {
  const _MatchTile({required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncContent(
    value: ref.watch(matchProvider(id)),
    retry: () => retryData(ref),
    builder: (b) {
      if (b == null) {
        return const SizedBox.shrink();
      }
      return SurfaceCard(
        onTap: () => context.push('/matches/$id'),
        child: Row(
          children: [
            const Icon(Icons.sports_soccer, color: AppColors.emerald),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${b.teamA.name} vs ${b.teamB.name}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${b.match.phase.toUpperCase()} · ${b.match.durationSeconds ~/ 60} min${b.timer.recoveryRequired ? ' · Timer review needed' : ''}',
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${b.score(b.teamA.id)} – ${b.score(b.teamB.id)}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
      );
    },
  );
}
