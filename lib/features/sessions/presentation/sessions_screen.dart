import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utilities/dates.dart';
import '../../../core/widgets/common.dart';
import '../domain/session.dart';

class SessionsScreen extends ConsumerWidget {
  const SessionsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Content(
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Eyebrow('Every Saturday, saved'),
        const SizedBox(height: 8),
        Text(
          'Session history',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 8),
        const Text('New teams each week. Memories that stay.'),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => context.push('/sessions/new'),
          icon: const Icon(Icons.add),
          label: const Text('Create session'),
        ),
        const SizedBox(height: 24),
        AsyncContent(
          value: ref.watch(sessionsProvider),
          retry: () => retryData(ref),
          builder: (sessions) => sessions.isEmpty
              ? const EmptyState(
                  icon: Icons.calendar_month_outlined,
                  title: 'No sessions yet',
                  message:
                      'Choose your first Saturday and bring the squad together.',
                )
              : Column(
                  children: sessions
                      .map(
                        (s) => Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: SessionCard(session: s),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    ),
  );
}

class SessionCard extends StatelessWidget {
  const SessionCard({super.key, required this.session});
  final FutsalSession session;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    onTap: () => context.push('/sessions/${session.id}'),
    child: Row(
      children: [
        Container(
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.elevated,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Text(
                DateFormat('MMM').format(session.date).toUpperCase(),
                style: const TextStyle(
                  color: AppColors.emerald,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
              ),
              Text(
                '${session.date.day}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.locationName.isEmpty
                    ? 'Saturday session'
                    : session.locationName,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                '${DateFormat('yyyy').format(session.date)} · ${session.matchDurationSeconds ~/ 60} min · ${rotationLabel(session.rotationMode)}',
              ),
              const SizedBox(height: 6),
              Text(
                session.status == 'completed'
                    ? 'COMPLETED · ROSTERS LOCKED'
                    : 'PLANNED',
                style: const TextStyle(
                  color: AppColors.emerald,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.chevron_right, color: AppColors.muted),
      ],
    ),
  );
}
