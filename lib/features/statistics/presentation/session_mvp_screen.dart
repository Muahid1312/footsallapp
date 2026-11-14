import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../domain/statistics.dart';

class SessionMvpScreen extends ConsumerStatefulWidget {
  const SessionMvpScreen({super.key, required this.sessionId});
  final String sessionId;
  @override
  ConsumerState<SessionMvpScreen> createState() => _SessionMvpState();
}

class _SessionMvpState extends ConsumerState<SessionMvpScreen> {
  final _form = GlobalKey<FormState>();
  final _goals = TextEditingController(text: '4'),
      _assists = TextEditingController(text: '3'),
      _wins = TextEditingController(text: '2'),
      _fouls = TextEditingController(text: '-1'),
      _reason = TextEditingController();
  bool _initialized = false, _busy = false, _dirty = false;
  String? _choice;
  String _request = const Uuid().v4();
  void _changed() {
    setState(() => _request = const Uuid().v4());
  }

  @override
  void dispose() {
    for (final c in [_goals, _assists, _wins, _fouls, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _weights() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    setState(() => _busy = true);
    try {
      await (await ref.read(statisticsRepositoryProvider.future)).setMvpWeights(
        widget.sessionId,
        MvpWeights(
          goal: int.parse(_goals.text),
          assist: int.parse(_assists.text),
          win: int.parse(_wins.text),
          foul: int.parse(_fouls.text),
        ),
      );
      if (mounted) {
        refreshData(ref);
        await ref.read(mvpProvider(widget.sessionId).future);
      }
      if (mounted) {
        setState(() => _dirty = false);
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

  Future<void> _confirm() async {
    if (_busy || _dirty || _choice == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await (await ref.read(statisticsRepositoryProvider.future)).confirmMvp(
        widget.sessionId,
        playerId: _choice == 'shared' ? null : _choice,
        shared: _choice == 'shared',
        reason: _reason.text,
        requestId: _request,
      );
      if (mounted) {
        refreshData(ref);
        await ref.read(mvpProvider(widget.sessionId).future);
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

  Widget _weight(TextEditingController c, String label, bool locked) =>
      SizedBox(
        width: 135,
        child: TextFormField(
          controller: c,
          enabled: !locked && !_busy,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          decoration: InputDecoration(labelText: label),
          onChanged: (_) {
            _changed();
            setState(() => _dirty = true);
          },
          validator: (v) {
            final n = int.tryParse(v ?? '');
            return n == null || n < -100 || n > 100 ? 'Use -100 to 100' : null;
          },
        ),
      );
  String _selection(Map<String, dynamic> d) {
    final ids = List<String>.from(
          jsonDecode(d['selected_ids_json'] as String) as List,
        ),
        snapshot =
            jsonDecode(d['calculation_json'] as String) as Map<String, dynamic>;
    final candidates = (snapshot['candidates'] as List)
        .cast<Map<String, dynamic>>();
    return ids
        .map(
          (id) =>
              candidates.where((c) => c['player_id'] == id).firstOrNull?['name']
                  as String? ??
              'Recorded player',
        )
        .join(', ');
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Session MVP')),
      body: Content(
        child: AsyncContent(
          value: ref.watch(mvpProvider(widget.sessionId)),
          retry: () => retryData(ref),
          builder: (m) {
            final session = ref
                .watch(sessionProvider(widget.sessionId))
                .valueOrNull;
            final closed = session?.session.status == 'completed',
                locked = m.decisions.isNotEmpty;
            if (!_initialized) {
              _goals.text = '${m.weights.goal}';
              _assists.text = '${m.weights.assist}';
              _wins.text = '${m.weights.win}';
              _fouls.text = '${m.weights.foul}';
              _initialized = true;
            }
            if (_choice == null ||
                (_choice == 'shared' && m.leaders.length < 2) ||
                (_choice != 'shared' &&
                    !m.candidates.any((c) => c.player.id == _choice))) {
              _choice = m.leaders.length > 1 ? 'shared' : m.leaders.firstOrNull;
            }
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Eyebrow('A calculated award'),
                const SizedBox(height: 12),
                Text(
                  'Saturday’s standout.',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  'MVP uses transparent recorded contributions. It is not an objective measure of overall player ability and never changes skill ratings.',
                ),
                if (!closed) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Provisional calculation: finish all matches and competitions, then complete this session before confirming an award.',
                    style: TextStyle(color: Color(0xFFFBBF24)),
                  ),
                ],
                const SizedBox(height: 20),
                Form(
                  key: _form,
                  child: SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Calculation weights',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 16,
                          children: [
                            _weight(_goals, 'Goal points', locked),
                            _weight(_assists, 'Assist points', locked),
                            _weight(_wins, 'Team-win points', locked),
                            _weight(_fouls, 'Foul points', locked),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          locked
                              ? 'Calculation weights are locked after the first confirmed award.'
                              : 'Save weight changes to recalculate before confirming.',
                        ),
                        if (!locked)
                          TextButton(
                            onPressed: _busy ? null : _weights,
                            child: const Text('Save weights & recalculate'),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                if (m.decisions.isNotEmpty) ...[
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Eyebrow('Confirmed award'),
                        const SizedBox(height: 8),
                        Text(
                          _selection(m.decisions.first),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          'Method: ${(m.decisions.first['method'] as String).replaceAll('_', ' ')} · revision ${m.decisions.first['revision']}',
                        ),
                        if ((m.decisions.first['reason'] as String?)
                                ?.isNotEmpty ==
                            true)
                          Text(m.decisions.first['reason'] as String),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                if (m.candidates.isEmpty)
                  const EmptyState(
                    icon: Icons.emoji_events_outlined,
                    title: 'No eligible participants',
                    message:
                        'The award needs valid finalized match participation. Bench-only attendance is excluded.',
                  ),
                if (m.candidates.isNotEmpty) ...[
                  Text(
                    m.leaders.length == 1
                        ? 'Calculated leader: ${m.candidates.first.player.name}'
                        : 'Tied calculated leaders: ${m.candidates.where((c) => m.leaders.contains(c.player.id)).map((c) => c.player.name).join(', ')}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  for (final c in m.candidates)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SurfaceCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                PlayerAvatar(c.player, radius: 22),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    c.player.name,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                Text(
                                  '${c.score} pts',
                                  style: const TextStyle(
                                    color: AppColors.emerald,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '${c.stats.appearances} matches · ${c.stats.goals} G · ${c.stats.assists} A · ${c.stats.wins} W · ${c.stats.fouls} fouls',
                            ),
                            Text(
                              'Goals ${c.breakdown['goals']} + assists ${c.breakdown['assists']} + wins ${c.breakdown['wins']} + fouls ${c.breakdown['fouls']} = ${c.score} points',
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_choice),
                    initialValue: _choice,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Confirm or override recipient',
                    ),
                    items: [
                      if (m.leaders.length > 1)
                        const DropdownMenuItem(
                          value: 'shared',
                          child: Text(
                            'Shared award for tied calculated leaders',
                          ),
                        ),
                      ...m.candidates.map(
                        (c) => DropdownMenuItem(
                          value: c.player.id,
                          child: Text(c.player.name),
                        ),
                      ),
                    ],
                    onChanged: !closed || _busy
                        ? null
                        : (v) {
                            setState(() => _choice = v);
                            _changed();
                          },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _reason,
                    enabled: closed && !_busy,
                    maxLength: 300,
                    onChanged: (_) => _changed(),
                    decoration: const InputDecoration(
                      labelText: 'Optional confirmation / override reason',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: !closed || _busy || _dirty ? null : _confirm,
                    icon: const Icon(Icons.emoji_events_outlined),
                    label: Text(
                      m.decisions.isEmpty
                          ? 'Confirm award'
                          : 'Record revised award',
                    ),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                if (m.decisions.length > 1) ...[
                  const SizedBox(height: 28),
                  const SectionTitle('Award history'),
                  for (final d in m.decisions)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Revision ${d['revision']} · ${_selection(d)}',
                      ),
                      subtitle: Text(
                        '${d['method']}${d['reason'] == null ? '' : ' · ${d['reason']}'}',
                      ),
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
