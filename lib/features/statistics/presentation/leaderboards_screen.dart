import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utilities/dates.dart';
import '../../../core/widgets/common.dart';
import '../domain/statistics.dart';

class LeaderboardsScreen extends ConsumerStatefulWidget {
  const LeaderboardsScreen({super.key, this.sessionId});
  final String? sessionId;
  @override
  ConsumerState<LeaderboardsScreen> createState() => _LeaderboardsState();
}

class _LeaderboardsState extends ConsumerState<LeaderboardsScreen> {
  late String _scope = widget.sessionId == null
      ? 'all'
      : 'session:${widget.sessionId}';
  String _metric = 'goals';
  final _minimum = TextEditingController(text: '3');
  @override
  void dispose() {
    _minimum.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope == 'recent'
        ? const StatisticsScope(recentSessions: 4)
        : _scope.startsWith('session:')
        ? StatisticsScope(sessionId: _scope.substring(8))
        : const StatisticsScope();
    final minimum = int.tryParse(_minimum.text),
        validMinimum = minimum != null && minimum >= 1 && minimum <= 1000;
    const metrics = {
      'goals': 'Top scorers',
      'assists': 'Assist leaders',
      'appearances': 'Most matches played',
      'wins': 'Most team wins',
      'goals_per_match': 'Goals per match',
      'assists_per_match': 'Assists per match',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboards')),
      body: Content(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Eyebrow('Recorded on the pitch'),
            const SizedBox(height: 12),
            Text(
              'The numbers.\nThe whole squad.',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 18),
            AsyncContent(
              value: ref.watch(sessionsProvider),
              retry: () => retryData(ref),
              builder: (sessions) => DropdownButtonFormField<String>(
                initialValue: _scope,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Period / Saturday session',
                ),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('All time')),
                  const DropdownMenuItem(
                    value: 'recent',
                    child: Text('Last 4 played sessions'),
                  ),
                  if (scope.sessionId != null &&
                      !sessions.any((s) => s.id == scope.sessionId))
                    DropdownMenuItem(
                      value: _scope,
                      enabled: false,
                      child: const Text('Session unavailable'),
                    ),
                  ...sessions.map(
                    (s) => DropdownMenuItem(
                      value: 'session:${s.id}',
                      child: Text(
                        '${sessionDate(s.date)} · ${s.locationName.isEmpty ? 'Saturday session' : s.locationName}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _scope = v!),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _metric,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Leaderboard'),
              items: metrics.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _metric = v!),
            ),
            if (_metric.endsWith('_per_match')) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _minimum,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Minimum eligible appearances',
                  errorText: validMinimum ? null : 'Use 1–1000 appearances',
                ),
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              'Only eligible finalized participation counts. Equal values share ranks; names only order tied rows. Rate rankings use unrounded values.',
            ),
            if (scope.sessionId != null)
              TextButton.icon(
                onPressed: () =>
                    context.push('/sessions/${scope.sessionId}/mvp'),
                icon: const Icon(Icons.emoji_events_outlined),
                label: const Text('Calculate this session’s MVP'),
              ),
            const SizedBox(height: 20),
            if (!_metric.endsWith('_per_match') || validMinimum)
              AsyncContent(
                value: ref.watch(statisticsProvider(scope)),
                retry: () => retryData(ref),
                builder: (b) {
                  final rows = b.leaderboard(
                    _metric,
                    minimumAppearances: validMinimum ? minimum : 3,
                  );
                  if (rows.isEmpty) {
                    return const EmptyState(
                      icon: Icons.insights_outlined,
                      title: 'No eligible entries',
                      message:
                          'No finalized participants meet this period and appearance threshold. No records are estimated.',
                    );
                  }
                  return Column(
                    children: rows
                        .map(
                          (r) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: SurfaceCard(
                              padding: const EdgeInsets.all(14),
                              onTap: () => context.push(
                                '/players/${r.player.id}/analytics',
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 30,
                                    child: Text(
                                      '${r.position}',
                                      style: const TextStyle(
                                        color: AppColors.emerald,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  PlayerAvatar(r.player, radius: 22),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          r.player.name,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                        Text(
                                          '${r.stats.appearances} matches${r.player.isArchived ? ' · Archived' : ''}',
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _metric.endsWith('_per_match')
                                        ? r.value.toStringAsFixed(2)
                                        : '${r.value.toInt()}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  );
                },
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
