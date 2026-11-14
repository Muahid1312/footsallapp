import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../domain/player.dart';

class PlayersScreen extends ConsumerStatefulWidget {
  const PlayersScreen({super.key});
  @override
  ConsumerState<PlayersScreen> createState() => _PlayersState();
}

class _PlayersState extends ConsumerState<PlayersScreen> {
  String search = '';
  bool archived = false;
  Widget _card(BuildContext context, Player p) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: SurfaceCard(
      padding: const EdgeInsets.all(16),
      onTap: () => context.push('/players/${p.id}'),
      child: Row(
        children: [
          PlayerAvatar(p, radius: 27),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  '${p.preferredPosition}${p.jerseyNumber == null ? '' : ' · #${p.jerseyNumber}'}${p.isArchived ? ' · Archived' : ''}',
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            children: [
              Text(
                '${p.skillRating}',
                style: const TextStyle(
                  color: AppColors.emerald,
                  fontWeight: FontWeight.w800,
                  fontSize: 22,
                ),
              ),
              const Text(
                'SKILL / 10',
                style: TextStyle(fontSize: 8, letterSpacing: 1),
              ),
            ],
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, color: AppColors.muted),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Content(
    child: CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Eyebrow('The people behind the game'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Your squad',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                    ),
                    IconButton.filled(
                      onPressed: () => context.push('/players/new'),
                      tooltip: 'Add player',
                      icon: const Icon(Icons.person_add_alt_1),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('One permanent squad. Endless Saturdays.'),
                TextButton.icon(
                  onPressed: () => context.push('/players/import'),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import from CSV'),
                ),
                const SizedBox(height: 24),
                TextField(
                  onChanged: (v) => setState(() => search = v),
                  decoration: const InputDecoration(
                    hintText: 'Search players or positions',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                const SizedBox(height: 12),
                FilterChip(
                  label: const Text('Include archived'),
                  selected: archived,
                  onSelected: (v) => setState(() => archived = v),
                ),
              ],
            ),
          ),
        ),
        ref
            .watch(playersProvider)
            .when(
              loading: () => const SliverToBoxAdapter(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                ),
              ),
              error: (e, s) => SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: EmptyState(
                    icon: Icons.error_outline,
                    title: 'Could not load players',
                    message:
                        'Retry without changing saved data. Settings can restore a validated backup if local data is unavailable.',
                    action: TextButton(
                      onPressed: () => retryData(ref),
                      child: const Text('Retry'),
                    ),
                  ),
                ),
              ),
              data: (players) {
                final filtered = players
                    .where(
                      (p) =>
                          (archived || !p.isArchived) &&
                          '${p.name} ${p.preferredPosition}'
                              .toLowerCase()
                              .contains(search.toLowerCase()),
                    )
                    .toList();
                if (filtered.isEmpty) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: EmptyState(
                        icon: Icons.groups_2_outlined,
                        title: search.isEmpty
                            ? 'The squad is waiting'
                            : 'No players found',
                        message: search.isEmpty
                            ? 'Add your first player to get matchday started.'
                            : 'Try another name or position.',
                        action: search.isEmpty
                            ? FilledButton(
                                onPressed: () => context.push('/players/new'),
                                child: const Text('Add player'),
                              )
                            : null,
                      ),
                    ),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  sliver: SliverList.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) =>
                        _card(context, filtered[index]),
                  ),
                );
              },
            ),
      ],
    ),
  );
}
