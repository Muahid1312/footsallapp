import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../domain/statistics.dart';

class CareerPanel extends ConsumerWidget {
  const CareerPanel({super.key, required this.playerId});
  final String playerId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncContent(
    value: ref.watch(statisticsProvider(const StatisticsScope())),
    retry: () => retryData(ref),
    builder: (bundle) {
      final s = bundle.career(playerId);
      if (s.appearances == 0) {
        return const EmptyState(
          icon: Icons.insights_outlined,
          title: 'No finished appearances yet',
          message:
              'Career totals appear after this player participates in a finished match. Live matches are excluded.',
        );
      }
      return SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 24,
              runSpacing: 16,
              children: [
                for (final entry in s.counts.entries)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entry.value}',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      Text(
                        entry.key.toUpperCase(),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
              ],
            ),
            const Divider(height: 28),
            Text(
              '${s.goalsPerMatch!.toStringAsFixed(2)} goals / match · ${s.assistsPerMatch!.toStringAsFixed(2)} assists / match',
            ),
            const SizedBox(height: 8),
            const Text(
              'Eligible appearance: positive recorded playing time or valid event evidence. Attendance and bench membership alone never count.',
            ),
          ],
        ),
      );
    },
  );
}

class StatBars extends StatelessWidget {
  const StatBars({
    super.key,
    required this.title,
    required this.labels,
    required this.values,
    required this.caption,
    this.color = AppColors.emerald,
  });
  final String title, caption;
  final List<String> labels;
  final List<int> values;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final maxValue = values.fold<int>(0, (v, n) => n > v ? n : v);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(caption),
          const SizedBox(height: 14),
          for (var i = 0; i < values.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${labels[i]} · ${values[i]}',
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                  ),
                  const SizedBox(height: 5),
                  Semantics(
                    label: '${labels[i]}: ${values[i]}',
                    child: LinearProgressIndicator(
                      value: maxValue == 0 ? 0 : values[i] / maxValue,
                      color: color,
                      backgroundColor: AppColors.elevated,
                      minHeight: 7,
                    ),
                  ),
                ],
              ),
            ),
          if (values.isEmpty)
            const Text('No eligible finalized participation in this period.'),
          const Text(
            'Bars start at zero. Recorded counts describe this sample; they do not predict skill or future results.',
            style: TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class PlayerTrends extends StatelessWidget {
  const PlayerTrends({super.key, required this.stats});
  final CareerStatistics stats;
  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<PlayerMatchStatistics>>{};
    for (final m in stats.matches.reversed) {
      (grouped[m.sessionId] ??= []).add(m);
    }
    final groups = grouped.values.toList(),
        recent = groups
            .skip(groups.length > 8 ? groups.length - 8 : 0)
            .toList();
    final labels = recent
        .map((g) => DateFormat('d MMM yy').format(g.first.date))
        .toList();
    final cumulative = <int>[];
    var count = 0;
    for (final g in groups) {
      count += g.length;
      cumulative.add(count);
    }
    final lastMatches = stats.matches.take(6).toList().reversed.toList();
    return Column(
      children: [
        StatBars(
          title: 'Goals by Saturday session',
          labels: labels,
          values: recent
              .map((g) => g.fold<int>(0, (n, m) => n + m.goals))
              .toList(),
          caption:
              'Last ${recent.length} recorded sessions · ${stats.appearances} career appearances.',
        ),
        const SizedBox(height: 16),
        StatBars(
          title: 'Assists over time',
          labels: labels,
          values: recent
              .map((g) => g.fold<int>(0, (n, m) => n + m.assists))
              .toList(),
          caption:
              'Session totals; separate sessions on the same date remain separate samples.',
          color: const Color(0xFF60A5FA),
        ),
        const SizedBox(height: 16),
        StatBars(
          title: 'Recent match contributions',
          labels: lastMatches
              .map(
                (m) =>
                    '${DateFormat('d MMM').format(m.date)} · ${m.teamName} · ${m.result} · ${m.goals} G / ${m.assists} A',
              )
              .toList(),
          values: lastMatches.map((m) => m.goals + m.assists).toList(),
          caption:
              'Goals + assists across ${lastMatches.length} recent eligible matches. Other roles are not measured by this count.',
        ),
        const SizedBox(height: 16),
        StatBars(
          title: 'Career appearance progression',
          labels: labels,
          values: cumulative
              .skip(cumulative.length > 8 ? cumulative.length - 8 : 0)
              .toList(),
          caption:
              'Cumulative eligible appearances through each recorded session.',
          color: const Color(0xFFFBBF24),
        ),
      ],
    );
  }
}
