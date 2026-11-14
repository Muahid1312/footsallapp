import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/database/app_database.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../players/domain/player.dart';
import '../domain/team.dart';

class TeamBuilderScreen extends ConsumerStatefulWidget {
  const TeamBuilderScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<TeamBuilderScreen> createState() => _TeamBuilderScreenState();
}

class _TeamBuilderScreenState extends ConsumerState<TeamBuilderScreen> {
  bool _busy = false;
  Future<void> _run(Future<void> Function(AppDatabase) operation) async {
    setState(() => _busy = true);
    try {
      await operation(await ref.read(databaseProvider.future));
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

  Future<void> _randomize() async {
    if (!await confirm(
      context,
      title: 'Generate new teams?',
      message:
          'This replaces the teams in this session only. Captains who move teams will be cleared. Other sessions stay unchanged.',
      action: 'Generate teams',
    )) {
      return;
    }
    if (!mounted) {
      return;
    }
    await _run((db) => db.randomizeTeams(widget.id));
  }

  Future<void> _edit(SessionTeam team, List<Player> players) async {
    final result = await showDialog<TeamEdit>(
      context: context,
      builder: (_) => _TeamEditDialog(team: team, players: players),
    );
    if (result == null || !mounted) {
      return;
    }
    await _run(
      (db) => db.updateTeam(
        widget.id,
        team.id,
        name: result.name,
        colorValue: result.color,
        captainPlayerId: result.captain,
      ),
    );
  }

  Future<void> _assign(
    Player player,
    SessionTeam source,
    SessionBundle bundle,
  ) async {
    final targets = bundle.teams.where((t) => t.id != source.id).toList();
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(c).height * .75,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              Text(player.name, style: Theme.of(c).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('Move to another team, or swap with a teammate.'),
              const SizedBox(height: 18),
              for (final t in targets) ...[
                ListTile(
                  leading: Icon(
                    Icons.arrow_forward,
                    color: Color(t.colorValue),
                  ),
                  title: Text('Move to ${t.name}'),
                  subtitle: Text(
                    source.playerIds.length <= 1
                        ? 'Keep at least one player per team'
                        : '${t.playerIds.length} players',
                  ),
                  enabled: source.playerIds.length > 1,
                  onTap: () => Navigator.pop(c, 'move:${t.id}'),
                ),
                for (final p in bundle.attendees.where(
                  (p) => t.playerIds.contains(p.id),
                ))
                  ListTile(
                    leading: const Icon(
                      Icons.swap_horiz,
                      color: AppColors.emerald,
                    ),
                    title: Text('Swap with ${p.name}'),
                    subtitle: Text(t.name),
                    onTap: () => Navigator.pop(c, 'swap:${p.id}'),
                  ),
                const Divider(),
              ],
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) {
      return;
    }
    if (action.startsWith('move:')) {
      final target = action.substring(5);
      final sizes =
          bundle.teams
              .map(
                (t) =>
                    t.playerIds.length +
                    (t.id == target ? 1 : 0) -
                    (t.id == source.id ? 1 : 0),
              )
              .toList()
            ..sort();
      final uneven = sizes.last - sizes.first > 1;
      if (uneven &&
          !await confirm(
            context,
            title: 'Allow uneven team sizes?',
            message:
                'This manual move makes the team-size gap larger than one player. Every player remains assigned; this explicitly overrides size balance.',
            action: 'Allow uneven move',
          )) {
        return;
      }
      if (!mounted) {
        return;
      }
      await _run(
        (db) =>
            db.movePlayer(widget.id, player.id, target, allowUneven: uneven),
      );
    } else {
      await _run(
        (db) => db.swapPlayers(widget.id, player.id, action.substring(5)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Team builder')),
    body: Content(
      child: AsyncContent(
        value: ref.watch(sessionProvider(widget.id)),
        retry: () => retryData(ref),
        builder: (bundle) {
          if (bundle == null) {
            return const Center(child: Text('Session not found.'));
          }
          final locked =
              bundle.session.status == 'completed' || bundle.rosterLocked;
          final sizes = bundle.teams.map((t) => t.playerIds.length).toSet();
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Eyebrow('The lineup'),
              const SizedBox(height: 8),
              Text(
                'Good friends.\nGreat competition.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                '${bundle.attendees.length} players · ${bundle.teams.length} teams · ${locked ? 'Read-only history' : 'Every change saves automatically'}',
              ),
              const SizedBox(height: 20),
              if (!locked) ...[
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => context.push('/sessions/${widget.id}/balance'),
                  icon: const Icon(Icons.balance),
                  label: const Text('Balanced preview & player locks'),
                ),
                const SizedBox(height: 12),
              ],
              if (!locked)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _randomize,
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Generate new random teams'),
                ),
              if (sizes.length > 1) ...[
                const SizedBox(height: 12),
                const Text(
                  'Uneven team sizes. Every attending player is included.',
                  style: TextStyle(color: Color(0xFFFBBF24)),
                ),
              ],
              if (!locked) ...[
                const SizedBox(height: 12),
                const Text(
                  'Tap a player to move or swap. Use the edit icon to change a team’s name, color, or captain.',
                ),
              ],
              const SizedBox(height: 20),
              if (_busy) const LinearProgressIndicator(),
              for (final team in bundle.teams)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: TeamRosterCard(
                    team: team,
                    players: bundle.attendees,
                    onEdit: locked || _busy
                        ? null
                        : () => _edit(team, bundle.attendees),
                    onPlayerTap: locked || _busy
                        ? null
                        : (p) => _assign(p, team, bundle),
                  ),
                ),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => context.pushReplacement('/sessions/${widget.id}'),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Done · View saved session'),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    ),
  );
}

class TeamRosterCard extends StatelessWidget {
  const TeamRosterCard({
    super.key,
    required this.team,
    required this.players,
    this.onEdit,
    this.onPlayerTap,
  });
  final SessionTeam team;
  final List<Player> players;
  final VoidCallback? onEdit;
  final void Function(Player)? onPlayerTap;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        Container(height: 4, color: Color(team.colorValue)),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Color(team.colorValue).withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.shield_outlined,
                  color: Color(team.colorValue),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      team.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text('${team.playerIds.length} players'),
                  ],
                ),
              ),
              if (onEdit != null)
                IconButton(
                  onPressed: onEdit,
                  tooltip: 'Edit ${team.name}',
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        for (final pid in team.playerIds)
          Builder(
            builder: (context) {
              final p = players.where((p) => p.id == pid).firstOrNull;
              if (p == null) {
                return const ListTile(title: Text('Player unavailable'));
              }
              final captain = team.captainPlayerId == pid;
              return ListTile(
                onTap: onPlayerTap == null ? null : () => onPlayerTap!(p),
                leading: PlayerAvatar(p, radius: 20),
                title: Text(p.name),
                subtitle: Text(
                  '${p.preferredPosition}${p.isArchived ? ' · Archived' : ''}',
                ),
                trailing: captain
                    ? Tooltip(
                        message: 'Team captain',
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: Color(
                              team.colorValue,
                            ).withValues(alpha: .15),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            'C',
                            style: TextStyle(
                              color: Color(team.colorValue),
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      )
                    : onPlayerTap == null
                    ? null
                    : const Icon(
                        Icons.swap_horiz,
                        color: AppColors.muted,
                        size: 20,
                      ),
              );
            },
          ),
        const SizedBox(height: 8),
      ],
    ),
  );
}

class TeamEdit {
  const TeamEdit(this.name, this.color, this.captain);
  final String name;
  final int color;
  final String? captain;
}

class _TeamEditDialog extends StatefulWidget {
  const _TeamEditDialog({required this.team, required this.players});
  final SessionTeam team;
  final List<Player> players;
  @override
  State<_TeamEditDialog> createState() => _TeamEditDialogState();
}

class _TeamEditDialogState extends State<_TeamEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.team.name,
  );
  late int _color = widget.team.colorValue;
  late String _captain = widget.team.captainPlayerId ?? '';
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Team identity'),
    content: SizedBox(
      width: 380,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _name,
                maxLength: 40,
                decoration: const InputDecoration(labelText: 'Team name'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Enter a team name' : null,
              ),
              const SizedBox(height: 18),
              const Text('Team color'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: teamColors
                    .map(
                      (color) => Semantics(
                        label: 'Team color ${teamColors.indexOf(color) + 1}',
                        selected: _color == color,
                        button: true,
                        child: InkWell(
                          onTap: () => setState(() => _color = color),
                          borderRadius: BorderRadius.circular(24),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Color(color),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _color == color
                                    ? Colors.white
                                    : Colors.transparent,
                                width: 3,
                              ),
                            ),
                            child: _color == color
                                ? const Icon(Icons.check, color: Colors.black)
                                : null,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 24),
              DropdownButtonFormField<String>(
                initialValue: _captain,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Captain'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('No captain')),
                  ...widget.players
                      .where((p) => widget.team.playerIds.contains(p.id))
                      .map(
                        (p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(p.name, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                ],
                onChanged: (v) => setState(() => _captain = v ?? ''),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(
              context,
              TeamEdit(_name.text, _color, _captain.isEmpty ? null : _captain),
            );
          }
        },
        child: const Text('Save team'),
      ),
    ],
  );
}
