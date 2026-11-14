import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../domain/match.dart';

class MatchTimeline extends StatelessWidget {
  const MatchTimeline({
    super.key,
    required this.bundle,
    required this.canCorrect,
    required this.onUndo,
    required this.onCorrect,
  });
  final MatchBundle bundle;
  final bool canCorrect;
  final void Function(MatchEvent) onUndo, onCorrect;
  @override
  Widget build(BuildContext context) {
    if (bundle.actions.isEmpty) {
      return EmptyState(
        icon: Icons.timeline,
        title: bundle.match.isFinal
            ? 'No recorded events'
            : 'Waiting for kick-off',
        message: bundle.match.isFinal
            ? 'This imported match has no event timeline.'
            : 'Starts, goals, fouls, substitutions, and corrections appear here.',
      );
    }
    return Column(
      children: bundle.actions.map((a) {
        final event = bundle.events.where((e) => e.id == a.eventId).firstOrNull;
        final target = bundle.events
            .where((e) => e.id == a.targetEventId)
            .firstOrNull;
        final title = switch (a.type) {
          'record' =>
            event?.type == 'goal'
                ? 'Goal · ${bundle.teamName(event?.teamId)}'
                : event?.type == 'foul'
                ? 'Player foul · ${bundle.teamName(event?.teamId)}'
                : '${event?.type ?? 'Event'} · imported',
          'correction' => 'Goal corrected · ${bundle.teamName(event?.teamId)}',
          'undo' =>
            '${target?.type == 'foul' ? 'Foul' : 'Goal'} voided · ${bundle.teamName(target?.teamId)}',
          'substitution' => 'Substitution · ${bundle.teamName(a.teamId)}',
          'start' => 'Match started',
          'pause' => 'Match paused',
          'resume' => 'Match resumed',
          'finish' => 'Match finished',
          'recovery' => 'Recovered paused',
          'timer_review' => 'Timer reviewed',
          'import' => 'Phase 1 record imported',
          _ => a.type,
        };
        final icon = switch (a.type) {
          'record' =>
            event?.type == 'goal' ? Icons.sports_soccer : Icons.sports_outlined,
          'correction' || 'undo' => Icons.history,
          'substitution' => Icons.swap_horiz,
          'start' || 'resume' => Icons.play_arrow,
          'pause' => Icons.pause,
          'finish' => Icons.flag_outlined,
          'recovery' => Icons.warning_amber_rounded,
          _ => Icons.timer_outlined,
        };
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SurfaceCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Icon(
                      icon,
                      color: event?.isVoided == true
                          ? AppColors.muted
                          : AppColors.emerald,
                      size: 22,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      matchTime(a.elapsedMillis),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: event?.isVoided == true
                              ? AppColors.muted
                              : Colors.white,
                          fontWeight: FontWeight.w800,
                          decoration: event?.isVoided == true
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      if (event != null)
                        Text(
                          '${bundle.playerName(event.playerId)}${event.assistId == null ? '' : ' · Assist: ${bundle.playerName(event.assistId)}'}${event.isVoided ? ' · VOIDED' : ''}',
                        ),
                      if (a.type == 'correction' && target != null)
                        Text(
                          'Replaces ${bundle.playerName(target.playerId)} at ${matchTime(target.elapsedMillis)}.',
                        ),
                      if (a.type == 'substitution')
                        Text(
                          '${bundle.playerName(a.outgoingId)} off → ${bundle.playerName(a.incomingId)} on',
                        ),
                      if (a.notes != null && a.notes!.isNotEmpty)
                        Text(a.notes!),
                      if (canCorrect &&
                          event != null &&
                          !event.isVoided &&
                          ['goal', 'foul'].contains(event.type))
                        Wrap(
                          spacing: 4,
                          children: [
                            if (event.type == 'goal')
                              TextButton.icon(
                                onPressed: () => onCorrect(event),
                                icon: const Icon(Icons.edit_outlined, size: 16),
                                label: const Text('Correct'),
                              ),
                            TextButton.icon(
                              onPressed: () => onUndo(event),
                              icon: const Icon(Icons.undo, size: 16),
                              label: const Text('Undo'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

class CorrectionReasonDialog extends StatefulWidget {
  const CorrectionReasonDialog({super.key});
  @override
  State<CorrectionReasonDialog> createState() => _CorrectionReasonDialogState();
}

class _CorrectionReasonDialogState extends State<CorrectionReasonDialog> {
  bool _submitted = false;
  final _reason = TextEditingController();
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Void this event?'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _reason,
        maxLength: 300,
        decoration: const InputDecoration(labelText: 'Correction reason'),
        validator: (v) =>
            v == null || v.trim().isEmpty ? 'Enter a reason' : null,
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
            Navigator.pop(context, _reason.text.trim());
          }
        },
        child: const Text('Void event'),
      ),
    ],
  );
}
