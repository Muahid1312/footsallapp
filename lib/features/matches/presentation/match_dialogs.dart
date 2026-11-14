import 'package:flutter/material.dart';
import '../../../core/widgets/common.dart';
import '../domain/match.dart';

class EventInput {
  const EventInput(this.teamId, this.playerId, this.assistId, this.notes);
  final String teamId, playerId;
  final String? assistId;
  final String notes;
}

class MatchEventDialog extends StatefulWidget {
  const MatchEventDialog({
    super.key,
    required this.bundle,
    required this.type,
    this.original,
    this.correctionTime,
  });
  final MatchBundle bundle;
  final String type;
  final MatchEvent? original;
  final int? correctionTime;
  @override
  State<MatchEventDialog> createState() => _MatchEventDialogState();
}

class _MatchEventDialogState extends State<MatchEventDialog> {
  bool _submitted = false;
  final _form = GlobalKey<FormState>();
  final _notes = TextEditingController();
  late String _team = widget.original?.teamId ?? widget.bundle.teamA.id;
  late String? _player = widget.original?.playerId;
  late String? _assist = widget.original?.assistId;
  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bundle;
    final candidates = b.players
        .where(
          (p) => widget.original == null && widget.correctionTime == null
              ? b.onField(_team).any((on) => on.id == p.id)
              : b.stints.any(
                  (s) =>
                      s.teamId == _team &&
                      s.playerId == p.id &&
                      s.contains(
                        widget.original?.elapsedMillis ??
                            widget.correctionTime!,
                      ),
                ),
        )
        .toList();
    return AlertDialog(
      title: Text(
        widget.original != null || widget.correctionTime != null
            ? 'Correct goal'
            : widget.type == 'goal'
            ? 'Record goal'
            : 'Record player foul',
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _team,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Team'),
                  items: [b.teamA, b.teamB]
                      .map(
                        (t) =>
                            DropdownMenuItem(value: t.id, child: Text(t.name)),
                      )
                      .toList(),
                  onChanged: widget.original != null
                      ? null
                      : (v) {
                          if (v != null) {
                            setState(() {
                              _team = v;
                              _player = null;
                              _assist = null;
                            });
                          }
                        },
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  key: ValueKey('player-$_team'),
                  initialValue: _player,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: widget.type == 'goal'
                        ? 'Scorer'
                        : 'Player committing foul',
                  ),
                  items: candidates
                      .map(
                        (p) =>
                            DropdownMenuItem(value: p.id, child: Text(p.name)),
                      )
                      .toList(),
                  validator: (v) =>
                      v == null ? 'Select an on-field player' : null,
                  onChanged: (v) => setState(() {
                    _player = v;
                    if (_assist == v) {
                      _assist = null;
                    }
                  }),
                ),
                if (widget.type == 'goal') ...[
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    key: ValueKey('assist-$_team-$_player'),
                    initialValue: _assist ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Assist (optional)',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('No assist'),
                      ),
                      ...candidates
                          .where((p) => p.id != _player)
                          .map(
                            (p) => DropdownMenuItem(
                              value: p.id,
                              child: Text(p.name),
                            ),
                          ),
                    ],
                    onChanged: (v) => setState(
                      () => _assist = v == null || v.isEmpty ? null : v,
                    ),
                  ),
                ],
                if (widget.type == 'foul' ||
                    widget.original != null ||
                    widget.correctionTime != null) ...[
                  const SizedBox(height: 18),
                  TextFormField(
                    controller: _notes,
                    maxLength: 300,
                    decoration: InputDecoration(
                      labelText:
                          widget.original != null ||
                              widget.correctionTime != null
                          ? 'Correction reason'
                          : 'Foul notes (optional)',
                    ),
                    validator: (v) =>
                        (widget.original != null ||
                                widget.correctionTime != null) &&
                            (v == null || v.trim().isEmpty)
                        ? 'Explain the correction'
                        : null,
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Only players on the pitch at the event time are eligible.',
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
            if (_submitted) {
              return;
            }
            if (_form.currentState!.validate()) {
              setState(() => _submitted = true);
              Navigator.pop(
                context,
                EventInput(_team, _player!, _assist, _notes.text.trim()),
              );
            }
          },
          child: Text(widget.original != null ? 'Save correction' : 'Confirm'),
        ),
      ],
    );
  }
}

class StartingLineupDialog extends StatefulWidget {
  const StartingLineupDialog({super.key, required this.bundle});
  final MatchBundle bundle;
  @override
  State<StartingLineupDialog> createState() => _StartingLineupDialogState();
}

class _StartingLineupDialogState extends State<StartingLineupDialog> {
  bool _submitted = false;
  late final Map<String, Set<String>> _selected = {
    for (final t in [widget.bundle.teamA, widget.bundle.teamB])
      t.id: t.playerIds.take(5).toSet(),
  };
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Starting lineups'),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose 1–5 starters per team. Unselected teammates start on the bench and can enter through substitutions.',
            ),
            const SizedBox(height: 16),
            for (final t in [widget.bundle.teamA, widget.bundle.teamB]) ...[
              Text(t.name, style: Theme.of(context).textTheme.titleMedium),
              for (final id in t.playerIds)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(widget.bundle.playerName(id)),
                  value: _selected[t.id]!.contains(id),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected[t.id]!.add(id);
                    } else {
                      _selected[t.id]!.remove(id);
                    }
                  }),
                ),
              const SizedBox(height: 12),
            ],
          ],
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
          if (_submitted) {
            return;
          }
          if (_selected.values.any((v) => v.isEmpty || v.length > 5)) {
            showError(
              context,
              ArgumentError('Choose 1–5 starters for each team.'),
            );
            return;
          }
          setState(() => _submitted = true);
          Navigator.pop(context, {
            for (final e in _selected.entries) e.key: e.value.toList(),
          });
        },
        child: const Text('Start match'),
      ),
    ],
  );
}

class SubstitutionInput {
  const SubstitutionInput(this.team, this.outgoing, this.incoming);
  final String team, outgoing, incoming;
}

class SubstitutionDialog extends StatefulWidget {
  const SubstitutionDialog({super.key, required this.bundle});
  final MatchBundle bundle;
  @override
  State<SubstitutionDialog> createState() => _SubstitutionDialogState();
}

class _SubstitutionDialogState extends State<SubstitutionDialog> {
  bool _submitted = false;
  final _form = GlobalKey<FormState>();
  late String _team = widget.bundle.teamA.id;
  String? _out, _in;
  @override
  Widget build(BuildContext context) {
    final b = widget.bundle, team = _team == b.teamA.id ? b.teamA : b.teamB;
    final on = b.onField(_team);
    final bench = b.players
        .where(
          (p) => team.playerIds.contains(p.id) && !on.any((v) => v.id == p.id),
        )
        .toList();
    return AlertDialog(
      title: const Text('Substitution'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _team,
                  decoration: const InputDecoration(labelText: 'Team'),
                  items: [b.teamA, b.teamB]
                      .map(
                        (t) =>
                            DropdownMenuItem(value: t.id, child: Text(t.name)),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() {
                        _team = v;
                        _out = null;
                        _in = null;
                      });
                    }
                  },
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  key: ValueKey('out-$_team'),
                  initialValue: _out,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Coming off'),
                  items: on
                      .map(
                        (p) =>
                            DropdownMenuItem(value: p.id, child: Text(p.name)),
                      )
                      .toList(),
                  validator: (v) =>
                      v == null ? 'Select an outgoing player' : null,
                  onChanged: (v) => setState(() => _out = v),
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  key: ValueKey('in-$_team'),
                  initialValue: _in,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Coming on'),
                  items: bench
                      .map(
                        (p) =>
                            DropdownMenuItem(value: p.id, child: Text(p.name)),
                      )
                      .toList(),
                  validator: (v) =>
                      v == null ? 'Select a benched teammate' : null,
                  onChanged: (v) => setState(() => _in = v),
                ),
                if (bench.isEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'No substitute is available on this team. All its players are on the pitch.',
                  ),
                ],
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
            if (_submitted) {
              return;
            }
            if (_form.currentState!.validate()) {
              setState(() => _submitted = true);
              Navigator.pop(context, SubstitutionInput(_team, _out!, _in!));
            }
          },
          child: const Text('Confirm substitution'),
        ),
      ],
    );
  }
}

class RecoveryDialog extends StatefulWidget {
  const RecoveryDialog({super.key, required this.bundle});
  final MatchBundle bundle;
  @override
  State<RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<RecoveryDialog> {
  bool _submitted = false;
  final _form = GlobalKey<FormState>();
  late final _minutes = TextEditingController(
    text: '${(widget.bundle.timer.accumulatedMillis / 1000).ceil() ~/ 60}',
  );
  late final _seconds = TextEditingController(
    text: '${(widget.bundle.timer.accumulatedMillis / 1000).ceil() % 60}',
  );
  @override
  void dispose() {
    _minutes.dispose();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Review recovered timer'),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The match was paused after restart. Review this estimate from saved timestamps, especially if the device clock changed. The suggested time is rounded up to a whole second.',
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _minutes,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Elapsed minutes',
                      ),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        return n == null || n < 0 ? 'Enter minutes' : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _seconds,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Seconds'),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        return n == null || n < 0 || n > 59 ? 'Use 0–59' : null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Maximum duration: ${matchTime(widget.bundle.match.durationSeconds * 1000)}. Recorded play cannot be moved into the future.',
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
          if (_submitted) {
            return;
          }
          if (_form.currentState!.validate()) {
            setState(() => _submitted = true);
            Navigator.pop(
              context,
              (int.parse(_minutes.text) * 60 + int.parse(_seconds.text)) * 1000,
            );
          }
        },
        child: const Text('Confirm elapsed time'),
      ),
    ],
  );
}

class CorrectionTimeDialog extends StatefulWidget {
  const CorrectionTimeDialog({super.key, required this.maximumMillis});
  final int maximumMillis;
  @override
  State<CorrectionTimeDialog> createState() => _CorrectionTimeState();
}

class _CorrectionTimeState extends State<CorrectionTimeDialog> {
  final _form = GlobalKey<FormState>();
  final _seconds = TextEditingController(text: '0');
  bool _submitted = false;
  @override
  void dispose() {
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Original goal time'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _seconds,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText:
              'Elapsed playing seconds (0–${widget.maximumMillis ~/ 1000})',
        ),
        validator: (v) {
          final n = int.tryParse(v ?? '');
          return n == null || n < 0 || n * 1000 > widget.maximumMillis
              ? 'Enter a time within the recorded match'
              : null;
        },
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
          Navigator.pop(context, int.parse(_seconds.text) * 1000);
        },
        child: const Text('Choose scorer & assist'),
      ),
    ],
  );
}
