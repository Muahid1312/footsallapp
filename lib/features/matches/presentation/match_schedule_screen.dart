import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../app/providers.dart';
import '../../../core/widgets/common.dart';

class MatchScheduleScreen extends ConsumerStatefulWidget {
  const MatchScheduleScreen({super.key, required this.sessionId});
  final String sessionId;
  @override
  ConsumerState<MatchScheduleScreen> createState() =>
      _MatchScheduleScreenState();
}

class _MatchScheduleScreenState extends ConsumerState<MatchScheduleScreen> {
  final _requestId = const Uuid().v4();
  final _minutes = TextEditingController();
  final _form = GlobalKey<FormState>();
  String? _a, _b;
  bool _busy = false;
  bool _initialized = false;
  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy || !_form.currentState!.validate()) {
      return;
    }
    if (_a == null || _b == null || _a == _b) {
      showError(context, ArgumentError('Choose two different session teams.'));
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await (await ref.read(matchRepositoryProvider.future)).create(
        sessionId: widget.sessionId,
        teamAId: _a!,
        teamBId: _b!,
        durationSeconds: int.parse(_minutes.text) * 60,
        requestId: _requestId,
      );
      refreshData(ref);
      if (mounted) {
        context.pushReplacement('/matches/$id');
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

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Schedule match')),
      body: Content(
        child: AsyncContent(
          value: ref.watch(sessionProvider(widget.sessionId)),
          retry: () => retryData(ref),
          builder: (bundle) {
            if (bundle == null) {
              return const Center(child: Text('Session not found.'));
            }
            if (bundle.session.status == 'completed') {
              return const Center(child: Text('This session is complete.'));
            }
            if (!_initialized) {
              _minutes.text = '${bundle.session.matchDurationSeconds ~/ 60}';
              _initialized = true;
            }
            return Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Eyebrow('Matchday · head to head'),
                  const SizedBox(height: 12),
                  Text(
                    'Two teams.\nOne pitch.',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Scheduling a match locks this session’s team identities and rosters. Choose the starting lineups in the Match Center.',
                  ),
                  const SizedBox(height: 28),
                  for (final side in [0, 1]) ...[
                    DropdownButtonFormField<String>(
                      initialValue: side == 0 ? _a : _b,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: side == 0 ? 'Home team' : 'Away team',
                      ),
                      items: bundle.teams
                          .map(
                            (t) => DropdownMenuItem(
                              value: t.id,
                              child: Text(t.name),
                            ),
                          )
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              if (side == 0) {
                                _a = v;
                              } else {
                                _b = v;
                              }
                            }),
                      validator: (v) => v == null ? 'Select a team' : null,
                    ),
                    const SizedBox(height: 20),
                  ],
                  TextFormField(
                    controller: _minutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Duration in minutes',
                    ),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 180
                          ? 'Enter 1–180 minutes'
                          : null;
                    },
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [5, 10, 15, 20]
                        .map(
                          (m) => ActionChip(
                            label: Text('$m min'),
                            onPressed: _busy
                                ? null
                                : () => setState(() => _minutes.text = '$m'),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _busy ? null : _create,
                    icon: const Icon(Icons.sports_soccer),
                    label: Text(_busy ? 'Saving…' : 'Open Match Center'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
