import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../data/match_repository.dart';
import '../domain/match.dart';
import 'match_dialogs.dart';
import 'match_timeline.dart';
import '../../competitions/data/competition_repository.dart';
import '../../competitions/presentation/competition_screen.dart'
    show CompetitionReasonDialog;

class MatchCenterScreen extends ConsumerStatefulWidget {
  const MatchCenterScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<MatchCenterScreen> createState() => _MatchCenterScreenState();
}

class _MatchCenterScreenState extends ConsumerState<MatchCenterScreen> {
  Timer? _ticker;
  bool _busy = false,
      _dialogOpen = false,
      _checkpointBusy = false,
      _haptic = false,
      _expirySignaled = false;
  int _ticks = 0;
  String _key() => const Uuid().v4();
  bool get _locked => _busy || _dialogOpen;
  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      final b = ref.read(matchProvider(widget.id)).valueOrNull;
      _ticks++;
      if (b?.match.phase == 'live') {
        setState(() {});
      }
      if (b != null &&
          b.match.phase == 'live' &&
          b.timer.elapsedMillis(b.match, ref.read(matchClockProvider)) >=
              b.match.durationSeconds * 1000) {
        if (_haptic && !_expirySignaled) {
          _expirySignaled = true;
          HapticFeedback.vibrate().catchError((Object _) {});
        }
      }
      if (_ticks % 5 == 0 && b?.match.phase == 'live') {
        _checkpoint();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _checkpoint() async {
    if (_checkpointBusy) {
      return;
    }
    _checkpointBusy = true;
    try {
      await (await ref.read(
        matchRepositoryProvider.future,
      )).checkpoint(widget.id);
      if (mounted) {
        ref.read(timerPersistenceErrorProvider.notifier).state = false;
      }
    } catch (_) {
      if (mounted) {
        ref.read(timerPersistenceErrorProvider.notifier).state = true;
      }
    } finally {
      _checkpointBusy = false;
    }
  }

  Future<void> _perform(
    Future<void> Function(MatchRepository) operation,
  ) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await operation(await ref.read(matchRepositoryProvider.future));
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

  Future<T?> _dialog<T>(
    Widget dialog, {
    Future<void> Function()? beforeOpen,
  }) async {
    if (_locked) {
      return null;
    }
    setState(() => _dialogOpen = true);
    try {
      if (beforeOpen != null) {
        await beforeOpen();
      }
      if (!mounted) {
        return null;
      }
      return await showDialog<T>(context: context, builder: (_) => dialog);
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _dialogOpen = false);
      }
    }
  }

  Future<void> _start(MatchBundle b) async {
    final selected = await _dialog<Map<String, List<String>>>(
      StartingLineupDialog(bundle: b),
    );
    if (selected != null && mounted) {
      final key = _key();
      await _perform((repo) => repo.start(widget.id, selected, requestId: key));
    }
  }

  Future<void> _record(
    MatchBundle b,
    String type, {
    MatchEvent? original,
  }) async {
    int? observedTime;
    final input = await _dialog<EventInput>(
      MatchEventDialog(bundle: b, type: type, original: original),
      beforeOpen: original == null
          ? () async {
              final clock = ref.read(matchClockProvider);
              await clock.synchronize();
              observedTime = b.timer.elapsedMillis(b.match, clock);
            }
          : null,
    );
    if (input == null || !mounted) {
      return;
    }
    final key = _key();
    await _perform((repo) async {
      if (original == null) {
        await repo.record(
          widget.id,
          type: type,
          teamId: input.teamId,
          playerId: input.playerId,
          assistId: input.assistId,
          notes: input.notes,
          occurredAtMillis: observedTime,
          requestId: key,
        );
      } else {
        await repo.correctGoal(
          widget.id,
          original.id,
          playerId: input.playerId,
          assistId: input.assistId,
          reason: input.notes,
          requestId: key,
        );
      }
    });
  }

  Future<void> _substitute(MatchBundle b) async {
    final input = await _dialog<SubstitutionInput>(
      SubstitutionDialog(bundle: b),
    );
    if (input == null || !mounted) {
      return;
    }
    final key = _key();
    await _perform(
      (repo) => repo.substitute(
        widget.id,
        teamId: input.team,
        outgoingId: input.outgoing,
        incomingId: input.incoming,
        requestId: key,
      ),
    );
  }

  Future<void> _review(MatchBundle b) async {
    final elapsed = await _dialog<int>(RecoveryDialog(bundle: b));
    if (elapsed == null || !mounted) {
      return;
    }
    final key = _key();
    await _perform(
      (repo) => repo.reviewTimer(widget.id, elapsed, requestId: key),
    );
  }

  Future<void> _undo(MatchEvent event) async {
    final reason = await _dialog<String>(const CorrectionReasonDialog());
    if (reason == null || !mounted) {
      return;
    }
    final key = _key();
    await _perform(
      (repo) => repo.undo(widget.id, event.id, reason: reason, requestId: key),
    );
  }

  Future<void> _finish() async {
    if (_locked) {
      return;
    }
    setState(() => _dialogOpen = true);
    bool accepted;
    try {
      accepted = await confirm(
        context,
        title: 'Finish and save this match?',
        message:
            'The current score will become the final result. The timer and event ledger will be locked. Correct mistakes before finishing.',
        action: 'Finish match',
      );
    } finally {
      if (mounted) {
        setState(() => _dialogOpen = false);
      }
    }
    if (!accepted || !mounted) {
      return;
    }
    final key = _key();
    await _perform((repo) => repo.finish(widget.id, requestId: key));
  }

  Future<void> _reopenResult() async {
    final reason = await _dialog<String>(const CompetitionReasonDialog());
    if (reason == null || !mounted) {
      return;
    }
    final key = _key();
    await _perform((repo) async {
      final link = await repo.db.rows(
        'SELECT competition_id FROM competition_fixtures WHERE match_id=?',
        [widget.id],
      );
      if (link.isEmpty) {
        throw StateError(
          'Administrative result reopening is available for active competition fixtures.',
        );
      }
      await CompetitionRepository(repo.db, repo.clock).reopen(
        link.single['competition_id'] as String,
        widget.id,
        reason: reason,
        requestId: key,
      );
    });
  }

  Future<void> _missingGoal(MatchBundle b) async {
    final time = await _dialog<int>(
      CorrectionTimeDialog(maximumMillis: b.timer.accumulatedMillis),
    );
    if (time == null || !mounted) {
      return;
    }
    final input = await _dialog<EventInput>(
      MatchEventDialog(bundle: b, type: 'goal', correctionTime: time),
    );
    if (input == null || !mounted) {
      return;
    }
    final key = _key();
    await _perform(
      (repo) => repo.addCorrectionGoal(
        widget.id,
        teamId: input.teamId,
        playerId: input.playerId,
        assistId: input.assistId,
        elapsedMillis: time,
        reason: input.notes,
        requestId: key,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Match Center'),
        actions: [
          IconButton(
            onPressed: () => ref.invalidate(matchProvider(widget.id)),
            tooltip: 'Reload saved match',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Content(
        child: AsyncContent(
          value: ref.watch(matchProvider(widget.id)),
          retry: () => retryData(ref),
          builder: (b) {
            if (b == null) {
              return const Center(child: Text('Match not found.'));
            }
            final elapsed = b.timer.elapsedMillis(
              b.match,
              ref.watch(matchClockProvider),
            );
            final remaining = b.match.durationSeconds * 1000 - elapsed;
            final expired = remaining <= 0;
            final reviewing =
                b.match.resultRevision > 0 && b.match.phase == 'paused';
            final canPlay =
                b.match.phase == 'live' &&
                !expired &&
                !b.timer.recoveryRequired &&
                !_locked;
            final latest = b.actions.reversed
                .map(
                  (a) => b.events
                      .where(
                        (e) =>
                            e.id == a.eventId &&
                            !e.isVoided &&
                            ['goal', 'foul'].contains(e.type),
                      )
                      .firstOrNull,
                )
                .whereType<MatchEvent>()
                .firstOrNull;
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Eyebrow(
                  b.match.isFinal
                      ? 'Saved match'
                      : 'Saturday · ${b.match.phase}',
                ),
                const SizedBox(height: 16),
                MatchScoreboard(bundle: b),
                const SizedBox(height: 18),
                SurfaceCard(
                  child: Column(
                    children: [
                      Text(
                        b.match.isFinal || reviewing
                            ? 'ELAPSED PLAYING TIME'
                            : expired
                            ? 'TIME EXPIRED · AWAITING FINISH'
                            : 'PLAYING TIME REMAINING',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: expired && !b.match.isFinal
                              ? const Color(0xFFFBBF24)
                              : AppColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.3,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        matchTime(
                          b.match.isFinal || reviewing ? elapsed : remaining,
                          countdown: !b.match.isFinal && !reviewing,
                        ),
                        style: const TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                          fontFeatures: [FontFeature.tabularFigures()],
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        '${b.match.durationSeconds ~/ 60} minute match · ${b.match.phase.toUpperCase()}',
                      ),
                    ],
                  ),
                ),
                if (ref.watch(timerPersistenceErrorProvider)) ...[
                  const SizedBox(height: 12),
                  const SurfaceCard(
                    child: Text(
                      'A timer checkpoint could not be saved. Reload or pause and try again before leaving the app.',
                      style: TextStyle(color: Color(0xFFFBBF24)),
                    ),
                  ),
                ],
                if (b.timer.recoveryRequired) ...[
                  const SizedBox(height: 16),
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Recovered paused',
                          style: TextStyle(
                            color: Color(0xFFFBBF24),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'The app restarted. Review the recovered playing time before resuming or finishing. No winner has been declared.',
                        ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: _locked ? null : () => _review(b),
                          child: const Text('Review recovered timer'),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (_busy) const LinearProgressIndicator(),
                if (b.match.resultRevision > 0) ...[
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Administrative result revision ${b.match.resultRevision}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Text(
                          'Prior results and their correction reasons remain in the audit history. Playing time cannot resume in result review.',
                        ),
                        if (b.match.phase == 'paused')
                          OutlinedButton(
                            onPressed: _locked ? null : () => _missingGoal(b),
                            child: const Text(
                              'Add a missing goal at its original time',
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (b.match.phase == 'scheduled')
                  FilledButton.icon(
                    onPressed: _locked ? null : () => _start(b),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Select lineups & start'),
                  ),
                if (b.match.isOpen) ...[
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            _locked ||
                                b.timer.recoveryRequired ||
                                b.match.resultRevision > 0
                            ? null
                            : () {
                                final key = _key();
                                _perform(
                                  (repo) => b.match.phase == 'live'
                                      ? repo.pause(widget.id, requestId: key)
                                      : repo.resume(widget.id, requestId: key),
                                );
                              },
                        icon: Icon(
                          b.match.phase == 'live'
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                        label: Text(
                          b.match.phase == 'live' ? 'Pause' : 'Resume',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _locked || b.timer.recoveryRequired
                            ? null
                            : _finish,
                        icon: const Icon(Icons.flag_outlined),
                        label: const Text('Finish match'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: canPlay ? () => _record(b, 'goal') : null,
                          icon: const Icon(Icons.sports_soccer),
                          label: const Text('Goal'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: canPlay ? () => _record(b, 'foul') : null,
                          icon: const Icon(Icons.sports_outlined),
                          label: const Text('Foul'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: canPlay ? () => _substitute(b) : null,
                        icon: const Icon(Icons.swap_horiz),
                        label: const Text('Substitute'),
                      ),
                      TextButton.icon(
                        onPressed: latest == null || _locked
                            ? null
                            : () => _undo(latest),
                        icon: const Icon(Icons.undo),
                        label: const Text('Undo latest event'),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _haptic,
                    onChanged: (v) => setState(() => _haptic = v),
                    title: const Text('Haptic alert at zero'),
                    subtitle: const Text(
                      'While the Match Center is open; results are finalized manually.',
                    ),
                  ),
                ],
                if (b.match.isFinal) ...[
                  Text(
                    b.match.phase == 'cancelled'
                        ? 'Cancelled · no finalized result'
                        : b.result,
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () =>
                        context.push('/matches/${widget.id}/summary'),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('View match summary'),
                  ),
                  if (b.match.phase == 'finished')
                    AsyncContent(
                      value: ref.watch(
                        correctableCompetitionProvider(widget.id),
                      ),
                      builder: (id) => id == null
                          ? const SizedBox.shrink()
                          : TextButton.icon(
                              onPressed: _locked ? null : _reopenResult,
                              icon: const Icon(Icons.history),
                              label: const Text('Correct competition result'),
                            ),
                    ),
                ],
                const SizedBox(height: 24),
                const SectionTitle('On the pitch'),
                const SizedBox(height: 12),
                if (b.match.phase == 'scheduled')
                  const Text(
                    'Starting lineups are selected when the match starts.',
                  )
                else
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final t in [b.teamA, b.teamB]) ...[
                          Text(
                            t.name,
                            style: TextStyle(
                              color: Color(t.colorValue),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            b.match.isFinal
                                ? '${b.stints.where((s) => s.teamId == t.id).map((s) => s.playerId).toSet().length} players participated'
                                : b
                                      .onField(t.id)
                                      .map((p) => p.name)
                                      .join(' · '),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 28),
                const SectionTitle('Match timeline'),
                const SizedBox(height: 12),
                MatchTimeline(
                  bundle: b,
                  canCorrect: b.match.isOpen && !_locked,
                  onUndo: _undo,
                  onCorrect: (event) => _record(b, 'goal', original: event),
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => context.go('/sessions/${b.match.sessionId}'),
                  child: const Text('Back to session'),
                ),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class MatchScoreboard extends StatelessWidget {
  const MatchScoreboard({super.key, required this.bundle});
  final MatchBundle bundle;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: LayoutBuilder(
      builder: (context, size) => Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final team in [bundle.teamA, bundle.teamB]) ...[
                if (team.id == bundle.teamB.id) const SizedBox(width: 32),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: Color(team.colorValue).withValues(alpha: .15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.shield_outlined,
                          color: Color(team.colorValue),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Tooltip(
                        message: team.name,
                        child: Text(
                          team.name,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final team in [bundle.teamA, bundle.teamB]) ...[
                if (team.id == bundle.teamB.id)
                  const SizedBox(
                    width: 32,
                    child: Center(
                      child: Text(
                        '–',
                        style: TextStyle(color: AppColors.muted, fontSize: 24),
                      ),
                    ),
                  ),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${bundle.score(team.id)}',
                      style: TextStyle(
                        fontSize: size.maxWidth < 300 ? 52 : 68,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          Row(
            children: [
              for (final team in [bundle.teamA, bundle.teamB]) ...[
                if (team.id == bundle.teamB.id) const SizedBox(width: 32),
                Expanded(
                  child: Text(
                    '${bundle.fouls(team.id)} team fouls',
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}
