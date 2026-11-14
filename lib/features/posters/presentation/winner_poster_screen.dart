import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../../app/providers.dart';
import '../../../core/widgets/common.dart';
import '../data/poster_repository.dart';
import '../data/poster_renderer.dart';
import '../domain/winner_poster.dart';

class WinnerPosterScreen extends ConsumerStatefulWidget {
  const WinnerPosterScreen({super.key, required this.competitionId});
  final String competitionId;
  @override
  ConsumerState<WinnerPosterScreen> createState() => _PosterState();
}

class _PosterState extends ConsumerState<WinnerPosterScreen> {
  final _title = TextEditingController(text: 'SATURDAY FUTSAL CHAMPIONSHIP');
  List<WinnerPoster>? _champions;
  String? _team, _error;
  List<String> _order = [];
  PosterStyle _style = PosterStyle.championsNight;
  bool _story = false,
      _color = true,
      _summary = true,
      _busy = false,
      _dirty = true;
  int _page = 0;
  File? _png;
  WinnerPoster get _data => _champions!.singleWhere((c) => c.teamId == _team);
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final repo = PosterRepository(
        await ref.read(databaseProvider.future),
        await ref.read(competitionRepositoryProvider.future),
      );
      final choices = await repo.champions(widget.competitionId);
      if (mounted) {
        setState(() {
          _champions = choices;
          _team = choices.first.teamId;
          _order = choices.first.players.map((p) => p.id).toList();
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is StateError
              ? e.message
              : 'Could not load the confirmed champion. Retry without changing competition history.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (mounted && _champions != null) {
      await _render();
    }
  }

  Future<void> _render() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await PosterRenderer().render(
        _data,
        style: _style,
        story: _story,
        teamColor: _color,
        showSummary: _summary,
        title: _title.text,
        order: _order,
        page: _page,
      );
      final root = await Directory(
        p.join((await getTemporaryDirectory()).path, 'winner_posters'),
      ).create(recursive: true);
      final file = File(
        p.join(root.path, 'champions_${const Uuid().v4()}_${_page + 1}.png'),
      );
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        final old = _png;
        setState(() {
          _png = file;
          _dirty = false;
          _error = null;
        });
        if (old != null && await old.exists()) {
          await old.delete();
        }
      } else {
        await file.delete();
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

  Future<void> _export(bool share) async {
    setState(() => _busy = true);
    try {
      final device = ref.read(deviceFilesProvider),
          name =
              'saturday_futsal_champions_${_data.date.toIso8601String().substring(0, 10)}_${_page + 1}.png';
      if (share) {
        await device.share(_png!.path, name, 'image/png');
      } else {
        final saved = await device.save(_png!.path, name, 'image/png');
        if (mounted && saved) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('High-resolution PNG saved.')),
          );
        }
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
      appBar: AppBar(title: const Text('Winner studio')),
      body: Content(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Eyebrow('Made on Saturday. Remembered forever.'),
            const SizedBox(height: 12),
            Text(
              'The winning moment.',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Original designs rendered offline. Check faces and names in the preview before saving or sharing.',
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!),
              TextButton(
                onPressed: _busy ? null : _load,
                child: const Text('Retry'),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            if (_champions != null) ...[
              const SizedBox(height: 20),
              if (_champions!.length > 1) ...[
                const Text(
                  'Shared championship: create a poster for each confirmed co-champion. Every poster is labeled Shared Champions.',
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _team,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirmed co-champion',
                  ),
                  items: _champions!
                      .map(
                        (c) => DropdownMenuItem(
                          value: c.teamId,
                          child: Text(c.teamName),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                          _team = v;
                          _order = _data.players.map((p) => p.id).toList();
                          _page = 0;
                          _dirty = true;
                        }),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                controller: _title,
                enabled: !_busy,
                maxLength: 70,
                decoration: const InputDecoration(
                  labelText: 'Competition title',
                ),
                onChanged: (_) => setState(() => _dirty = true),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<PosterStyle>(
                initialValue: _style,
                decoration: const InputDecoration(labelText: 'Poster design'),
                items: PosterStyle.values
                    .map(
                      (s) => DropdownMenuItem(value: s, child: Text(s.label)),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _style = v!;
                        _dirty = true;
                      }),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<bool>(
                initialValue: _story,
                decoration: const InputDecoration(
                  labelText: 'Export dimensions',
                ),
                items: const [
                  DropdownMenuItem(
                    value: false,
                    child: Text('Portrait · 1080 × 1350'),
                  ),
                  DropdownMenuItem(
                    value: true,
                    child: Text('Story · 1080 × 1920'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _story = v!;
                        _page = 0;
                        _dirty = true;
                      }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _color,
                title: const Text('Use team color accents'),
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _color = v;
                        _dirty = true;
                      }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _summary,
                title: const Text('Show recorded competition summary'),
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _summary = v;
                        _dirty = true;
                      }),
              ),
              if (_data.pages(story: _story).length > 1) ...[
                const SizedBox(height: 8),
                Text(
                  '${_data.players.length} players span ${_data.pages(story: _story).length} pages. Export each page to include the full squad.',
                ),
                DropdownButtonFormField<int>(
                  key: ValueKey('pages-$_story-$_team'),
                  initialValue: _page,
                  decoration: const InputDecoration(labelText: 'Poster page'),
                  items: [
                    for (var i = 0; i < _data.pages(story: _story).length; i++)
                      DropdownMenuItem(value: i, child: Text('Page ${i + 1}')),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                          _page = v!;
                          _dirty = true;
                        }),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _render,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Render preview'),
              ),
              if (_dirty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Changes need a new preview before export.'),
                ),
              if (_png != null) ...[
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.file(_png!, cacheWidth: 720),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy || _dirty ? null : () => _export(false),
                      icon: const Icon(Icons.download),
                      label: const Text('Save PNG'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || _dirty ? null : () => _export(true),
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('Share PNG'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              const SectionTitle('Player order'),
              const SizedBox(height: 8),
              const Text(
                'Drag to reorder. All champion-team players remain included. Long names may use an ellipsis; inspect every page.',
              ),
              ReorderableListView.builder(
                buildDefaultDragHandles: !_busy,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _order.length,
                onReorder: _busy
                    ? (_, _) {}
                    : (old, next) => setState(() {
                        if (next > old) {
                          next--;
                        }
                        final id = _order.removeAt(old);
                        _order.insert(next, id);
                        _dirty = true;
                      }),
                itemBuilder: (context, index) {
                  final player = _data.players.singleWhere(
                    (p) => p.id == _order[index],
                  );
                  return ListTile(
                    key: ValueKey(player.id),
                    leading: PlayerAvatar(player, radius: 20),
                    title: Text(player.name),
                    trailing: const Icon(Icons.drag_handle),
                  );
                },
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    ),
  );
}
