import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utilities/dates.dart';
import '../../../core/widgets/common.dart';
import '../../sessions/presentation/sessions_screen.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final players = ref.watch(playersProvider);
    final sessions = ref.watch(sessionsProvider);
    return Content(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.emerald,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.sports_soccer,
                  color: AppColors.background,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SATURDAY',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'F U T S A L',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const Tooltip(
                message: 'Saved on this device. Works offline.',
                child: Icon(
                  Icons.offline_pin_outlined,
                  color: AppColors.emerald,
                ),
              ),
              IconButton(
                onPressed: () => context.push('/settings'),
                tooltip: 'Settings & local data',
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          const SizedBox(height: 34),
          const Eyebrow('Your weekly ritual'),
          const SizedBox(height: 8),
          Text(
            'Same friends.\nNew game.',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 10),
          const Text('Build the teams. Make Saturday count.'),
          const SizedBox(height: 26),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 450),
            builder: (context, value, child) => Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, 12 * (1 - value)),
                child: child,
              ),
            ),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: const Color(0xFF326747)),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF17452F), Color(0xFF14271E)],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Eyebrow('Next Saturday')),
                        Icon(
                          Icons.sports_soccer,
                          size: 32,
                          color: AppColors.emerald.withValues(alpha: .55),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      DateFormat('d MMMM').format(nextSaturday()),
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text('A fresh session. A fresh set of teams.'),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => context.push('/sessions/new'),
                        icon: const Icon(Icons.add),
                        label: const Text('Create Saturday session'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  label: 'REGISTERED PLAYERS',
                  icon: Icons.groups_2_outlined,
                  value: players.when(
                    data: (p) => '${p.length}',
                    error: (e, s) => '—',
                    loading: () => '…',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Metric(
                  label: 'SAVED SESSIONS',
                  icon: Icons.history,
                  value: sessions.when(
                    data: (s) => '${s.length}',
                    error: (e, s) => '—',
                    loading: () => '…',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          SectionTitle(
            'The squad',
            action: TextButton(
              onPressed: () => context.go('/players'),
              child: const Text('View players →'),
            ),
          ),
          const SizedBox(height: 10),
          SurfaceCard(
            onTap: () => context.push('/players/new'),
            child: const Row(
              children: [
                Icon(Icons.person_add_alt_1, color: AppColors.emerald),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bring a friend to the pitch',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text('Register a player in your permanent squad.'),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_rounded, color: AppColors.muted),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SurfaceCard(
            onTap: () => context.push('/statistics'),
            child: const Row(
              children: [
                Icon(Icons.insights_outlined, color: AppColors.emerald),
                SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Career leaderboards & analytics',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right),
              ],
            ),
          ),
          const SizedBox(height: 28),
          SectionTitle(
            'Recent sessions',
            action: TextButton(
              onPressed: () => context.go('/sessions'),
              child: const Text('All sessions →'),
            ),
          ),
          const SizedBox(height: 10),
          AsyncContent(
            value: sessions,
            retry: () => retryData(ref),
            builder: (items) => items.isEmpty
                ? const EmptyState(
                    icon: Icons.calendar_today_outlined,
                    title: 'Your history starts here',
                    message:
                        'Create a session and its teams will stay saved on this device.',
                  )
                : Column(
                    children: items
                        .take(3)
                        .map(
                          (s) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: SessionCard(session: s),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 18),
          AsyncContent(
            value: ref.watch(recentFinishedProvider),
            retry: () => retryData(ref),
            builder: (match) => SurfaceCard(
              onTap: match == null
                  ? null
                  : () => context.push('/matches/${match.match.id}/summary'),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.emoji_events_outlined,
                    color: AppColors.emerald,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Latest finished match',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          match == null
                              ? 'No finished match results yet.'
                              : '${match.result} · ${match.score(match.teamA.id)}–${match.score(match.teamB.id)}',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              'YOUR PITCH. YOUR PEOPLE.',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 2,
                color: AppColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.icon});
  final String label, value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppColors.muted, size: 22),
        const SizedBox(height: 14),
        Text(value, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 5),
        Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
            color: AppColors.muted,
          ),
        ),
      ],
    ),
  );
}
