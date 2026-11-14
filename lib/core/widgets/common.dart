import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/players/domain/player.dart';
import '../theme/app_theme.dart';

class Content extends StatelessWidget {
  const Content({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 840),
      child: SafeArea(top: false, child: child),
    ),
  );
}

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.onTap,
  });
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: const BorderSide(color: AppColors.line),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    ),
  );
}

class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      color: AppColors.emerald,
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 2,
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.action});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      if (action != null) action!,
    ],
  );
}

class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar(this.player, {super.key, this.radius = 24});
  final Player player;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final initials = player.name
        .trim()
        .split(RegExp(r'\s+'))
        .take(2)
        .map((s) => s.isEmpty ? '' : s.characters.first)
        .join()
        .toUpperCase();
    final fallback = Container(
      color: AppColors.elevated,
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: AppColors.emerald,
          fontWeight: FontWeight.w800,
          fontSize: radius * .65,
        ),
      ),
    );
    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: ClipOval(
        child: player.photoPath == null
            ? fallback
            : Image.file(
                File(player.photoPath!),
                fit: BoxFit.cover,
                cacheWidth:
                    (radius * 2 * MediaQuery.devicePixelRatioOf(context))
                        .round()
                        .clamp(64, 512)
                        .toInt(),
                cacheHeight:
                    (radius * 2 * MediaQuery.devicePixelRatioOf(context))
                        .round()
                        .clamp(64, 512)
                        .toInt(),
                errorBuilder: (_, error, stack) => fallback,
              ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: Column(
      children: [
        const SizedBox(height: 12),
        Icon(icon, size: 42, color: AppColors.emerald),
        const SizedBox(height: 18),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 18), action!],
        const SizedBox(height: 12),
      ],
    ),
  );
}

class AsyncContent<T> extends StatelessWidget {
  const AsyncContent({
    super.key,
    required this.value,
    required this.builder,
    this.retry,
  });
  final AsyncValue<T> value;
  final Widget Function(T) builder;
  final VoidCallback? retry;
  @override
  Widget build(BuildContext context) => value.when(
    data: builder,
    loading: () => const Center(
      child: Padding(
        padding: EdgeInsets.all(48),
        child: CircularProgressIndicator(),
      ),
    ),
    error: (error, stack) => Padding(
      padding: const EdgeInsets.all(20),
      child: EmptyState(
        icon: Icons.error_outline,
        title: 'Couldn’t load your data',
        message: 'Your saved data has not been removed. Please try again.',
        action: retry == null
            ? null
            : OutlinedButton(onPressed: retry, child: const Text('Try again')),
      ),
    ),
  );
}

void showError(BuildContext context, Object error) {
  final message = error is ArgumentError
      ? error.message.toString()
      : error is StateError
      ? error.message
      : error is FormatException
      ? error.message
      : 'Couldn’t complete this action. Please try again.';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
