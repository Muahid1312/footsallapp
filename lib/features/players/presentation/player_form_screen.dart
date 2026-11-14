import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'photo_crop_screen.dart';
import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';

class PlayerFormScreen extends ConsumerStatefulWidget {
  const PlayerFormScreen({super.key, this.playerId});
  final String? playerId;
  @override
  ConsumerState<PlayerFormScreen> createState() => _PlayerFormScreenState();
}

class _PlayerFormScreenState extends ConsumerState<PlayerFormScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _jersey = TextEditingController();
  String _position = 'All-rounder';
  String _foot = 'unknown';
  String? _secondary;
  bool _keeper = false;
  String? _photo;
  double _skill = 5;
  bool _loading = true, _saving = false, _picking = false;
  Object? _loadError;
  List<String> get _positionOptions => <String>{
    ...positions,
    _position,
    if (_secondary != null) _secondary!,
  }.toList();
  static const positions = [
    'All-rounder',
    'Goalkeeper',
    'Defender',
    'Winger',
    'Pivot',
  ];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (widget.playerId != null) {
        final p = await (await ref.read(
          databaseProvider.future,
        )).player(widget.playerId!);
        if (p == null) {
          throw StateError('Player not found.');
        }
        _name.text = p.name;
        _jersey.text = p.jerseyNumber?.toString() ?? '';
        _position = p.preferredPosition;
        _secondary = p.secondaryPosition;
        _keeper = p.goalkeeperEligible;
        _foot = p.preferredFoot;
        _photo = p.photoPath;
        _skill = p.skillRating.toDouble();
      }
      final recovered = await ref.read(photoStoreProvider).recoverLostPhoto();
      if (recovered != null) {
        _photo = recovered;
      }
    } catch (e) {
      _loadError = e;
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _jersey.dispose();
    super.dispose();
  }

  Future<void> _pick({ImageSource source = ImageSource.gallery}) async {
    setState(() => _picking = true);
    try {
      final store = ref.read(photoStoreProvider);
      final selected = await store.select(source: source);
      if (selected == null || !mounted) {
        return;
      }
      final photo = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              PhotoCropScreen(file: File(selected.path), store: store),
        ),
      );
      if (mounted && photo != null) {
        setState(() => _photo = photo);
      }
    } catch (e) {
      if (mounted) {
        showError(
          context,
          source == ImageSource.camera
              ? StateError(
                  'The camera is unavailable or could not return a photo. Choose a photo from the gallery instead.',
                )
              : e,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _picking = false);
      }
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    setState(() => _saving = true);
    try {
      final db = await ref.read(databaseProvider.future);
      await db.savePlayer(
        id: widget.playerId,
        name: _name.text,
        position: _position,
        photoPath: _photo,
        jerseyNumber: int.tryParse(_jersey.text.trim()),
        skillRating: _skill.round(),
        secondaryPosition: _secondary,
        updateSecondaryPosition: true,
        goalkeeperEligible: _keeper,
        preferredFoot: _foot,
      );
      refreshData(ref);
      if (mounted) {
        context.pop();
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.playerId == null ? 'Add player' : 'Edit player'),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _loadError != null
        ? const Center(
            child: Text('Couldn’t load this player. Go back and try again.'),
          )
        : Content(
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Eyebrow('Squad profile'),
                  const SizedBox(height: 10),
                  Text(
                    widget.playerId == null
                        ? 'Meet your next\nteammate.'
                        : 'Keep the squad\nup to date.',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: Column(
                      children: [
                        SizedBox(
                          width: 100,
                          height: 100,
                          child: ClipOval(
                            child: _photo == null
                                ? Container(
                                    color: AppColors.elevated,
                                    child: const Icon(
                                      Icons.person_outline,
                                      size: 48,
                                      color: AppColors.emerald,
                                    ),
                                  )
                                : Image.file(
                                    File(_photo!),
                                    fit: BoxFit.cover,
                                    errorBuilder: (c, e, s) => Container(
                                      color: AppColors.elevated,
                                      child: const Icon(
                                        Icons.person_outline,
                                        size: 48,
                                        color: AppColors.emerald,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _picking || _saving ? null : _pick,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: Text(
                            _picking ? 'Copying photo…' : 'Choose photo',
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _picking || _saving
                              ? null
                              : () => _pick(source: ImageSource.camera),
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('Take photo'),
                        ),
                        if (_photo != null)
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => setState(() => _photo = null),
                            child: const Text('Remove photo'),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _name,
                    maxLength: 80,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Player name'),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'Enter a player name'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _position,
                    decoration: const InputDecoration(
                      labelText: 'Preferred position',
                    ),
                    items: _positionOptions
                        .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) {
                        setState(() {
                          _position = v;
                          if (_secondary == v) {
                            _secondary = null;
                          }
                          if (v == 'Goalkeeper') {
                            _keeper = true;
                          }
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    key: ValueKey('secondary-$_position'),
                    initialValue: _secondary ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Secondary position (optional)',
                    ),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('None')),
                      ..._positionOptions
                          .where((p) => p != _position)
                          .map(
                            (p) => DropdownMenuItem(value: p, child: Text(p)),
                          ),
                    ],
                    onChanged: (v) => setState(
                      () => _secondary = v == null || v.isEmpty ? null : v,
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Eligible to play goalkeeper'),
                    subtitle: const Text(
                      'Used for team coverage, independently of skill rating.',
                    ),
                    value: _keeper,
                    onChanged: (v) => setState(() => _keeper = v),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: _foot,
                    decoration: const InputDecoration(
                      labelText: 'Preferred foot',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'unknown',
                        child: Text('Not specified'),
                      ),
                      DropdownMenuItem(value: 'left', child: Text('Left')),
                      DropdownMenuItem(value: 'right', child: Text('Right')),
                      DropdownMenuItem(value: 'both', child: Text('Both')),
                    ],
                    onChanged: (v) => setState(() => _foot = v!),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _jersey,
                    keyboardType: TextInputType.number,
                    maxLength: 2,
                    decoration: const InputDecoration(
                      labelText: 'Jersey number',
                      hintText: 'Optional · 0–99',
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return null;
                      }
                      final n = int.tryParse(v);
                      return n == null || n < 0 || n > 99
                          ? 'Use a number from 0 to 99'
                          : null;
                    },
                  ),
                  const SizedBox(height: 16),
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Skill rating',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              '${_skill.round()} / 10',
                              style: const TextStyle(
                                color: AppColors.emerald,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: _skill,
                          min: 1,
                          max: 10,
                          divisions: 9,
                          label: '${_skill.round()}',
                          onChanged: (v) => setState(() => _skill = v),
                        ),
                        const Text(
                          'An administrator’s estimate, used for squad planning.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _saving || _picking ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: Text(_saving ? 'Saving…' : 'Save player'),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
  );
}
