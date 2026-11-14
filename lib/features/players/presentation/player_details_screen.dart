import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../statistics/presentation/statistics_widgets.dart';

class PlayerDetailsScreen extends ConsumerStatefulWidget {
  const PlayerDetailsScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PlayerDetailsScreen> createState() =>
      _PlayerDetailsScreenState();
}

class _PlayerDetailsScreenState extends ConsumerState<PlayerDetailsScreen> {
  bool _busy = false;
  Future<void> _archive(bool archived) async {
    if (!await confirm(
      context,
      title: archived ? 'Archive player?' : 'Restore player?',
      message: archived
          ? 'They will be hidden from new sessions. All previous attendance and team history will stay saved.'
          : 'This player will be available for new sessions again.',
      action: archived ? 'Archive' : 'Restore',
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
      )).archivePlayer(widget.id, archived: archived);
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
      title: const Text('Player profile'),
      actions: [
        IconButton(
          onPressed: () => context.push('/players/${widget.id}/edit'),
          tooltip: 'Edit player',
          icon: const Icon(Icons.edit_outlined),
        ),
      ],
    ),
    body: Content(
      child: AsyncContent(
        value: ref.watch(playersProvider),
        retry: () => retryData(ref),
        builder: (players) {
          final p = players.where((p) => p.id == widget.id).firstOrNull;
          if (p == null) {
            return const Center(child: Text('Player not found.'));
          }
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 12),
              Center(child: PlayerAvatar(p, radius: 55)),
              const SizedBox(height: 22),
              Text(
                p.name,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                '${p.preferredPosition}${p.secondaryPosition == null ? '' : ' / ${p.secondaryPosition}'}${p.goalkeeperEligible ? ' · GK eligible' : ''}${p.jerseyNumber == null ? '' : ' · #${p.jerseyNumber}'}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 26),
              Text(
                'Preferred foot: ${p.preferredFoot}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              SurfaceCard(
                child: Row(
                  children: [
                    const Icon(Icons.bolt, color: AppColors.emerald),
                    const SizedBox(width: 12),
                    const Expanded(child: Text('Skill rating')),
                    Text(
                      '${p.skillRating} / 10',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              const SectionTitle('Career statistics'),
              const SizedBox(height: 12),
              CareerPanel(playerId: widget.id),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () =>
                    context.push('/players/${widget.id}/analytics'),
                icon: const Icon(Icons.insights_outlined),
                label: const Text('Career trends & history'),
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _archive(!p.isArchived),
                icon: Icon(
                  p.isArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                label: Text(p.isArchived ? 'Restore player' : 'Archive player'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Player records are kept permanently. Archiving never removes historical rosters.',
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
      ),
    ),
  );
}
