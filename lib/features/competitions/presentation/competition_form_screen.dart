import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../app/providers.dart';
import '../../../core/widgets/common.dart';
import '../domain/competition.dart';

class CompetitionFormScreen extends ConsumerStatefulWidget {
  const CompetitionFormScreen({
    super.key,
    required this.sessionId,
    this.competitionId,
  });
  final String sessionId;
  final String? competitionId;
  @override
  ConsumerState<CompetitionFormScreen> createState() => _CompetitionFormState();
}

class _CompetitionFormState extends ConsumerState<CompetitionFormScreen> {
  final _form = GlobalKey<FormState>();
  final _minutes = TextEditingController(text: '10'),
      _cycles = TextEditingController(text: '1'),
      _limit = TextEditingController(text: '6');
  final _win = TextEditingController(text: '3'),
      _draw = TextEditingController(text: '1'),
      _loss = TextEditingController(text: '0');
  final _id = const Uuid().v4();
  String _mode = 'round_robin', _policy = 'both_rotate', _criterion = 'points';
  bool _busy = false, _initialized = false;
  @override
  void dispose() {
    for (final c in [_minutes, _cycles, _limit, _win, _draw, _loss]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _number(TextEditingController c, String label, int min, int max) =>
      TextFormField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        validator: (v) {
          final n = int.tryParse(v ?? '');
          return n == null || n < min || n > max ? 'Use $min–$max' : null;
        },
      );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.competitionId == null
              ? 'Create competition'
              : 'Edit draft rules',
        ),
      ),
      body: Content(
        child: AsyncContent(
          value: ref.watch(sessionProvider(widget.sessionId)),
          retry: () => retryData(ref),
          builder: (b) {
            if (b == null) {
              return const Center(child: Text('Session not found.'));
            }
            CompetitionBundle? editing;
            if (widget.competitionId != null) {
              final saved = ref.watch(
                competitionProvider(widget.competitionId!),
              );
              if (saved.isLoading) {
                return const Center(child: CircularProgressIndicator());
              }
              if (saved.hasError) {
                return EmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not load settings',
                  message: 'Retry without changing saved data.',
                  action: TextButton(
                    onPressed: () => retryData(ref),
                    child: const Text('Retry'),
                  ),
                );
              }
              editing = saved.valueOrNull;
              if (editing == null || editing.competition.status != 'draft') {
                return const Center(
                  child: Text('Only draft settings can be edited.'),
                );
              }
            }
            if (!_initialized) {
              final defaults = ref.watch(settingsProvider);
              if (defaults.isLoading) {
                return const Center(child: CircularProgressIndicator());
              }
              if (defaults.hasError) {
                return const Center(
                  child: Text(
                    'Could not load competition defaults. Reopen this screen to retry.',
                  ),
                );
              }
              final settings = defaults.requireValue;
              _win.text = '${settings.win}';
              _draw.text = '${settings.draw}';
              _loss.text = '${settings.loss}';
              _cycles.text = '${settings.cycles}';
              _limit.text = '${settings.limit}';
              _policy = settings.policy;
              _minutes.text = '${b.session.matchDurationSeconds ~/ 60}';
              _mode = b.session.rotationMode;
              if (editing != null) {
                final c = editing.competition;
                _mode = c.mode;
                _policy = c.drawPolicy;
                _criterion = c.criterion;
                _minutes.text = '${c.duration ~/ 60}';
                _cycles.text = '${c.cycles}';
                _limit.text = '${c.limit}';
                _win.text = '${c.win}';
                _draw.text = '${c.draw}';
                _loss.text = '${c.loss}';
              }

              _initialized = true;
            }
            return Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Eyebrow('One Saturday. One title.'),
                  const SizedBox(height: 12),
                  Text(
                    'Set the rules.',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${b.teams.length} saved session teams. All teams enter in their saved order. Rules lock when fixtures are generated.',
                  ),
                  const SizedBox(height: 24),
                  DropdownButtonFormField<String>(
                    initialValue: _mode,
                    decoration: const InputDecoration(
                      labelText: 'Competition mode',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'round_robin',
                        child: Text('Round robin'),
                      ),
                      DropdownMenuItem(
                        value: 'winner_stays',
                        child: Text('Winner stays'),
                      ),
                    ],
                    onChanged: (v) => setState(() => _mode = v!),
                  ),
                  const SizedBox(height: 18),
                  _number(_minutes, 'Match minutes', 1, 180),
                  const SizedBox(height: 18),
                  if (_mode == 'round_robin')
                    _number(_cycles, 'Round-robin cycles', 1, 10),
                  if (_mode == 'winner_stays') ...[
                    _number(_limit, 'Number of league matches', 1, 100),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                      initialValue: _policy,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Draw rotation',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'both_rotate',
                          child: Text('Both rotate when possible'),
                        ),
                        DropdownMenuItem(
                          value: 'longest',
                          child: Text('Longest-playing team rotates'),
                        ),
                        DropdownMenuItem(
                          value: 'manual',
                          child: Text('Administrator decides'),
                        ),
                      ],
                      onChanged: (v) => setState(() => _policy = v!),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'With one waiting team, “both rotate” falls back to longest-playing. Equal tenure rotates the first-listed playing team. Two teams rematch. Draws never count as wins.',
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                      initialValue: _criterion,
                      decoration: const InputDecoration(
                        labelText: 'Champion criterion',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'points',
                          child: Text('Most competition points'),
                        ),
                        DropdownMenuItem(
                          value: 'wins',
                          child: Text('Most match wins'),
                        ),
                      ],
                      onChanged: (v) => setState(() => _criterion = v!),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const SectionTitle('Competition points'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _number(_win, 'Win', 0, 100)),
                      const SizedBox(width: 10),
                      Expanded(child: _number(_draw, 'Draw', 0, 100)),
                      const SizedBox(width: 10),
                      Expanded(child: _number(_loss, 'Loss', 0, 100)),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    _mode == 'round_robin'
                        ? 'Ranking: points → goal difference → goals scored → balanced head-to-head mini-table. Remaining ties share a position.'
                        : 'The FIFO waiting queue gives every waiting team a turn. Equal championship ${_criterion == 'wins' ? 'wins' : 'points'} require a shared title, playoff, or explicit decision.',
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            if (!_form.currentState!.validate()) {
                              return;
                            }
                            setState(() => _busy = true);
                            try {
                              final repo = await ref.read(
                                competitionRepositoryProvider.future,
                              );
                              if (widget.competitionId == null) {
                                await repo.create(
                                  sessionId: widget.sessionId,
                                  teamIds: b.teams.map((t) => t.id).toList(),
                                  mode: _mode,
                                  durationSeconds:
                                      int.parse(_minutes.text) * 60,
                                  cycles: _mode == 'round_robin'
                                      ? int.parse(_cycles.text)
                                      : 1,
                                  matchLimit: _mode == 'winner_stays'
                                      ? int.parse(_limit.text)
                                      : 6,
                                  win: int.parse(_win.text),
                                  draw: int.parse(_draw.text),
                                  loss: int.parse(_loss.text),
                                  drawPolicy: _policy,
                                  criterion: _criterion,
                                  requestId: _id,
                                );
                              } else {
                                await repo.updateDraft(
                                  widget.competitionId!,
                                  mode: _mode,
                                  durationSeconds:
                                      int.parse(_minutes.text) * 60,
                                  cycles: _mode == 'round_robin'
                                      ? int.parse(_cycles.text)
                                      : 1,
                                  matchLimit: _mode == 'winner_stays'
                                      ? int.parse(_limit.text)
                                      : 6,
                                  win: int.parse(_win.text),
                                  draw: int.parse(_draw.text),
                                  loss: int.parse(_loss.text),
                                  drawPolicy: _policy,
                                  criterion: _criterion,
                                  requestId: _id,
                                );
                              }
                              if (mounted) {
                                refreshData(ref);
                                context.pushReplacement(
                                  '/competitions/${widget.competitionId ?? _id}',
                                );
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
                          },
                    child: Text(_busy ? 'Saving…' : 'Save draft competition'),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
