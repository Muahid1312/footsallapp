import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utilities/dates.dart';
import '../../../core/widgets/common.dart';
import '../../teams/presentation/team_builder_screen.dart';
import '../../matches/presentation/session_matches.dart';

class SessionDetailsScreen extends ConsumerStatefulWidget {
  const SessionDetailsScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<SessionDetailsScreen> createState() =>
      _SessionDetailsScreenState();
}

class _SessionDetailsScreenState extends ConsumerState<SessionDetailsScreen> {
  bool _busy = false;
  Future<void> _complete() async {
    if (!await confirm(
      context,
      title: 'Complete this session?',
      message:
          'Finish all matches first. Completing the session locks attendance, teams, and match scheduling as permanent history. This action cannot be undone in the app.',
      action: 'Complete & lock',
    )) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await (await ref.read(
        databaseProvider.future,
      )).completeSession(widget.id);
      refreshData(ref);
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Session details'),
      actions: [
        IconButton(
          onPressed: () => context.go('/sessions'),
          tooltip: 'All session history',
          icon: const Icon(Icons.history),
        ),
      ],
    ),
    body: Content(
      child: AsyncContent(
        value: ref.watch(sessionProvider(widget.id)),
        retry: () => retryData(ref),
        builder: (bundle) {
          if (bundle == null) {
            return const Center(child: Text('Session not found.'));
          }
          final s = bundle.session;
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Eyebrow(
                s.status == 'completed'
                    ? 'Completed · history preserved'
                    : 'Saturday matchday',
              ),
              const SizedBox(height: 10),
              Text(
                sessionDate(s.date),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 10),
              Text(s.locationName.isEmpty ? 'No location set' : s.locationName),
              const SizedBox(height: 24),
              SurfaceCard(
                child: Column(
                  children: [
                    _Info(
                      Icons.timer_outlined,
                      'Match duration',
                      '${s.matchDurationSeconds ~/ 60} minutes',
                    ),
                    const Divider(height: 28),
                    _Info(
                      Icons.rotate_right,
                      'Rotation',
                      rotationLabel(s.rotationMode),
                    ),
                    const Divider(height: 28),
                    _Info(
                      Icons.groups_outlined,
                      'Attendance',
                      '${bundle.attendees.length} players · ${bundle.teams.length} teams',
                    ),
                    const Divider(height: 28),
                    _Info(
                      Icons.offline_pin_outlined,
                      'Saved on device',
                      s.status == 'completed'
                          ? 'Completed & locked'
                          : 'Planned',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              const SectionTitle('Session analytics'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () =>
                        context.push('/statistics?session=${s.id}'),
                    icon: const Icon(Icons.leaderboard_outlined),
                    label: const Text('Session top scorers'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => context.push('/sessions/${s.id}/mvp'),
                    icon: const Icon(Icons.emoji_events_outlined),
                    label: const Text('Calculate MVP'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SectionTitle(
                'Competition',
                action: s.status == 'planned'
                    ? TextButton(
                        onPressed: () =>
                            context.push('/sessions/${s.id}/competition/new'),
                        child: const Text('Create competition'),
                      )
                    : null,
              ),
              const SizedBox(height: 12),
              AsyncContent(
                value: ref.watch(competitionsProvider(s.id)),
                retry: () => retryData(ref),
                builder: (items) => items.isEmpty
                    ? const Text(
                        'Create a round-robin competition or a winner-stays rotation with these teams.',
                      )
                    : Column(
                        children: items
                            .map(
                              (c) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: SurfaceCard(
                                  onTap: () =>
                                      context.push('/competitions/${c.id}'),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.emoji_events_outlined),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          '${c.mode.replaceAll('_', ' ')} · ${c.status}',
                                        ),
                                      ),
                                      const Icon(Icons.chevron_right),
                                    ],
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
              ),
              const SizedBox(height: 24),
              SessionMatches(
                sessionId: s.id,
                canSchedule: s.status == 'planned',
              ),
              const SizedBox(height: 24),
              SectionTitle(
                'The teams',
                action: s.status == 'planned' && !bundle.rosterLocked
                    ? TextButton.icon(
                        onPressed: () =>
                            context.push('/sessions/${s.id}/teams'),
                        icon: const Icon(Icons.tune, size: 18),
                        label: const Text('Edit teams'),
                      )
                    : null,
              ),
              const SizedBox(height: 12),
              for (final t in bundle.teams)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TeamRosterCard(team: t, players: bundle.attendees),
                ),
              const SizedBox(height: 14),
              const SectionTitle('Attendance'),
              const SizedBox(height: 12),
              SurfaceCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: bundle.attendees
                      .map(
                        (p) => ListTile(
                          leading: PlayerAvatar(p, radius: 18),
                          title: Text(p.name),
                          trailing: const Icon(
                            Icons.check_circle_outline,
                            color: AppColors.emerald,
                            size: 20,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 24),
              if (s.status == 'planned')
                OutlinedButton.icon(
                  onPressed: _busy ? null : _complete,
                  icon: const Icon(Icons.lock_outline),
                  label: Text(
                    _busy ? 'Saving…' : 'Complete session & lock history',
                  ),
                ),
              const SizedBox(height: 20),
              const Text(
                'Each match has its own timer and event ledger. Team rosters stay locked once a match is scheduled; every Saturday retains independent history.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    ),
  );
}

class _Info extends StatelessWidget {
  const _Info(this.icon, this.label, this.value);
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: AppColors.emerald, size: 22),
      const SizedBox(width: 14),
      Expanded(child: Text(label)),
      const SizedBox(width: 12),
      Flexible(
        child: Text(
          value,
          textAlign: TextAlign.right,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}
