import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../../app/providers.dart';
import '../../../core/widgets/common.dart';
import '../../../core/database/app_database.dart';
import '../../backup/data/backup_service.dart';
import '../data/settings_repository.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsState();
}

class _SettingsState extends ConsumerState<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  final _minutes = TextEditingController(text: '10'),
      _win = TextEditingController(text: '3'),
      _draw = TextEditingController(text: '1'),
      _loss = TextEditingController(text: '0'),
      _cycles = TextEditingController(text: '1'),
      _limit = TextEditingController(text: '6');
  String _generation = 'balanced',
      _mode = 'round_robin',
      _policy = 'both_rotate';
  bool _initialized = false, _busy = false;
  String? _message;
  @override
  void dispose() {
    for (final c in [_minutes, _win, _draw, _loss, _cycles, _limit]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    setState(() => _busy = true);
    try {
      await SettingsRepository(await ref.read(databaseProvider.future)).save(
        AppSettings(
          minutes: int.parse(_minutes.text),
          generation: _generation,
          competition: _mode,
          win: int.parse(_win.text),
          draw: int.parse(_draw.text),
          loss: int.parse(_loss.text),
          cycles: int.parse(_cycles.text),
          policy: _policy,
          limit: int.parse(_limit.text),
        ),
      );
      if (mounted) {
        refreshData(ref);
        setState(
          () => _message = 'Defaults saved for new sessions and competitions.',
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
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    final maintenance = ref.read(maintenanceProvider.notifier);
    maintenance.state = true;
    try {
      await (await ref.read(
        matchRepositoryProvider.future,
      )).checkpointRunning();
      final file = await (await ref.read(
        backupServiceProvider.future,
      )).create(await ref.read(databaseProvider.future));
      final saved = await ref
          .read(deviceFilesProvider)
          .save(file.path, p.basename(file.path), 'application/zip');
      if (mounted) {
        setState(
          () => _message = saved
              ? 'Backup saved to your selected location. Keep it private; it contains player photos and history.'
              : 'Backup prepared privately; saving was cancelled. Tap Create backup to try again.',
        );
      }
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    } finally {
      maintenance.state = false;
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    PreparedRestore? prepared;
    String? selected;
    var activated = false;
    final maintenance = ref.read(maintenanceProvider.notifier);
    BackupService? service;
    try {
      service = await ref.read(backupServiceProvider.future);
      selected = await ref.read(deviceFilesProvider).pick('backup');
      if (selected == null) {
        return;
      }
      maintenance.state = true;
      prepared = await service.prepare(File(selected));
      maintenance.state = false;
      if (!mounted) {
        return;
      }
      final summary = prepared.manifest['summary'] as Map<String, dynamic>?,
          missing =
              (prepared.manifest['missing_photo_player_ids'] as List?)
                  ?.length ??
              0;
      final accepted = await confirm(
        context,
        title: 'Replace current app data?',
        message:
            'Validated backup from ${prepared.manifest['created_at']}\n${summary?['players'] ?? '—'} players · ${summary?['sessions'] ?? '—'} sessions · ${summary?['matches'] ?? '—'} matches.\n$missing unavailable photo references.\n${prepared.manifest['paused_live_matches']} running matches will reopen paused and require timer review.\n\nThis replaces the data shown in the app. The previous local data is retained for recovery. Export a current backup first if you need a portable copy.',
        action: 'Restore this backup',
      );
      if (!accepted || !mounted) {
        return;
      }
      maintenance.state = true;
      AppDatabase? current;
      try {
        current = await ref.read(databaseProvider.future);
      } catch (_) {
        /* Validated backup can recover an unreadable current database. */
      }
      await service.activate(prepared, current);
      activated = true;
      ref.invalidate(databaseProvider);
      refreshData(ref);
      await ref.read(databaseProvider.future);
      if (mounted) {
        context.go('/');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Backup restored. Previous local data remains available in Settings.',
            ),
          ),
        );
      }
    } catch (e) {
      ref.invalidate(databaseProvider);
      if (mounted) {
        showError(context, e);
      }
    } finally {
      try {
        if (prepared != null && !activated && service != null) {
          await service.discard(prepared);
        }
        if (selected != null && await File(selected).exists()) {
          await File(selected).delete();
        }
      } catch (_) {
        /* Incomplete private staging may be retried; never block the app on cleanup. */
      } finally {
        maintenance.state = false;
      }
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _recover() async {
    if (!await confirm(
      context,
      title: 'Reopen previous local data?',
      message:
          'Switch back to the data kept before the latest restore. Changes made in the currently selected data will not appear in the previous copy. Running matches reopen paused and require timer review.',
      action: 'Recover previous data',
    )) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = true);
    final maintenance = ref.read(maintenanceProvider.notifier);
    maintenance.state = true;
    try {
      final current = ref.read(databaseProvider).valueOrNull;
      if (current != null) {
        await current.close();
      }
      await (await ref.read(storageProvider.future)).recoverPrevious();
      ref.invalidate(databaseProvider);
      refreshData(ref);
      await BackupService.pauseForRecovery(
        await ref.read(databaseProvider.future),
      );
      refreshData(ref);
      if (mounted) {
        context.go('/');
      }
    } catch (e) {
      ref.invalidate(databaseProvider);
      if (mounted) {
        showError(context, e);
      }
    } finally {
      maintenance.state = false;
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _number(TextEditingController c, String label, int min, int max) =>
      SizedBox(
        width: 145,
        child: TextFormField(
          controller: c,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label),
          validator: (v) {
            final n = int.tryParse(v ?? '');
            return n == null || n < min || n > max ? 'Use $min–$max' : null;
          },
        ),
      );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Settings & local data')),
      body: Content(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Eyebrow('Ready for next Saturday'),
            const SizedBox(height: 12),
            AsyncContent(
              value: ref.watch(settingsProvider),
              retry: () => retryData(ref),
              builder: (s) {
                if (!_initialized) {
                  _minutes.text = '${s.minutes}';
                  _win.text = '${s.win}';
                  _draw.text = '${s.draw}';
                  _loss.text = '${s.loss}';
                  _cycles.text = '${s.cycles}';
                  _limit.text = '${s.limit}';
                  _generation = s.generation;
                  _mode = s.competition;
                  _policy = s.policy;
                  _initialized = true;
                }
                return Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionTitle('Defaults for new sessions'),
                      const SizedBox(height: 16),
                      _number(_minutes, 'Match minutes', 1, 180),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: _generation,
                        decoration: const InputDecoration(
                          labelText: 'Team generation mode',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'balanced',
                            child: Text('Balanced preview'),
                          ),
                          DropdownMenuItem(
                            value: 'random',
                            child: Text('Random'),
                          ),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _generation = v!),
                      ),
                      const SizedBox(height: 16),
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
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _mode = v!),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 14,
                        children: [
                          _number(_win, 'Win points', 0, 100),
                          _number(_draw, 'Draw points', 0, 100),
                          _number(_loss, 'Loss points', 0, 100),
                          _number(_cycles, 'League cycles', 1, 10),
                          _number(_limit, 'Rotation matches', 1, 100),
                        ],
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: _policy,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Winner-stays draw policy',
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
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _policy = v!),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _save,
                        child: const Text('Save defaults'),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 28),
            const SectionTitle('Backup & restore'),
            const SizedBox(height: 12),
            const Text(
              'Backups contain the database, settings, and available player photos. They are not encrypted. Save them somewhere you trust. Missing source photos are reported; missing pixels cannot be reconstructed.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _backup,
              icon: const Icon(Icons.save_alt),
              label: const Text('Create offline backup'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _restore,
              icon: const Icon(Icons.restore),
              label: const Text('Validate & restore a backup'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _recover,
              icon: const Icon(Icons.history),
              label: const Text('Recover previous local data'),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_message!),
              ),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 24),
            const SectionTitle('About Saturday Futsal'),
            const SizedBox(height: 12),
            const Text(
              'Version 1.0.0+1 · Dark sports theme\n\nNo accounts, analytics tracking, or server connection. Profiles, photos, and matches stay in app storage. Export and sharing happen only when you choose them. Uninstalling or clearing storage removes local data; keep a backup. Sharing a poster shares its visible names and photos.',
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    ),
  );
}
