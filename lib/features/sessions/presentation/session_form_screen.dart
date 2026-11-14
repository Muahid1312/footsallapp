import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utilities/dates.dart';
import '../../../core/widgets/common.dart';

class SessionFormScreen extends ConsumerStatefulWidget {
  const SessionFormScreen({super.key});
  @override
  ConsumerState<SessionFormScreen> createState() => _SessionFormScreenState();
}

class _SessionFormScreenState extends ConsumerState<SessionFormScreen> {
  final _form = GlobalKey<FormState>();
  final _location = TextEditingController();
  final _teamCount = TextEditingController(text: '2');
  final _minutes = TextEditingController(text: '10');
  final _selected = <String>{};
  DateTime _date = nextSaturday();
  String _rotation = 'round_robin';
  bool _saving = false;
  bool _defaultsReady = false;
  @override
  void initState() {
    super.initState();
    _defaults();
  }

  Future<void> _defaults() async {
    try {
      final s = await ref.read(settingsProvider.future);
      if (mounted) {
        setState(() {
          _minutes.text = '${s.minutes}';
          _rotation = s.competition;
          _defaultsReady = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _defaultsReady = true);
      }
    }
  }

  @override
  void dispose() {
    _location.dispose();
    _teamCount.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _chooseDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      selectableDayPredicate: (date) => date.weekday == DateTime.saturday,
      helpText: 'CHOOSE A SATURDAY',
    );
    if (date != null && mounted) {
      setState(() => _date = date);
    }
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    final count = int.parse(_teamCount.text);
    if (_selected.length < count) {
      showError(
        context,
        ArgumentError(
          'Select at least $count players so every team has a player.',
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final id = await (await ref.read(databaseProvider.future)).createSession(
        date: _date,
        location: _location.text,
        durationSeconds: int.parse(_minutes.text) * 60,
        rotationMode: _rotation,
        playerIds: _selected.toList(),
        teamCount: count,
      );
      refreshData(ref);
      if (mounted) {
        context.pushReplacement('/sessions/$id/teams');
      }
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = int.tryParse(_teamCount.text) ?? 0;
    final tooMany = count > _selected.length;
    final uneven =
        count >= 2 &&
        _selected.length >= count &&
        _selected.length % count != 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Create session')),
      body: !_defaultsReady
          ? const Center(child: CircularProgressIndicator())
          : Content(
              child: Form(
                key: _form,
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const Eyebrow('Get matchday ready'),
                    const SizedBox(height: 8),
                    Text(
                      'A new Saturday.\nA clean slate.',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Attendance and teams belong only to this session. Your previous Saturdays stay untouched.',
                    ),
                    const SizedBox(height: 24),
                    SurfaceCard(
                      onTap: _saving ? null : _chooseDate,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.calendar_month,
                            color: AppColors.emerald,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'SESSION DATE',
                                  style: TextStyle(
                                    fontSize: 10,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  sessionDate(_date),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.edit_calendar_outlined),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _location,
                      maxLength: 100,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Pitch / location',
                        hintText: 'Optional',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _minutes,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Match minutes',
                            ),
                            validator: (v) {
                              final n = int.tryParse(v ?? '');
                              return n == null || n < 1 || n > 180
                                  ? 'Use 1–180 minutes'
                                  : null;
                            },
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: TextFormField(
                            controller: _teamCount,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Number of teams',
                            ),
                            validator: (v) {
                              final n = int.tryParse(v ?? '');
                              return n == null || n < 2 || n > 32
                                  ? 'Use 2–32 teams'
                                  : null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    DropdownButtonFormField<String>(
                      initialValue: _rotation,
                      decoration: const InputDecoration(
                        labelText: 'Rotation mode',
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
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _rotation = v);
                        }
                      },
                    ),
                    const SizedBox(height: 28),
                    SectionTitle(
                      'Who’s playing?',
                      action: Text(
                        '${_selected.length} selected',
                        style: const TextStyle(color: AppColors.emerald),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Archived players are excluded from new sessions.',
                    ),
                    const SizedBox(height: 12),
                    AsyncContent(
                      value: ref.watch(playersProvider),
                      retry: () => retryData(ref),
                      builder: (all) {
                        final players = all
                            .where((p) => !p.isArchived)
                            .toList();
                        if (players.isEmpty) {
                          return EmptyState(
                            icon: Icons.person_add_alt,
                            title: 'Add your squad first',
                            message:
                                'You need at least two active players to create teams.',
                            action: OutlinedButton(
                              onPressed: () => context.push('/players/new'),
                              child: const Text('Add a player'),
                            ),
                          );
                        }
                        return Column(
                          children: [
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _saving
                                    ? null
                                    : () => setState(() {
                                        if (_selected.length ==
                                            players.length) {
                                          _selected.clear();
                                        } else {
                                          _selected.addAll(
                                            players.map((p) => p.id),
                                          );
                                        }
                                      }),
                                child: Text(
                                  _selected.length == players.length
                                      ? 'Deselect all'
                                      : 'Select all',
                                ),
                              ),
                            ),
                            ...players.map(
                              (p) => CheckboxListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                value: _selected.contains(p.id),
                                onChanged: _saving
                                    ? null
                                    : (v) => setState(() {
                                        if (v == true) {
                                          _selected.add(p.id);
                                        } else {
                                          _selected.remove(p.id);
                                        }
                                      }),
                                secondary: PlayerAvatar(p, radius: 20),
                                title: Text(p.name),
                                subtitle: Text(
                                  '${p.preferredPosition} · Skill ${p.skillRating}',
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                    if (tooMany)
                      _Notice(
                        'You selected ${_selected.length} players for $count teams. Add more players or reduce the team count.',
                      ),
                    if (uneven)
                      _Notice(
                        'Uneven squad: teams will have ${_selected.length ~/ count}–${(_selected.length / count).ceil()} players. Everyone will be included.',
                      ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _saving ? null : _create,
                      icon: const Icon(Icons.auto_awesome),
                      label: Text(
                        _saving
                            ? 'Creating session…'
                            : 'Create session & generate teams',
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Teams are randomly distributed, not skill balanced. You can move or swap players next.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, color: Color(0xFFFBBF24)),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
