import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/providers.dart';
import '../../../core/widgets/common.dart';
import '../domain/player_csv.dart';
import '../data/player_import_repository.dart';

class PlayerImportScreen extends ConsumerStatefulWidget {
  const PlayerImportScreen({super.key});
  @override
  ConsumerState<PlayerImportScreen> createState() => _ImportState();
}

class _ImportState extends ConsumerState<PlayerImportScreen> {
  CsvTable? _table;
  Map<String, int?> _mapping = {};
  List<PlayerImportRow>? _rows;
  bool _busy = false;
  String? _message;
  Future<void> _pick() async {
    setState(() => _busy = true);
    String? selected;
    try {
      selected = await ref.read(deviceFilesProvider).pick('csv');
      if (selected == null) {
        return;
      }
      final file = File(selected);
      if (await file.length() > 2 * 1024 * 1024) {
        throw const FormatException('CSV is larger than 2 MB.');
      }
      final table = CsvTable.parse(utf8.decode(await file.readAsBytes()));
      if (mounted) {
        setState(() {
          _table = table;
          _mapping = table.suggest();
          _rows = null;
          _message = null;
        });
      }
    } catch (e) {
      if (mounted) {
        showError(context, e);
      }
    } finally {
      if (selected != null && await File(selected).exists()) {
        await File(selected).delete();
      }
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _preview() async {
    setState(() => _busy = true);
    try {
      final players = await (await ref.read(
        databaseProvider.future,
      )).players(includeArchived: true);
      final rows = previewCsv(_table!, _mapping, players);
      if (mounted) {
        setState(() => _rows = rows);
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

  Future<void> _apply() async {
    final updates = _rows!.where((r) => r.action == 'update').length,
        creates = _rows!.where((r) => r.action == 'create').length;
    if (!await confirm(
      context,
      title: 'Import these profiles?',
      message:
          'Create $creates players and update $updates existing profiles. Existing IDs, ratings, photos, and match history are preserved. New players start with a manual rating of 5; review it afterward.',
      action: 'Import profiles',
    )) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final count = await PlayerImportRepository(
        await ref.read(databaseProvider.future),
      ).apply(_rows!);
      if (mounted) {
        refreshData(ref);
        setState(() {
          _rows = null;
          _table = null;
          _message =
              '$count profiles imported. Assign photos manually from each player profile.';
        });
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
      appBar: AppBar(title: const Text('Import player profiles')),
      body: Content(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Eyebrow('From the form to the pitch'),
            const SizedBox(height: 12),
            Text(
              'Bring your squad.',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Export the Google Form response sheet as UTF-8 CSV, then map its columns. No Google account connection is needed.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Drive photo links stay private to Google and are not downloaded. Open each imported profile to assign a gallery or camera photo.',
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.upload_file),
              label: const Text('Select CSV file'),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_message!),
              ),
            if (_busy) const LinearProgressIndicator(),
            if (_table != null) ...[
              const SizedBox(height: 20),
              Text(
                '${_table!.rows.length} records · Map columns',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final e in const {
                'name': 'Full name (or map first/last below)',
                'first': 'First name',
                'last': 'Last name',
                'position': 'Position',
                'foot': 'Preferred foot',
                'jersey': 'Jersey number',
                'photo': 'Photo / Drive link',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('${identityHashCode(_table)}-${e.key}'),
                    initialValue: _mapping[e.key] ?? -1,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: e.value),
                    items: [
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('Not mapped'),
                      ),
                      for (var i = 0; i < _table!.headers.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            _table!.headers[i],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                            _mapping[e.key] = v == -1 ? null : v;
                            _rows = null;
                          }),
                  ),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _preview,
                child: const Text('Preview records'),
              ),
            ],
            if (_rows != null) ...[
              const SizedBox(height: 24),
              const SectionTitle('Review every selection'),
              const SizedBox(height: 8),
              const Text(
                'Likely duplicates default to Skip. Select Update and the existing player to preserve their identity and history. Only one selected record per name is allowed.',
              ),
              const SizedBox(height: 16),
              for (final r in _rows!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Row ${r.number} · ${r.name.isEmpty ? 'Missing name' : r.name}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${r.position} · ${r.foot} foot${r.jersey == null ? '' : ' · #${r.jersey}'}',
                        ),
                        if (r.action == 'update' &&
                            (!r.hasPosition || !r.hasFoot))
                          const Text(
                            'Unmapped or empty position/foot fields preserve existing values on update.',
                          ),
                        if (r.photoLink)
                          const Text(
                            'Photo link: assign manually after import.',
                          ),
                        if (r.error != null)
                          Text(
                            r.error!,
                            style: const TextStyle(color: Color(0xFFFBBF24)),
                          ),
                        if (r.repeated)
                          const Text(
                            'Repeated name in this CSV; select only one row.',
                          ),
                        if (r.duplicates.isNotEmpty)
                          const Text(
                            'Likely existing player. Review before updating.',
                          ),
                        DropdownButtonFormField<String>(
                          initialValue: r.action,
                          decoration: const InputDecoration(
                            labelText: 'Action',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: 'skip',
                              child: Text('Skip'),
                            ),
                            if (r.error == null && r.duplicates.isEmpty)
                              const DropdownMenuItem(
                                value: 'create',
                                child: Text('Create new profile'),
                              ),
                            if (r.error == null && r.duplicates.isNotEmpty)
                              const DropdownMenuItem(
                                value: 'update',
                                child: Text('Update existing profile'),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => r.action = v!),
                        ),
                        if (r.action == 'update') ...[
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: r.target,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Existing player',
                            ),
                            items: r.duplicates
                                .map(
                                  (p) => DropdownMenuItem(
                                    value: p.id,
                                    child: Text(
                                      '${p.name} · ${p.preferredPosition}${p.jerseyNumber == null ? '' : ' · #${p.jerseyNumber}'}${p.isArchived ? ' · Archived' : ''}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => r.target = v),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              FilledButton.icon(
                onPressed: _busy || !_rows!.any((r) => r.action != 'skip')
                    ? null
                    : _apply,
                icon: const Icon(Icons.check),
                label: const Text('Import selected profiles'),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    ),
  );
}
