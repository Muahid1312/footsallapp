import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../data/balance_repository.dart';
import '../domain/team_balancer.dart';

class BalancePreviewScreen extends ConsumerStatefulWidget {
  const BalancePreviewScreen({super.key, required this.sessionId});
  final String sessionId;
  @override
  ConsumerState<BalancePreviewScreen> createState() => _BalancePreviewState();
}

class _BalancePreviewState extends ConsumerState<BalancePreviewScreen> {
  final _seed = TextEditingController(text: '1'),
      _iterations = TextEditingController(text: '2000');
  String _mode = 'balanced';
  bool _uneven = false, _busy = false, _dirty = true;
  String? _error;
  BalancePreview? _preview;
  SessionBundle? _session;
  Map<String, String> _locks = {};
  bool _defaultsLoaded = false;
  @override
  void initState() {
    super.initState();
    Future.microtask(_generate);
  }

  @override
  void dispose() {
    _seed.dispose();
    _iterations.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (!mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      if (!_defaultsLoaded) {
        _mode = (await ref.read(settingsProvider.future)).generation;
        _defaultsLoaded = true;
      }
      final seed = int.tryParse(_seed.text),
          iterations = int.tryParse(_iterations.text);
      if (seed == null ||
          seed < 0 ||
          seed > 2147483647 ||
          iterations == null ||
          iterations < 0 ||
          iterations > 20000) {
        throw ArgumentError(
          'Use a seed from 0–2147483647 and 0–20000 swap attempts.',
        );
      }
      final repo = await ref.read(balanceRepositoryProvider.future);
      final locks = await repo.locks(widget.sessionId);
      if (mounted) {
        setState(() => _locks = locks);
      }
      final bundle = await ref.read(sessionProvider(widget.sessionId).future);
      final preview = await repo.preview(
        widget.sessionId,
        mode: _mode,
        seed: seed,
        iterations: iterations,
        allowUneven: _uneven,
      );
      if (mounted) {
        setState(() {
          _session = bundle;
          _preview = preview;
          _error = null;
          _dirty = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ArgumentError
              ? e.message.toString()
              : e is StateError
              ? e.message
              : 'Could not generate teams. Retry without changing saved history.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _lock(String player, String team) async {
    setState(() => _busy = true);
    try {
      await (await ref.read(balanceRepositoryProvider.future)).setLock(
        widget.sessionId,
        player,
        _locks.containsKey(player) ? null : team,
      );
      if (mounted) {
        refreshData(ref);
        await _generate();
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

  Future<void> _swap(String player, String team) async {
    final old = _preview!;
    final session = _session!;
    final other = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(c).height * .7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(20),
            children: [
              const Text('Swap with an unlocked player on another team'),
              for (final t in session.teams.where((t) => t.id != team))
                for (final id in old.result.assignments[t.id]!.where(
                  (id) => !_locks.containsKey(id),
                ))
                  ListTile(
                    title: Text(
                      session.attendees.singleWhere((p) => p.id == id).name,
                    ),
                    subtitle: Text(t.name),
                    leading: const Icon(Icons.swap_horiz),
                    onTap: () => Navigator.pop(c, id),
                  ),
            ],
          ),
        ),
      ),
    );
    if (other == null || !mounted) {
      return;
    }
    try {
      final map = {
        for (final e in old.result.assignments.entries)
          e.key: e.value
              .map(
                (id) => id == player
                    ? other
                    : id == other
                    ? player
                    : id,
              )
              .toList(),
      };
      final result = describeBalance(old.request, map);
      setState(
        () => _preview = BalancePreview(old.request, result, old.fingerprint),
      );
    } catch (e) {
      showError(context, e);
    }
  }

  Future<void> _confirm() async {
    if (_busy || _dirty || _error != null || _preview == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      await (await ref.read(
        balanceRepositoryProvider.future,
      )).confirm(widget.sessionId, _preview!);
      if (mounted) {
        refreshData(ref);
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        showError(context, e);
        setState(() => _dirty = true);
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
      appBar: AppBar(title: const Text('Balance preview')),
      body: Content(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Eyebrow('Fairer teams. Same friends.'),
            const SizedBox(height: 12),
            Text(
              'Find the balance.',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Preview only: saved rosters change after confirmation. Locks persist for future generation in this unplayed session.',
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(labelText: 'Generation mode'),
              items: const [
                DropdownMenuItem(
                  value: 'balanced',
                  child: Text('Balanced · skills and positions'),
                ),
                DropdownMenuItem(value: 'random', child: Text('Seeded random')),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _mode = v!;
                      _dirty = true;
                    }),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _seed,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Reproducible seed',
                    ),
                    onChanged: (_) => setState(() => _dirty = true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _iterations,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Swap attempt limit',
                    ),
                    onChanged: (_) => setState(() => _dirty = true),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _uneven,
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _uneven = v;
                      _dirty = true;
                    }),
              title: const Text('Explicitly allow uneven sizes'),
              subtitle: const Text(
                'Only needed when locks make the one-player size limit impossible. Every team must still be nonempty.',
              ),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          _seed.text =
                              '${((int.tryParse(_seed.text) ?? 0) + 1) % 2147483648}';
                          _generate();
                        },
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Regenerate'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _generate,
                  child: const Text('Generate with exact seed'),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              SurfaceCard(
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFBBF24)),
                ),
              ),
            ],
            if (_preview != null && _session != null) ...[
              const SizedBox(height: 24),
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _preview!.result.quality,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Strength spread ${_preview!.result.spread.toStringAsFixed(2)} · seed ${_preview!.result.seed}',
                    ),
                    Text(
                      '${_preview!.result.method} · ${_preview!.result.evaluations} evaluated candidates',
                    ),
                    const Text(
                      'Estimated strength = average skill + 0.5 per player above average team size. These are planning estimates, not guarantees of equal ability or results.',
                    ),
                    for (final warning in _preview!.result.warnings)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          warning,
                          style: const TextStyle(color: Color(0xFFFBBF24)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              for (final t in _session!.teams) ...[
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(height: 4, color: Color(t.colorValue)),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Builder(
                          builder: (context) {
                            final m = _preview!.result.metrics.singleWhere(
                              (m) => m.teamId == t.id,
                            );
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.name,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                Text(
                                  '${m.size} players · avg ${m.average.toStringAsFixed(2)} · strength ${m.strength.toStringAsFixed(2)} · ${m.keepers} GK',
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      for (final id in _preview!.result.assignments[t.id]!)
                        Builder(
                          builder: (context) {
                            final p = _session!.attendees.singleWhere(
                                  (p) => p.id == id,
                                ),
                                locked = _locks.containsKey(id);
                            return ListTile(
                              leading: PlayerAvatar(p, radius: 22),
                              title: Text(p.name),
                              subtitle: Text(
                                '${p.preferredPosition}${p.secondaryPosition == null ? '' : ' / ${p.secondaryPosition}'} · Skill ${p.skillRating}${p.goalkeeperEligible ? ' · GK' : ''}',
                              ),
                              onTap: _busy || _dirty || _error != null || locked
                                  ? null
                                  : () => _swap(id, t.id),
                              trailing: IconButton(
                                onPressed: _busy ? null : () => _lock(id, t.id),
                                tooltip: locked
                                    ? 'Unlock ${p.name}'
                                    : 'Lock ${p.name} to ${t.name}',
                                icon: Icon(
                                  locked ? Icons.lock : Icons.lock_open,
                                  color: locked
                                      ? AppColors.emerald
                                      : AppColors.muted,
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                onPressed: _busy || _dirty || _error != null ? null : _confirm,
                icon: const Icon(Icons.check),
                label: const Text('Confirm teams'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tap an unlocked player to swap. History with scheduled or played matches is never overwritten.',
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    ),
  );
}
