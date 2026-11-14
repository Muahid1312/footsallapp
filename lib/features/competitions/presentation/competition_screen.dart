import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../app/providers.dart';
import '../../../core/utilities/dates.dart';
import '../../../core/widgets/common.dart';
import '../data/competition_repository.dart';
import '../domain/competition.dart';

class CompetitionScreen extends ConsumerStatefulWidget {
  const CompetitionScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<CompetitionScreen> createState() => _CompetitionScreenState();
}

class _CompetitionScreenState extends ConsumerState<CompetitionScreen> {
  bool _busy = false, _dialogOpen = false;
  String _key() => const Uuid().v4();
  Future<void> _run(
    Future<void> Function(CompetitionRepository) operation,
  ) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await operation(await ref.read(competitionRepositoryProvider.future));
      if (mounted) {
        refreshData(ref);
      }
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

  Future<String?> _reason() async {
    if (_dialogOpen || _busy) {
      return null;
    }
    setState(() => _dialogOpen = true);
    try {
      return await showDialog<String>(
        context: context,
        builder: (_) => const CompetitionReasonDialog(),
      );
    } finally {
      if (mounted) {
        setState(() => _dialogOpen = false);
      }
    }
  }

  Future<void> _manage(CompetitionFixture f, String action) async {
    final reason = await _reason();
    if (reason == null || !mounted) {
      return;
    }
    final key = _key();
    await _run(
      (r) => r.manageFixture(
        widget.id,
        f.id,
        action,
        reason: reason,
        requestId: key,
      ),
    );
  }

  Future<void> _complete(CompetitionBundle b) async {
    if (_busy || _dialogOpen) {
      return;
    }
    setState(() => _dialogOpen = true);
    CompetitionEndInput? input;
    try {
      input = await showDialog<CompetitionEndInput>(
        context: context,
        builder: (_) => CompetitionEndDialog(bundle: b),
      );
    } finally {
      if (mounted) {
        setState(() => _dialogOpen = false);
      }
    }
    if (input == null || !mounted) {
      return;
    }
    final value = input, key = _key();
    await _run(
      (r) => r.complete(
        widget.id,
        champion: value.champion,
        shared: value.shared,
        endEarly: value.early,
        reason: value.reason,
        requestId: key,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Competition')),
      body: Content(
        child: AsyncContent(
          value: ref.watch(competitionProvider(widget.id)),
          retry: () => retryData(ref),
          builder: (b) {
            if (b == null) {
              return const Center(child: Text('Competition not found.'));
            }
            final c = b.competition, locked = _busy || _dialogOpen;
            final open = b.fixtures
                .where((f) => ['live', 'paused'].contains(f.phase))
                .firstOrNull;
            final next = b.fixtures
                .where((f) => f.status == 'pending' && f.phase == 'scheduled')
                .firstOrNull;
            final done = b.fixtures
                .where(
                  (f) =>
                      f.kind == 'league' &&
                      f.status == 'finished' &&
                      f.phase == 'finished',
                )
                .length;
            final roundTeams = <String, Set<String>>{};
            for (final f in b.fixtures.where((f) => f.kind == 'league')) {
              (roundTeams['${f.cycle}:${f.round}'] ??= <String>{}).addAll([
                f.a,
                f.b,
              ]);
            }
            final total = c.mode == 'winner_stays'
                ? c.limit
                : b.fixtures
                      .where(
                        (f) => f.kind == 'league' && f.row['required'] == 1,
                      )
                      .length;
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Eyebrow(
                  '${c.mode == 'round_robin' ? 'Round robin' : 'Winner stays'} · ${c.status}',
                ),
                const SizedBox(height: 12),
                Text(
                  'Saturday competition',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                AsyncContent(
                  value: ref.watch(sessionProvider(c.sessionId)),
                  builder: (s) =>
                      Text(s == null ? '' : sessionDate(s.session.date)),
                ),
                const SizedBox(height: 16),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${b.teams.length} teams · ${c.duration ~/ 60} min matches · ${c.win}/${c.draw}/${c.loss} points (W/D/L)',
                      ),
                      Text(
                        c.mode == 'round_robin'
                            ? '${c.cycles} round-robin cycles · standings decide the title'
                            : 'Champion: most ${c.criterion == 'wins' ? 'match wins' : 'competition points'} · draw policy: ${c.drawPolicy.replaceAll('_', ' ')}',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: b.teams
                            .map(
                              (t) => Chip(
                                avatar: Icon(
                                  Icons.shield_outlined,
                                  color: Color(t.colorValue),
                                  size: 18,
                                ),
                                label: Text(t.name),
                              ),
                            )
                            .toList(),
                      ),
                      if (c.status != 'draft') ...[
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: total == 0
                              ? 0
                              : (done / total).clamp(0, 1).toDouble(),
                        ),
                        const SizedBox(height: 8),
                        Text('$done / $total league matches completed'),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                if (_busy) const LinearProgressIndicator(),
                if (c.status == 'draft')
                  FilledButton.icon(
                    onPressed: locked
                        ? null
                        : () {
                            final k = _key();
                            _run((r) => r.activate(c.id, requestId: k));
                          },
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('Generate fixtures & activate'),
                  ),
                if (c.status == 'draft')
                  TextButton(
                    onPressed: locked
                        ? null
                        : () => context.push(
                            '/sessions/${c.sessionId}/competition/${c.id}/settings',
                          ),
                    child: const Text('Edit draft settings'),
                  ),
                if (b.decision != null) ...[
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Eyebrow('Championship decision'),
                        const SizedBox(height: 8),
                        Text(
                          b.decision!['champion_team_id'] == null
                              ? 'Shared champions: ${(jsonDecode(b.decision!['tied_teams_json'] as String) as List).map((id) => b.teamName(id as String)).join(', ')}'
                              : '${b.teamName(b.decision!['champion_team_id'] as String)} · Champions',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text('Method: ${b.decision!['method']}'),
                        if (b.decision!['reason'] != '')
                          Text(b.decision!['reason'] as String),
                        if (b.decision!['ended_early'] == 1)
                          const Text('Competition explicitly ended early.'),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () =>
                              context.push('/competitions/${c.id}/poster'),
                          icon: const Icon(Icons.workspace_premium_outlined),
                          label: const Text('Create winner poster'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                if (c.status == 'active') ...[
                  if (open != null)
                    FilledButton.icon(
                      onPressed: locked
                          ? null
                          : () => context.push('/matches/${open.matchId}'),
                      icon: const Icon(Icons.play_circle_outline),
                      label: const Text('Open current match'),
                    ),
                  if (open == null && next != null)
                    FilledButton.icon(
                      onPressed: locked
                          ? null
                          : () => context.push('/matches/${next.matchId}'),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(
                        'Next: ${b.teamName(next.a)} vs ${b.teamName(next.b)}',
                      ),
                    ),
                  if (c.mode == 'winner_stays') ...[
                    const SizedBox(height: 18),
                    const SectionTitle('Pitch & waiting queue'),
                    const SizedBox(height: 12),
                    SurfaceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${open != null
                                ? 'Playing now'
                                : next != null
                                ? 'Next match'
                                : 'Last selected pairing'} · ${c.rotation.playing.map(b.teamName).join(' vs ')}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (c.rotation.queue.isEmpty)
                            const Text('Two teams · rematches are allowed.'),
                          for (var i = 0; i < c.rotation.queue.length; i++)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(child: Text('${i + 1}')),
                              title: Text(b.teamName(c.rotation.queue[i])),
                              subtitle: Text(
                                i == 0
                                    ? (open != null
                                          ? 'Playing next'
                                          : 'Next waiting challenger')
                                    : 'Waiting',
                              ),
                            ),
                          if (c.rotation.awaitingMatch != null) ...[
                            const Text(
                              'Draw: rotation needs an administrator decision. No winner was chosen.',
                            ),
                            for (final t in c.rotation.playing)
                              TextButton(
                                onPressed: locked
                                    ? null
                                    : () async {
                                        final reason = await _reason();
                                        if (reason == null || !mounted) {
                                          return;
                                        }
                                        final k = _key();
                                        await _run(
                                          (r) => r.resolveDraw(
                                            c.id,
                                            stayer: t,
                                            reason: reason,
                                            requestId: k,
                                          ),
                                        );
                                      },
                                child: Text('${b.teamName(t)} stays'),
                              ),
                            TextButton(
                              onPressed: locked
                                  ? null
                                  : () async {
                                      final reason = await _reason();
                                      if (reason == null || !mounted) {
                                        return;
                                      }
                                      final k = _key();
                                      await _run(
                                        (r) => r.resolveDraw(
                                          c.id,
                                          both: true,
                                          reason: reason,
                                          requestId: k,
                                        ),
                                      );
                                    },
                              child: const Text('Rotate both when possible'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (next == null &&
                        open == null &&
                        c.rotation.awaitingMatch == null &&
                        done < c.limit &&
                        !b.fixtures.any((f) => f.status == 'postponed'))
                      OutlinedButton(
                        onPressed: locked
                            ? null
                            : () {
                                final k = _key();
                                _run(
                                  (r) => r.continueRotation(c.id, requestId: k),
                                );
                              },
                        child: const Text('Restore next rotation fixture'),
                      ),
                  ],
                ],
                const SizedBox(height: 28),
                const SectionTitle('Standings'),
                const SizedBox(height: 10),
                const Text(
                  'Only finished, non-voided league results count. Equal ranks are shared; playoff scores do not change league totals.',
                ),
                const SizedBox(height: 10),
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('#')),
                        DataColumn(label: Text('Team')),
                        DataColumn(label: Text('P')),
                        DataColumn(label: Text('W')),
                        DataColumn(label: Text('D')),
                        DataColumn(label: Text('L')),
                        DataColumn(label: Text('GF')),
                        DataColumn(label: Text('GA')),
                        DataColumn(label: Text('GD')),
                        DataColumn(label: Text('Pts')),
                      ],
                      rows: b.table
                          .map(
                            (r) => DataRow(
                              cells: [
                                DataCell(Text('${r.position}')),
                                DataCell(Text(b.teamName(r.teamId))),
                                for (final value in [
                                  r.played,
                                  r.won,
                                  r.drawn,
                                  r.lost,
                                  r.goalsFor,
                                  r.goalsAgainst,
                                  r.difference,
                                  r.points,
                                ])
                                  DataCell(Text('$value')),
                              ],
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                const SectionTitle('Fixture schedule'),
                const SizedBox(height: 12),
                for (final f in b.fixtures)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SurfaceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${b.teamName(f.a)} vs ${b.teamName(f.b)}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '#${f.sequence} · ${f.kind} · cycle ${f.cycle}, round ${f.round} · ${f.status} / ${f.phase}',
                          ),
                          if (c.mode == 'round_robin' &&
                              f.kind == 'league' &&
                              b.teams.length.isOdd)
                            Text(
                              'Bye: ${b.teams.where((t) => !(roundTeams['${f.cycle}:${f.round}'] ?? <String>{}).contains(t.id)).map((t) => t.name).join(', ')}',
                            ),
                          if (f.phase == 'finished')
                            Text('${f.scoreA} – ${f.scoreB}'),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: locked
                                    ? null
                                    : () =>
                                          context.push('/matches/${f.matchId}'),
                                child: Text(
                                  f.phase == 'finished'
                                      ? 'Review result'
                                      : 'Open match',
                                ),
                              ),
                              if (c.status == 'active' &&
                                  f.phase == 'scheduled' &&
                                  f.status != 'cancelled') ...[
                                TextButton(
                                  onPressed: locked
                                      ? null
                                      : () => _manage(
                                          f,
                                          f.status == 'postponed'
                                              ? 'restore'
                                              : 'postpone',
                                        ),
                                  child: Text(
                                    f.status == 'postponed'
                                        ? 'Restore'
                                        : 'Postpone',
                                  ),
                                ),
                                TextButton(
                                  onPressed: locked
                                      ? null
                                      : () => _manage(f, 'cancel'),
                                  child: const Text('Cancel unplayed fixture'),
                                ),
                              ],
                              if (c.status == 'active' && f.phase == 'finished')
                                TextButton(
                                  onPressed: locked
                                      ? null
                                      : () async {
                                          final reason = await _reason();
                                          if (reason == null || !mounted) {
                                            return;
                                          }
                                          final k = _key();
                                          await _run(
                                            (r) => r.reopen(
                                              c.id,
                                              f.matchId,
                                              reason: reason,
                                              requestId: k,
                                            ),
                                          );
                                        },
                                  child: const Text('Correct result'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (c.status == 'active') ...[
                  const SizedBox(height: 20),
                  Text(
                    'Eligible leaders: ${b.championCandidates.map(b.teamName).join(', ')}',
                  ),
                  if (b.championCandidates.length > 1)
                    const Text(
                      'Title unresolved. No champion is selected automatically.',
                    ),
                  if (b.candidates.length == 2 &&
                      b.championCandidates.length > 1)
                    OutlinedButton(
                      onPressed: locked
                          ? null
                          : () {
                              final k = _key();
                              _run((r) async {
                                await r.playoff(c.id, requestId: k);
                              });
                            },
                      child: const Text('Schedule championship playoff'),
                    ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: locked ? null : () => _complete(b),
                    icon: const Icon(Icons.emoji_events_outlined),
                    label: const Text('Complete competition'),
                  ),
                ],
                if (b.history.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  const SectionTitle('Administrative history'),
                  const SizedBox(height: 12),
                  for (final action in b.history)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        (action['kind'] as String).replaceAll('_', ' '),
                      ),
                      subtitle: Text(action['reason'] as String),
                    ),
                ],
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class CompetitionReasonDialog extends StatefulWidget {
  const CompetitionReasonDialog({super.key});
  @override
  State<CompetitionReasonDialog> createState() => _CompetitionReasonState();
}

class _CompetitionReasonState extends State<CompetitionReasonDialog> {
  final _form = GlobalKey<FormState>(), _reason = TextEditingController();
  bool _submitted = false;
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Administrative change'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _reason,
        maxLength: 300,
        decoration: const InputDecoration(labelText: 'Reason'),
        validator: (v) =>
            v == null || v.trim().isEmpty ? 'Explain this change' : null,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_submitted || !_form.currentState!.validate()) {
            return;
          }
          _submitted = true;
          Navigator.pop(context, _reason.text.trim());
        },
        child: const Text('Confirm change'),
      ),
    ],
  );
}

class CompetitionEndInput {
  CompetitionEndInput(this.champion, this.shared, this.early, this.reason);
  final String? champion;
  final bool shared, early;
  final String reason;
}

class CompetitionEndDialog extends StatefulWidget {
  const CompetitionEndDialog({super.key, required this.bundle});
  final CompetitionBundle bundle;
  @override
  State<CompetitionEndDialog> createState() => _CompetitionEndState();
}

class _CompetitionEndState extends State<CompetitionEndDialog> {
  final _form = GlobalKey<FormState>(), _reason = TextEditingController();
  bool _early = false, _submitted = false;
  late String _choice = widget.bundle.championCandidates.length == 1
      ? widget.bundle.championCandidates.single
      : 'shared';
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Finalize championship'),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The champion decision and results will be locked. Tied teams stay tied unless you explicitly resolve the title.',
              ),
              const SizedBox(height: 18),
              DropdownButtonFormField<String>(
                initialValue: _choice,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Champion decision',
                ),
                items: [
                  if (widget.bundle.championCandidates.length > 1)
                    const DropdownMenuItem(
                      value: 'shared',
                      child: Text('Shared championship'),
                    ),
                  ...widget.bundle.championCandidates.map(
                    (id) => DropdownMenuItem(
                      value: id,
                      child: Text(widget.bundle.teamName(id)),
                    ),
                  ),
                ],
                onChanged: (v) => setState(() => _choice = v!),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _early,
                onChanged: (v) => setState(() => _early = v!),
                title: const Text('Explicitly end early'),
                subtitle: const Text(
                  'Cancel remaining unplayed fixtures; a reason is required.',
                ),
              ),
              TextFormField(
                controller: _reason,
                maxLength: 300,
                decoration: const InputDecoration(labelText: 'Decision reason'),
                validator: (v) =>
                    (_early ||
                            _choice != 'shared' &&
                                widget.bundle.championCandidates.length > 1) &&
                        (v == null || v.trim().isEmpty)
                    ? 'Explain the administrative decision'
                    : null,
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
          if (_submitted || !_form.currentState!.validate()) {
            return;
          }
          _submitted = true;
          Navigator.pop(
            context,
            CompetitionEndInput(
              _choice == 'shared' ? null : _choice,
              _choice == 'shared',
              _early,
              _reason.text.trim(),
            ),
          );
        },
        child: const Text('Save final decision'),
      ),
    ],
  );
}
